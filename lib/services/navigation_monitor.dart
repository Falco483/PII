/// navigation_monitor.dart — Logica di Business per la Navigazione Assistita
///
/// Questa classe gestisce tutta la logica "intelligente" dell'app:
/// 1. Mantiene la variabile `direction` (bearing affidabile)
/// 2. Rileva quando l'utente è fermo (zero-speed trigger)
/// 3. Controlla se l'utente è su un waypoint di svolta del percorso
/// 4. Calcola i punti laterali e interroga la Roads API
/// 5. Emette eventi per l'overlay visivo
/// 6. [TASK 2] Monitora la posizione rispetto al percorso attivo ogni 2 secondi
/// 7. [TASK 2] Gestisce il cambio automatico a percorsi alternativi
/// 8. [TASK 2] Ricalcola il percorso via API se nessun alternativo è compatibile
///
/// SEPARAZIONE DELLE RESPONSABILITÀ:
/// Questo file contiene SOLO la logica di business. Non contiene:
/// - Rendering UI (→ navigation_overlay.dart)
/// - Chiamate GPS (→ navigation_screen.dart)
/// - Calcoli geodetici (→ geo_utils.dart)
/// - Chiamate Roads API (→ roads_service.dart)
///
/// Questo design permette di testare la logica in isolamento e di sostituire
/// facilmente qualsiasi componente senza toccare gli altri.
///
/// THREAD SAFETY:
/// Gli aggiornamenti GPS arrivano in background (stream asincrono).
/// Per evitare race condition:
/// - Lo snapshot della posizione e del bearing viene catturato atomicamente
///   al momento dello scadere del timer (Step 2.2)
/// - I timer vengono cancellati in modo sicuro controllando sempre se sono
///   ancora attivi prima di operare
/// - Le variabili critiche (direction, _zeroSpeedTimer) sono modificate
///   solo dal thread principale (main isolate di Flutter)
library;

import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'geo_utils.dart';
import 'roads_service.dart';
import 'directions_service.dart';
import '../models/navigation_session.dart';
import 'navigation_session_service.dart';

// =============================================================================
// MODELLO PER LO STATO DELL'OVERLAY
// =============================================================================

/// Tipo di overlay da mostrare sulla mappa.
///
/// - [turnInstruction]: l'utente è fermo su un waypoint di svolta.
///   Mostra l'istruzione di navigazione (testo da html_instructions).
/// - [lateralRoadDetected]: la Roads API ha trovato strade laterali.
///   Mostra un messaggio di incoraggiamento ("Continua dritto, stai andando bene!").
/// - [arrivalCelebration]: l'utente ha raggiunto la destinazione.
///   Mostra un messaggio di congratulazioni con festa.
enum OverlayType {
  turnInstruction,
  lateralRoadDetected,
  arrivalCelebration,
  returnToRoute,
}

/// Stato dell'overlay da mostrare sulla mappa.
///
/// Contiene il tipo di overlay e il messaggio da visualizzare.
/// Viene emesso dal NavigationMonitor tramite un ValueNotifier
/// per essere osservato dalla UI.
class NavigationOverlayState {
  final OverlayType type;
  final String message;

  /// L'istruzione di manovra dallo step, se disponibile (es. "turn-right").
  /// Usato dalla UI per mostrare un'icona appropriata.
  final String? maneuver;

  NavigationOverlayState({
    required this.type,
    required this.message,
    this.maneuver,
  });
}

// =============================================================================
// MESSAGGI DI SUPPORTO PER RAGAZZI CON DISABILITÀ COGNITIVE
// =============================================================================
//
// PRINCIPI DI DESIGN:
// 1. Frasi CORTE e SEMPLICI → massimo 5-6 parole
// 2. Tono POSITIVO e RASSICURANTE → mai rimproveri, mai imperativi aggressivi
// 3. Nessuna parola ambigua → "dritto" è chiaro, "prosegui" può confondere
// 4. Ripetizione del concetto chiave → "dritto" compare in tutte le frasi
//    laterali perché è l'unica informazione che conta in quel momento
// 5. Emoji come supporto visivo → il cervello processa le emoji più
//    velocemente del testo, utile per comunicazione immediata

/// Messaggi mostrati quando vengono rilevate strade laterali.
/// L'utente NON deve svoltare, deve continuare dritto.
/// Ogni messaggio rassicura che la strada è giusta.
const List<String> kLateralRoadMessages = [
  ' Continua dritto, stai andando bene!',
  ' Vai dritto, sei sulla strada giusta!',
  ' Bravo, continua così! Vai dritto!',
  ' Non svoltare, vai sempre dritto!',
  ' Perfetto! Continua dritto!',
  ' Stai andando benissimo, dritto!',
];

/// Messaggi mostrati quando l'utente è vicino a un waypoint di svolta.
/// Il testo dell'istruzione di svolta viene AGGIUNTO dopo il prefisso
/// di incoraggiamento, così il ragazzo legge prima il rinforzo positivo
/// e poi l'istruzione specifica.
///
/// ESEMPIO COMPLETO:
/// "Ci siamo quasi! Svolta a destra in Via Roma"
const List<String> kTurnEncouragementPrefixes = [
  'Ci siamo quasi! ',
  'Bravissimo! Ora: ',
  'Perfetto! Adesso: ',
  'Stai andando forte! ',
  'Ottimo lavoro! Ora: ',
  'Ce la fai! ',
];

/// Messaggi di celebrazione mostrati quando l'utente raggiunge la destinazione.
/// Questi sono i messaggi più importanti dell'intera app: il ragazzo ha completato
/// il percorso da solo. Devono trasmettere orgoglio e soddisfazione.
const List<String> kArrivalMessages = [
  ' Sei arrivato! Bravissimo!',
  ' Ce l\'hai fatta! Sei un campione!',
  ' Sei arrivato a destinazione! Grande!',
  ' Complimenti, sei arrivato!',
  ' Perfetto! Sei arrivato, bravo!',
  ' Destinazione raggiunta! Che bravo!',
];

// =============================================================================
// MODELLO PER LO STATO DI RICALCOLO PERCORSO
// =============================================================================

/// Fasi del processo di ricalcolo percorso.
///
/// Queste fasi guidano la UI per mostrare il bottom sheet appropriato:
/// - [none]: nessun ricalcolo in corso, UI normale
/// - [offRoute]: deviazione confermata, ricerca percorso alternativo in corso
/// - [rerouting]: nessun alternativo trovato, chiamata API in corso
/// - [routeChanged]: nuovo percorso trovato e applicato, mostra conferma
///
/// FLUSSO TIPICO:
/// none → offRoute → rerouting → routeChanged → none
///
/// FLUSSO RAPIDO (alternativo trovato in memoria):
/// none → offRoute → routeChanged → none
enum ReroutePhase { none, offRoute, rerouting, routeChanged }

/// FIX BUG 1 + BUG 2 — Modello per il progresso in tempo reale del percorso.
///
/// Incapsula i valori calcolati ad ogni aggiornamento GPS che la UI
/// deve mostrare in tempo reale:
///
/// - [remainingMeters]: distanza stimata residua fino alla destinazione
///   (somma delle distanze degli step futuri + distanza parziale dallo
///   step corrente al suo endLocation). Non passa per strade non
///   percorse; è una stima basata sul percorso attivo.
/// - [remainingSeconds]: tempo residuo stimato, proporzionale alla
///   distanza residua rispetto alla distanza totale del percorso.
///   Usare la velocità media del percorso (non quella istantanea) dà
///   stime più stabili e coerenti con i tempi mostrati inizialmente
///   dalla Directions API.
/// - [remainingDistanceText]: versione human-readable di
///   [remainingMeters] ("1,2 km", "450 m").
/// - [remainingDurationText]: versione human-readable di
///   [remainingSeconds] ("15 min", "1 h 5 min").
/// - [distanceToNextTurn]: distanza in metri dall'utente alla fine
///   dello step corrente — ovvero alla PROSSIMA svolta da effettuare.
///   Usato dal banner verde (BUG 2) per mostrare la distanza dinamica
///   alla prossima istruzione, invece del valore statico iniziale.
class RouteProgress {
  final double remainingMeters;
  final int remainingSeconds;
  final String remainingDistanceText;
  final String remainingDurationText;
  final double distanceToNextTurn;

  const RouteProgress({
    required this.remainingMeters,
    required this.remainingSeconds,
    required this.remainingDistanceText,
    required this.remainingDurationText,
    required this.distanceToNextTurn,
  });
}

// =============================================================================
// CLASSE PRINCIPALE — NAVIGATION MONITOR
// =============================================================================

/// NavigationMonitor — Cuore della logica di navigazione assistita.
///
/// CICLO DI VITA:
/// 1. Viene creato in NavigationScreen.initState()
/// 2. Riceve aggiornamenti continui di posizione, velocità e bearing
/// 3. Emette eventi di overlay tramite [overlayNotifier]
/// 4. Viene distrutto in NavigationScreen.dispose() tramite [dispose()]
///
/// UTILIZZO:
/// ```dart
/// final monitor = NavigationMonitor();
/// monitor.overlayNotifier.addListener(() {
///   final state = monitor.overlayNotifier.value;
///   if (state != null) { /* mostra overlay */ }
/// });
/// // Ad ogni aggiornamento GPS:
/// monitor.updatePosition(lat, lng, speedKmH, rawBearing);
/// // Quando il percorso viene calcolato:
/// monitor.updateRouteSteps(result.steps);
/// // In dispose:
/// monitor.dispose();
/// ```
class NavigationMonitor {
  // ===========================================================================
  // STATO INTERNO
  // ===========================================================================

  /// Ultimo bearing affidabile dell'utente (gradi 0-360, o null se mai acquisito).
  ///
  /// PERCHÉ PUÒ ESSERE NULL:
  /// Al primo avvio dell'app, prima che l'utente si muova a velocità sufficiente,
  /// non abbiamo nessun bearing affidabile. In questo stato, tutte le funzionalità
  /// che dipendono dalla direzione (calcolo punti laterali) restano in standby.
  /// Questo è preferibile a usare un bearing casuale che porterebbe a risultati
  /// errati.
  double? _direction;

  /// Posizione corrente dell'utente (latitudine).
  double? _currentLat;

  /// Posizione corrente dell'utente (longitudine).
  double? _currentLng;

  /// Posizione (latitudine) dell'ultima analisi per l'overlay (cooldown spaziale).
  double? _lastAnalysisLat;

  /// Posizione (longitudine) dell'ultima analisi per l'overlay (cooldown spaziale).
  double? _lastAnalysisLng;

  /// Timestamp dell'ultima chiamata alla Roads API (cooldown temporale).
  DateTime? _lastApiCallTime;

  /// Velocità corrente dell'utente in km/h.
  double _currentSpeed = 0.0;

  /// Counter dei tick per il polling dinamico (Adaptive Polling).
  int _routeCheckTicks = 0;

  /// Counter delle deviazioni consecutive (Strikes).
  /// Per pedoni (speed < 10 km/h) servono 3 strikes (6s); per veicoli 2 (4s).
  int _consecutiveOffRouteDetects = 0;

  /// Bearing raw corrente dal GPS (può essere inaffidabile a basse velocità).
  double _rawBearing = 0.0;

  /// Timer per il fallback di avanzamento step (FIX BUG 3+4).
  ///
  /// Quando l'utente è fermo o quasi-fermo (speed < 2 km/h) a 15-30m
  /// dalla svolta senza mai avvicinarsi abbastanza per attivare
  /// l'approche, questo timer forza l'avanzamento dopo 15 secondi.
  /// Questo evita che l'istruzione resti bloccata per sempre in coda
  /// o a un semaforo.
  Timer? _stallTimer;

  /// Timestamp dell'ultimo aggiornamento istruzione (FIX BUG 4).
  ///
  /// Usato per evitare aggiornamenti troppo rapidi dell'istruzione
  /// che confonderebbero l'utente (minimo 500ms tra istruzioni).
  DateTime? _lastInstructionTime;

  /// Accuratezza GPS corrente in metri (0.0 = sconosciuta).
  /// Aggiornata ad ogni chiamata updatePosition() e usata in _onRouteCheckTick()
  /// per saltare i tick quando il segnale è troppo debole (> 30m).
  double _currentAccuracy = 0.0;

  /// Lista degli step del percorso calcolato dalla Directions API.
  /// Viene aggiornata ogni volta che l'utente calcola un nuovo percorso.
  List<DirectionStep> _routeSteps = [];

  // ===========================================================================
  // STATO PROGRESSIONE PERCORSO — DYNAMIC INSTRUCTIONS
  // ===========================================================================

  /// Indice dello step attualmente attivo (cioè quello in cui l'utente si
  /// trova fisicamente). Al calcolo del percorso (o al ricalcolo) parte
  /// sempre da 0 (il primo step del percorso).
  ///
  /// Questo indice viene aumentato man mano che l'utente raggiunge il
  /// punto finale (`endLocation`) dello step corrente.
  int _currentStepIndex = 0;

  /// Contatore degli aggiornamenti GPS consecutivi in cui l'utente risulta
  /// vicino (< 15 metri) all'incrocio di destinazione dello step corrente.
  ///
  /// PERCHÉ SERVE QUESTO CONTATORE:
  /// Il GPS non è perfetto. Un singolo sbalzo temporaneo del segnale (es.
  /// riflesso su un palazzo) potrebbe porre falsamente l'utente a 5m
  /// dall'incrocio per un solo istante. Per evitare che l'interfaccia
  /// avanzi prematuramente d'istruzione, richiediamo che la vicinanza sia
  /// "confermata" per almeno N aggiornamenti GPS consecutivi (noi usiamo 2).
  int _consecutiveCloseUpdates = 0;

  /// FIX BUG 2 — Stato "approach-then-leave" per l'avanzamento step.
  ///
  /// PROBLEMA DELLA VERSIONE PRECEDENTE:
  /// L'avanzamento avveniva a 40m dalla endLocation dello step corrente,
  /// cioè PRIMA della svolta fisica. Il banner mostrava quindi l'istruzione
  /// del nuovo step (es. "Svolta a destra") mentre l'utente era ancora
  /// sulla strada precedente. Dopo che l'utente aveva effettivamente
  /// svoltato, il banner continuava a mostrare "Svolta a destra" finché
  /// l'utente non arrivava a 40m dal waypoint SUCCESSIVO — un ritardo
  /// percepibile di parecchie decine di secondi.
  ///
  /// LOGICA ATTUALE ("approach-then-leave"):
  /// 1. L'utente si avvicina all'endLocation dello step corrente.
  /// 2. Quando dist < 15m, marchiamo `_wasCloseToStepEnd = true`.
  /// 3. L'utente compie la svolta (fisicamente).
  /// 4. Quando dist > 25m (allontanamento), l'utente ha superato il
  ///    waypoint → avanziamo _currentStepIndex e resettiamo il flag.
  ///
  /// RISULTATO:
  /// Il banner si aggiorna DOPO la svolta effettiva, non prima: l'utente
  /// vede l'istruzione giusta per il tratto che sta realmente percorrendo.
  ///
  /// GESTIONE PROSSIMITÀ ALL'ULTIMO STEP:
  /// Sull'ultimo step il flag non serve perché non c'è "after-turn":
  /// la logica di arrivo (CASO B) gestisce la convergenza sulla
  /// destinazione con la sua soglia e le sue 3 conferme consecutive.
  bool _wasCloseToStepEnd = false;

  // ===========================================================================
  // STATO PERCORSI — TASK 2
  // ===========================================================================

  /// Percorso attualmente attivo (quello mostrato all'utente sulla mappa).
  /// Quando l'utente devia, questo campo viene sostituito con un percorso
  /// alternativo (Task 2b) o con il risultato di un ricalcolo API (Task 2c).
  /// È null se la navigazione non è ancora stata avviata.
  RouteData? _activeRoute;

  /// Lista di TUTTI i percorsi alternativi ricevuti dall'ultima chiamata API.
  /// Include anche il percorso attivo. Quando l'utente devia, iteriamo su
  /// questa lista per cercare un percorso alternativo compatibile (Task 2b)
  /// prima di fare una nuova chiamata API.
  List<RouteData> _alternativeRoutes = [];

  /// Destinazione originale come COORDINATE (formato "lat,lng").
  /// Salvata al momento del calcolo iniziale del percorso e usata per il
  /// ricalcolo API nel Task 2c: la destinazione non cambia mai, solo la
  /// posizione di partenza (che diventa la posizione GPS corrente).
  String? _originalDestination;

  /// Flag che indica se la navigazione è attiva.
  /// La navigazione è attiva dopo che startNavigation() è stato chiamato
  /// e fino a quando stopNavigation() o dispose() viene chiamato.
  /// Il timer di controllo percorso (ogni 2s) gira solo quando questo è true.
  bool _isNavigating = false;

  /// Flag che indica se un ricalcolo del percorso via API è in corso (Task 2c).
  /// Evita di lanciare ricalcoli concorrenti mentre il precedente è ancora
  /// in attesa di risposta dalla API.
  bool _isRerouting = false;

  /// Timestamp fino al quale il controllo deviazione è bloccato.
  /// Attivato quando l'utente sceglie "Torna al vecchio percorso":
  /// per 15 secondi non si effettuano controlli off-route né chiamate API,
  /// dando all'utente il tempo di manovrare per rientrare sul percorso.
  DateTime? _returnToRouteLockUntil;

  /// Flag che indica se l'arrivo a destinazione è già stato emesso.
  ///
  /// FIX BUG ANIMAZIONE ARRIVO:
  /// Senza questo flag, il monitor emetteva arrivalCelebration ad OGNI
  /// aggiornamento GPS in cui l'utente era entro la soglia dall'ultimo
  /// step. Ogni emissione riavviava l'animazione progressiva nel bottom
  /// sheet di arrivo, impedendo a step 2 ("Vuoi rivedere il percorso?")
  /// di apparire. Con il flag, emettiamo UNA SOLA VOLTA.
  bool _hasArrived = false;

  /// Contatore degli aggiornamenti GPS consecutivi in cui l'utente è
  /// entro la soglia di arrivo dall'ultimo step.
  ///
  /// L'arrivo viene confermato solo dopo kArrivalConfirmations letture
  /// consecutive (3 = circa 3 secondi). Questo evita falsi arrivi
  /// causati da salti GPS momentanei.
  int _consecutiveArrivalUpdates = 0;

  /// Parsifica `_originalDestination` nel formato "lat,lng" in una coppia
  /// [lat, lng] di double, oppure null se non disponibile o malformato.
  ///
  /// FIX BUG 4: usato nel rilevamento arrivo come fallback alla
  /// endLocation dell'ultimo step del percorso attivo, che può essere
  /// stata "snapped" da Google a una coordinata leggermente diversa
  /// dopo un ricalcolo.
  List<double>? _parseOriginalDestination() {
    final String? dest = _originalDestination;
    if (dest == null || dest.isEmpty) return null;
    final parts = dest.split(',');
    if (parts.length != 2) return null;
    final double? lat = double.tryParse(parts[0].trim());
    final double? lng = double.tryParse(parts[1].trim());
    if (lat == null || lng == null) return null;
    return [lat, lng];
  }

  // ===========================================================================
  // STATO "SCELTA PERCORSO" — Percorso precedente salvato
  // ===========================================================================
  //
  // Quando il monitor trova un nuovo percorso (Task 2b alternativo o Task 2c
  // ricalcolo API), NON lo impone silenziosamente. Salva il vecchio percorso
  // in queste variabili, applica il nuovo sulla mappa, e la UI mostra un
  // bottom sheet che chiede all'utente: "Vuoi continuare col nuovo percorso
  // o tornare al vecchio?".
  //
  // Se l'utente conferma → _previousRoute viene azzerato.
  // Se l'utente rifiuta → _previousRoute viene ripristinato come attivo.

  /// Percorso precedente (prima del ricalcolo). Null se non c'è stata
  /// nessuna deviazione o l'utente ha già confermato/rifiutato.
  RouteData? _previousRoute;

  /// Step del percorso precedente (per ripristino completo).
  List<DirectionStep> _previousRouteSteps = [];

  /// Indice dello step in cui l'utente si trovava prima del ricalcolo.
  int _previousStepIndex = 0;

  /// Lista di percorsi alternativi del percorso precedente (per ripristino).
  List<RouteData> _previousAlternativeRoutes = [];

  /// Timestamp di quando la navigazione è stata avviata.
  /// Usato per il grace period: nei primi 15 secondi dopo l'avvio,
  /// il controllo di deviazione viene ignorato per dare all'utente
  /// il tempo di mettersi in cammino e allinearsi con la polyline.
  DateTime? _navigationStartTime;

  // ===========================================================================
  // TIMER
  // ===========================================================================

  /// Timer periodico per il campionamento del bearing ogni 5 secondi.
  ///
  /// PERCHÉ UN TIMER PERIODICO:
  /// Vedi commento dettagliato in geo_utils.dart su kBearingUpdateIntervalSec.
  /// In breve: aggiornare direction ad ogni frame GPS causerebbe oscillazioni
  /// rapide. Un campionamento ogni 5 secondi lascia il tempo al bearing di
  /// stabilizzarsi.
  Timer? _bearingTimer;

  /// Timer del countdown di 10 secondi quando la velocità scende a zero.
  ///
  /// GESTIONE SICURA DEL TIMER:
  /// Questo timer viene:
  /// - Avviato solo se non è già attivo (evita countdown multipli)
  /// - Cancellato se la velocità torna sopra soglia (l'utente si è mosso)
  /// - Cancellato in dispose() (l'utente chiude l'app)
  ///
  /// Per evitare race condition, controlliamo sempre _zeroSpeedTimer != null
  /// prima di interagire con esso, e lo settiamo a null dopo la cancellazione.
  Timer? _zeroSpeedTimer;

  /// Timer periodico per il controllo della posizione rispetto al percorso
  /// attivo ogni kRouteCheckIntervalSec secondi (TASK 2).
  ///
  /// Questo timer è SEPARATO dal bearingTimer perché ha una frequenza diversa:
  /// - bearingTimer: ogni 5 secondi (campionamento bearing)
  /// - routeCheckTimer: ogni 2 secondi (controllo deviazione)
  ///
  /// CICLO DI VITA:
  /// - Avviato in startNavigation() quando l'utente inizia a navigare
  /// - Cancellato in stopNavigation() o dispose()
  Timer? _routeCheckTimer;

  /// Flag che indica se il blocco di analisi (steps 2.2→2.6) è in esecuzione.
  /// Evita che un secondo timer scada e lanci un'analisi concorrente mentre
  /// la prima è ancora in corso (la chiamata alla Roads API è asincrona).
  bool _isAnalysisRunning = false;

  // ===========================================================================
  // OUTPUT — NOTIFIER PER L'OVERLAY
  // ===========================================================================

  /// Notifier che emette lo stato dell'overlay da mostrare sulla mappa.
  ///
  /// La UI (NavigationScreen) ascolta questo notifier e mostra/nasconde
  /// l'overlay di conseguenza.
  ///
  /// - value = null → nessun overlay da mostrare
  /// - value = NavigationOverlayState → mostra l'overlay con il messaggio
  ///
  /// Dopo che l'overlay viene mostrato, la UI è responsabile di resettare
  /// il valore a null dopo il timeout (kOverlayAutoDismissSeconds).
  final ValueNotifier<NavigationOverlayState?> overlayNotifier =
      ValueNotifier<NavigationOverlayState?>(null);

  /// Notifier che emette il percorso attivo corrente (TASK 2).
  ///
  /// Questo notifier viene aggiornato ogni volta che il percorso attivo cambia:
  /// - Quando startNavigation() imposta il percorso iniziale (best route)
  /// - Quando Task 2b sostituisce il percorso con un alternativo
  /// - Quando Task 2c ricalcola il percorso via API
  ///
  /// La UI (NavigationScreen) ascolta questo notifier per aggiornare:
  /// - La polyline visualizzata sulla mappa
  /// - Le indicazioni passo-passo
  /// - Distanza e durata totale
  ///
  /// - value = null → nessun percorso attivo (navigazione non avviata)
  /// - value = RouteData → percorso attivo con tutti i dati
  final ValueNotifier<RouteData?> activeRouteNotifier =
      ValueNotifier<RouteData?>(null);

  /// Notifier che comunica in tempo reale alla UI l'indice dello step corrente.
  ///
  /// Questo notifier emette solo un numero intero (`int`), che rappresenta
  /// quale passo (step) l'utente sta percorrendo. Viene usato dal NavigationScreen
  /// per cambiare l'istruzione in alto (es. "Svolta a destra tra 50m")
  /// man mano che l'utente si sposta fisicamente.
  ///
  /// Usiamo un notifier separato (anziché forzare un setState enorme di tutto
  /// lo schermo) per migliorare le performance. Solo il banner in alto
  /// ascolterà questo valore per aggiornarsi fluidamente.
  final ValueNotifier<int> currentStepNotifier = ValueNotifier<int>(0);

  /// Notifier che comunica alla UI la fase corrente del processo di ricalcolo.
  ///
  /// La NavigationScreen ascolta questo notifier per mostrare:
  /// - [offRoute]: bottom sheet "Ricalcolo in corso..." con spinner
  /// - [rerouting]: stessa UI (la chiamata API è in corso)
  /// - [routeChanged]: animazione "Va tutto bene" con conferma
  /// - [none]: nessun bottom sheet (navigazione normale)
  ///
  /// FLUSSO TIPICO:
  /// L'utente devia → offRoute → (cerca alternativo) → rerouting → (API) → routeChanged
  /// L'utente tocca "Mostra il nuovo percorso" → none
  final ValueNotifier<ReroutePhase> reroutePhaseNotifier =
      ValueNotifier<ReroutePhase>(ReroutePhase.none);

  /// FIX BUG 1 + BUG 2 — Notifier che emette il progresso in tempo reale
  /// del percorso attivo: distanza/tempo residui e distanza alla prossima
  /// svolta.
  ///
  /// Viene aggiornato ad ogni chiamata a updatePosition() quando è in
  /// corso una navigazione. Il valore è null quando:
  /// - la navigazione non è ancora stata avviata
  /// - la posizione GPS non è ancora disponibile
  /// - il percorso attivo non ha totalDistanceMeters valido
  ///
  /// La UI (NavigationScreen) ascolta questo notifier per aggiornare:
  /// - Il bottom sheet di navigazione (tempo + distanza totali residui)
  /// - Il banner verde superiore (distanza dinamica alla prossima svolta)
  final ValueNotifier<RouteProgress?> progressNotifier =
      ValueNotifier<RouteProgress?>(null);

  // ===========================================================================
  // SERVIZI
  // ===========================================================================

  /// Client per la Roads API. Iniettato nel costruttore per facilitare il testing.
  final RoadsService _roadsService;

  /// Client per la Directions API. Usato nel Task 2c per ricalcolare il percorso
  /// quando l'utente devia e nessun percorso alternativo è compatibile.
  final DirectionsService _directionsService;

  /// Servizio per la persistenza delle sessioni di navigazione.
  final NavigationSessionService _sessionService;

  /// Sessione di navigazione in corso. Null se la navigazione non è attiva.
  NavigationSession? _currentSession;

  /// Generatore di numeri casuali per variare i messaggi di incoraggiamento.
  /// Usare lo stesso Random per tutta la sessione garantisce una distribuzione
  /// uniforme dei messaggi (non ripete lo stesso 3 volte di fila).
  final Random _random = Random();

  // ===========================================================================
  // COSTRUTTORE
  // ===========================================================================

  /// Crea un nuovo NavigationMonitor e avvia il timer di campionamento del bearing.
  ///
  /// PARAMETRI:
  /// - [roadsService]: (opzionale) istanza di RoadsService. Se non fornita,
  ///   ne crea una nuova. Utile per il testing (si può iniettare un mock).
  /// - [directionsService]: (opzionale) istanza di DirectionsService. Se non
  ///   fornita, ne crea una nuova. Usata per il ricalcolo percorso (Task 2c).
  /// - [sessionService]: (opzionale) istanza di NavigationSessionService. Se non
  ///   fornita, ne crea una nuova. Usata per la persistenza delle sessioni.
  NavigationMonitor({
    RoadsService? roadsService,
    DirectionsService? directionsService,
    NavigationSessionService? sessionService,
  }) : _roadsService = roadsService ?? RoadsService(),
       _directionsService = directionsService ?? DirectionsService(),
       _sessionService = sessionService ?? NavigationSessionService() {
    // Avvia subito il timer periodico per il campionamento del bearing
    _startBearingTimer();
  }

  // ===========================================================================
  // METODI PUBBLICI
  // ===========================================================================

  /// Aggiorna la posizione, la velocità e il bearing raw dell'utente.
  ///
  /// Questo metodo viene chiamato ad ogni aggiornamento GPS dal listener
  /// in NavigationScreen. Gestisce:
  /// 1. Salvataggio dei valori correnti
  /// 2. Logica del trigger velocità-zero (avvio/cancellazione del timer 10s)
  ///
  /// PARAMETRI:
  /// - [lat]: latitudine corrente
  /// - [lng]: longitudine corrente
  /// - [speedKmH]: velocità corrente in km/h (già convertita da m/s)
  /// - [rawBearing]: bearing GPS raw in gradi (0-360)
  ///
  /// SIDE EFFECTS:
  /// - Aggiorna le variabili interne
  /// - Può avviare o cancellare il timer di 10 secondi
  void updatePosition(
    double lat,
    double lng,
    double speedKmH,
    double rawBearing, [
    double accuracy = 0.0,
  ]) {
    // TASK 5 - Filtro Globale Accuratezza GPS
    // Se il segnale GPS è troppo debole (accuracy > 30m), ignoriamo
    // completamente l'aggiornamento per evitare "salti" fittizi che
    // innescherebbero falsi calcoli (strade laterali, avanzamento step).
    if (accuracy > 30.0) {
      print('⚠️ GPS precisione insufficiente (${accuracy}m). Update ignorato.');
      return;
    }

    // Salva i valori correnti. Queste variabili sono usate dal timer del
    // bearing (ogni 5s) e dallo snapshot (quando il timer 10s scade).
    _currentLat = lat;
    _currentLng = lng;
    _currentSpeed = speedKmH;
    _rawBearing = rawBearing;
    _currentAccuracy = accuracy;

    // --- LOGICA TRIGGER VELOCITÀ ZERO (Step 2.1) ---
    //
    // Quando la velocità scende sotto 1 km/h, l'utente è considerato "fermo".
    // Avvia un countdown di 10 secondi. Se la velocità torna sopra soglia
    // prima dello scadere, il timer viene cancellato.
    //
    // PERCHÉ QUESTO DELAY:
    // Senza il delay, ogni breve fermata (semaforo rosso, ingorgo, precedenza)
    // attiverebbe l'analisi delle strade laterali, causando:
    // 1. Falsi positivi visivi (l'overlay appare quando non serve)
    // 2. Chiamate API inutili (ogni analisi chiama la Roads API)
    // 3. Distrazione per l'utente, che è un problema critico per un'app
    //    destinata a persone con disabilità cognitive

    if (speedKmH < kZeroSpeedThresholdKmH) {
      // L'utente è fermo. Avvia il countdown SOLO se non è già attivo.
      // Controllare _zeroSpeedTimer != null evita di creare timer multipli
      // che causerebbero analisi duplicate.
      if (_zeroSpeedTimer == null && !_isAnalysisRunning) {
        print(
          '⏱️ OVERLAY DEBUG: Velocità ${speedKmH.toStringAsFixed(1)} km/h < soglia. '
          'Avvio countdown ${kZeroSpeedDelayMs}ms...',
        );
        _startZeroSpeedCountdown();
      }
    } else {
      // Se l'utente si è rimesso in moto. Cancella il countdown se era attivo.
      // Questo gestisce il caso classico: l'utente si ferma al semaforo,
      // il semaforo diventa verde dopo 5 secondi, l'utente riparte.
      // Senza questa cancellazione, il timer continuerebbe a contare e
      // l'analisi partirebbe anche se l'utente è in movimento.
      if (_zeroSpeedTimer != null) {
        print(
          '🏃 OVERLAY DEBUG: Velocità ${speedKmH.toStringAsFixed(1)} km/h — '
          'utente in moto, ANNULLO countdown.',
        );
      }
      _cancelZeroSpeedCountdown();
    }

    // --- LOGICA AVANZAMENTO STEP DINAMICO ---
    //
    // Questa procedura controlla se l'utente sta raggiungendo la fine
    // della via in cui si trova, per dirgli di compiere la svolta successiva.
    // Viene eseguita ad ogni singolo aggiornamento GPS, fintanto che
    // ci sono step validi ed è attiva una rotta.
    //
    // FIX BUG 4 — AVANZAMENTO BASATO SU PROIEZIONE ORTOGONALE:
    // Avanziamo lo step quando la proiezione del punto utente sul segmento
    // [step.start, step.end] cade OLTRE la fine (parametro t >= 1.0) e la
    // distanza laterale dal segmento è entro la soglia di deviazione.
    //
    // Vantaggi rispetto alle soglie scalari (versione precedente):
    //  1. "Cambia troppo presto" risolto: serve attraversare il vertice in
    //     proiezione, non basta avvicinarsi geometricamente.
    //  2. "Non cambia subito dopo" risolto: t scatta a 1.0 al momento esatto
    //     dell'attraversamento (a piedi, ~1 GPS update = 1-2s di latenza).
    //  3. Funziona anche con svolte a 90° dove la distanza scalare cresce
    //     lentamente (geometria tangenziale).
    //
    // Conferma su 2 letture consecutive per filtrare jitter GPS.
    // Lo Stall Timer (15s a velocità ~0) resta come fallback per chi
    // resta fermo prima di una svolta (es. coda al semaforo).
    if (_activeRoute != null && _routeSteps.isNotEmpty) {
      // Flag per sapere se abbiamo avanzato almeno uno step in questo ciclo
      bool didAdvance = false;

      // While loop: continua ad avanzare finché lo step corrente risulta
      // "superato" E c'è un prossimo step.
      while (_currentStepIndex < _routeSteps.length) {
        final currentStep = _routeSteps[_currentStepIndex];

        // Distanza geodetica tra la posizione GPS e la fine dello step corrente
        final double distanceToEnd = distanceBetween(
          lat,
          lng,
          currentStep.endLat,
          currentStep.endLng,
        );

        // --- CASO A: step intermedi (non l'ultimo) ---
        if (_currentStepIndex + 1 < _routeSteps.length) {
          // FIX BUG 4 — TIMING DI AVANZAMENTO PRECISO
          //
          // Strategia in cascata:
          //   1. NEXT-SEG-MATCH (B4.6): se l'utente è già geometricamente
          //      sul segmento successivo (t∈[0.05,1] e lateral≤12m), avanza
          //      subito. Risolve le svolte secche dove t del segmento
          //      corrente oscilla attorno a 1.0 per disturbo trigonometrico.
          //   2. OVERSHOOT (B4.2): se t≥1.15 con lateral≤12m → advance in 1
          //      lettura (overshoot inequivocabile, non serve 2ª conferma).
          //   3. PROJECTED-PAST CONFIRMED (B4.2): se t∈[1.0,1.15) e
          //      lateral≤12m → 2 letture consecutive prima di avanzare.
          //   4. HYSTERESIS (B4.2): non resettare il counter finché t<0.92
          //      (zona di disambiguazione). Evita il "ping-pong" sui jitter
          //      GPS attorno alla soglia.
          //
          // Differenze chiave vs versione precedente:
          //   - Soglia laterale 12m (kStepAdvanceLateralThresholdMeters)
          //     invece di 30m (kRouteDeviationThresholdMeters): evita
          //     l'avanzamento prematuro quando l'utente è su via parallela.
          //   - Hysteresis impedisce reset spuri del counter.
          //   - Next-seg match risolve il caso "t resta sotto 1.0 sulla
          //     svolta secca" che bloccava l'avanzamento per 5-10s.
          final SegmentProjection proj = projectPointOnSegment(
            lat,
            lng,
            currentStep.startLat,
            currentStep.startLng,
            currentStep.endLat,
            currentStep.endLng,
          );

          // Approach: utente è negli ultimi 15m della endLocation. Stato
          // informativo, usato anche per gatekeeper dello stall timer.
          if (distanceToEnd < 15.0 && !_wasCloseToStepEnd) {
            print(
              '📍 APPROACH: utente vicino all\'endLoc step $_currentStepIndex '
              '(${distanceToEnd.toStringAsFixed(1)}m, t=${proj.t.toStringAsFixed(2)})',
            );
            _wasCloseToStepEnd = true;
          }

          final bool onSegment =
              proj.lateralDistanceMeters <= kStepAdvanceLateralThresholdMeters;

          // --- STRATEGIA 1: NEXT-SEG-MATCH (FIX B4.6 + multi-skip) ---
          // Calcoliamo la proiezione sul segmento successivo. Se l'utente è
          // GIÀ all'inizio del prossimo segmento (con t≥0.05 per evitare il
          // match sull'esatto vertice di giunzione), avanziamo subito.
          //
          // FIX MULTI-SKIP: rimosso il limite superiore `t ≤ 1.0`. Se dopo
          // un gap GPS l'utente è oltre il prossimo segmento (t > 1.0), ma
          // ancora geometricamente coerente (lateral ≤ 12m sulla retta del
          // segmento), avanziamo comunque. Il while loop poi rivaluterà lo
          // step dopo, generando un secondo advance se anche quel segmento
          // è stato superato. Così copriamo i recovery dopo gallerie/buchi.
          final nextStep = _routeSteps[_currentStepIndex + 1];
          final SegmentProjection nextProj = projectPointOnSegment(
            lat,
            lng,
            nextStep.startLat,
            nextStep.startLng,
            nextStep.endLat,
            nextStep.endLng,
          );
          final bool nextSegMatch = nextProj.t >= 0.05 &&
              nextProj.lateralDistanceMeters <=
                  kStepAdvanceLateralThresholdMeters;
          if (nextSegMatch) {
            print(
              '📍 NEXT-SEG-MATCH: step $_currentStepIndex → '
              '${_currentStepIndex + 1} '
              '(next t=${nextProj.t.toStringAsFixed(2)}, '
              'lat=${nextProj.lateralDistanceMeters.toStringAsFixed(1)}m)',
            );
            _advanceStepLocal(lat, lng, reason: 'next-seg-match');
            didAdvance = true;
            continue;
          }

          // --- STRATEGIA 2: OVERSHOOT (FIX B4.2) ---
          if (proj.t >= 1.15 && onSegment) {
            print(
              '📍 PROJ-OVERSHOOT: step $_currentStepIndex — '
              't=${proj.t.toStringAsFixed(2)} (≥1.15) → advance immediato',
            );
            _advanceStepLocal(lat, lng, reason: 'overshoot');
            didAdvance = true;
            continue;
          }

          // --- STRATEGIA 3: PROJECTED-PAST con conferma (zona [1.0, 1.15)) ---
          if (proj.t >= 1.0 && onSegment) {
            _consecutiveCloseUpdates++;
            print(
              '📍 PROJ-PAST: step $_currentStepIndex — '
              't=${proj.t.toStringAsFixed(2)}, '
              'lat=${proj.lateralDistanceMeters.toStringAsFixed(1)}m '
              '(conferma $_consecutiveCloseUpdates/2)',
            );
            if (_consecutiveCloseUpdates >= 2) {
              _advanceStepLocal(lat, lng, reason: 'projected-past-confirmed');
              didAdvance = true;
              continue;
            }
            break;
          }

          // --- STRATEGIA 4: HYSTERESIS (FIX B4.2) ---
          // Reset del counter SOLO se ben sotto la soglia. Tra 0.92 e 1.0
          // tratteniamo il counter così un singolo jitter sotto 1.0 non
          // azzera la conferma in corso.
          if (proj.t < 0.92) {
            _consecutiveCloseUpdates = 0;
          }

          // --- STRATEGIA 5: LOOKAHEAD MULTI-STEP (recovery profondo) ---
          //
          // PROBLEMA: dopo gap GPS lungo (es. galleria, indoor a inizio
          // navigazione) l'utente può ricomparire OLTRE 2+ segmenti dal
          // currentStep. Le strategie 1-3 non scattano:
          //  - step+1 next-seg-match: t può essere >1 e lateral grande
          //    (clamped projection cade sull'endpoint di step+1, che è
          //    distante dall'utente reale).
          //  - strategia 2/3 (sul current): onSegment FALSE per lat alta.
          // → currentStep resta indietro per tutto il percorso.
          //
          // SOLUZIONE: scansione di al massimo +3 step in avanti. Per
          // ciascuno, calcoliamo la proiezione sul SUO segmento. Se uno
          // di questi ha t∈[0.05, 1.0] e lateral≤12m, l'utente è
          // realmente su quello step → avanziamo step-by-step fino a
          // raggiungerlo. Limite +3 evita salti in avanti irrealistici
          // dovuti a errori GPS estremi (utente teletrasportato).
          const int kMaxLookaheadSteps = 3;
          int? lookaheadTargetIdx;
          for (int i = _currentStepIndex + 1;
              i < _routeSteps.length &&
                  i <= _currentStepIndex + kMaxLookaheadSteps;
              i++) {
            final lookStep = _routeSteps[i];
            // Skip step degeneri: la proiezione è instabile.
            final double segLen = haversineDistance(
              lookStep.startLat,
              lookStep.startLng,
              lookStep.endLat,
              lookStep.endLng,
            );
            if (segLen < 2.0) continue;

            final SegmentProjection lookProj = projectPointOnSegment(
              lat,
              lng,
              lookStep.startLat,
              lookStep.startLng,
              lookStep.endLat,
              lookStep.endLng,
            );
            if (lookProj.t >= 0.05 &&
                lookProj.t <= 1.0 &&
                lookProj.lateralDistanceMeters <=
                    kStepAdvanceLateralThresholdMeters) {
              lookaheadTargetIdx = i;
              break; // Prendiamo il PRIMO match (più vicino al current)
            }
          }
          if (lookaheadTargetIdx != null) {
            print(
              '📍 LOOKAHEAD: $_currentStepIndex → $lookaheadTargetIdx '
              '(utente già su step futuro, recovery dopo gap)',
            );
            // Avanziamo step-per-step così _verifyAdvancementCoherence
            // viene chiamato per ogni transizione (logging diagnostico).
            while (_currentStepIndex < lookaheadTargetIdx) {
              _advanceStepLocal(lat, lng, reason: 'lookahead');
            }
            didAdvance = true;
            continue;
          }

          // --- STALL TIMER (FIX B4.4): utente fermo nella "zona morta" ---
          //
          // Se l'utente è praticamente fermo (speedKmH < 2 km/h) E si trova
          // nella zona 15-35m dalla svolta, l'istruzione resterebbe bloccata
          // per sempre (es. coda a semaforo). Avanziamo dopo 15s di stallo,
          // MA solo se la verifica direzionale conferma che il next-step è
          // più vicino del cur-step end. Vedi _onStallTimerExpired.
          if (speedKmH < 2.0 &&
              distanceToEnd >= 15.0 &&
              distanceToEnd <= 35.0 &&
              !_wasCloseToStepEnd) {
            if (_stallTimer == null) {
              print(
                '⏱️ STALL: utente fermo a ${distanceToEnd.toStringAsFixed(1)}m '
                'dalla svolta — avvio stall timer (15s)',
              );
              _stallTimer =
                  Timer(const Duration(seconds: 15), _onStallTimerExpired);
            }
          } else {
            _stallTimer?.cancel();
            _stallTimer = null;
          }

          break; // Ancora dentro il segmento corrente
        }
        // --- CASO B: ULTIMO step → rilevamento ARRIVO ---
        //
        // SOGLIA PIÙ STRETTA (20m invece di 40m):
        // L'arrivo è un evento irreversibile e importante. A 40m il ragazzo
        // può essere ancora in mezzo a una strada, non davanti alla destinazione.
        // 20m con GPS accuracy tipica (5-15m) è un buon compromesso.
        //
        // CONFERMA MULTIPLA (3 letture consecutive):
        // Evitiamo falsi arrivi da salti GPS. 3 letture a ~1 GPS/sec =
        // circa 3 secondi di permanenza entro la soglia.
        //
        // FLAG _hasArrived:
        // L'arrivo viene emesso UNA SOLA VOLTA. Senza questo flag,
        // ogni aggiornamento GPS successivo riemetteva arrivalCelebration,
        // resettando l'animazione del bottom sheet e impedendo a
        // "Vuoi rivedere il percorso?" di apparire (step 2 mai raggiunto).
        //
        // FIX BUG 4 — ANCORAGGIO DOPPIO ALLA DESTINAZIONE:
        // Dopo un ricalcolo percorso, Google può fare snap della destinazione
        // a una coordinata leggermente diversa da quella originale
        // selezionata dall'utente. In quel caso, distanceToEnd (verso
        // l'endLocation dell'ULTIMO step del nuovo percorso) può rimanere
        // sempre > 20m anche se l'utente è fisicamente dove voleva andare.
        // Usiamo la DISTANZA MINIMA tra end-step e destinazione-originale
        // parsata: così scatta l'arrivo indipendentemente da quale delle
        // due coordinate l'utente raggiunge per prima.
        else {
          if (_hasArrived) {
            break; // Già emesso, non ripetere
          }

          // Distanza dall'endLocation dell'ultimo step (default)
          double arrivalDistance = distanceToEnd;

          // Se c'è una destinazione originale salvata e parsabile,
          // considera anche quella come candidato di arrivo.
          final List<double>? origDest = _parseOriginalDestination();
          if (origDest != null) {
            final double distToOriginal = distanceBetween(
              lat,
              lng,
              origDest[0],
              origDest[1],
            );
            if (distToOriginal < arrivalDistance) {
              arrivalDistance = distToOriginal;
            }
          }

          if (arrivalDistance < 20.0) {
            _consecutiveArrivalUpdates++;
            print(
              '📍 ARRIVO DEBUG: entro 20m dalla destinazione '
              '(${arrivalDistance.toStringAsFixed(1)}m, '
              'conferma $_consecutiveArrivalUpdates/3)',
            );

            if (_consecutiveArrivalUpdates >= 3) {
              // ARRIVO CONFERMATO! L'utente è a destinazione.
              _hasArrived = true;
              _currentSession?.destinationReached = true;
              final String arrivalMsg =
                  kArrivalMessages[_random.nextInt(kArrivalMessages.length)];
              print("🎉 Navigazione ultimata! Messaggio: $arrivalMsg");
              final arrivalOverlay = NavigationOverlayState(
                type: OverlayType.arrivalCelebration,
                message: arrivalMsg,
              );
              overlayNotifier.value = arrivalOverlay;
              _recordOverlayEvent(arrivalOverlay);
            }
          } else {
            // Troppo lontano dalla destinazione: resetta le conferme
            _consecutiveArrivalUpdates = 0;
          }
          break;
        }
      }

      // Se abbiamo avanzato, notifica la UI una sola volta con l'indice finale.
      // Questo è più efficiente che notificare ad ogni singolo skip.
      if (didAdvance) {
        _consecutiveCloseUpdates = 0;
        currentStepNotifier.value = _currentStepIndex;
        print(
          '📍 Step avanzato → $_currentStepIndex '
          '(${_routeSteps[_currentStepIndex].instruction})',
        );
      }

      // FIX BUG 1 + BUG 2 — Calcolo progresso in tempo reale
      //
      // Dopo aver eventualmente avanzato _currentStepIndex, calcoliamo:
      //   - distanceToNextTurn: distanza dall'utente all'endLocation dello
      //     step corrente (= alla prossima svolta da effettuare).
      //   - remainingMeters: somma delle distanze degli step successivi +
      //     distanza parziale all'endLocation dello step corrente.
      //   - remainingSeconds: proporzionale alla distanza residua, usando
      //     la velocità media del percorso originale (metri/secondo).
      //
      // Il calcolo è stabile: non usa la velocità istantanea (che oscilla
      // a basse velocità) ma il rapporto distanza_totale/durata_totale,
      // lo stesso che la Directions API ha usato inizialmente.
      _emitRouteProgress(lat, lng);
    }
  }

  // ===========================================================================
  // FIX BUG 4 — HELPER DI AVANZAMENTO STEP
  // ===========================================================================

  /// Avanza lo step corrente di 1 e resetta i flag locali. Non aggiorna
  /// `currentStepNotifier`: la pubblicazione viene fatta una volta sola in
  /// fondo al while loop (più efficiente di N notifiche per N skip).
  ///
  /// Esegue anche la verifica di coerenza geometrica: se la posizione
  /// dell'utente non è plausibile sul nuovo segmento, log warning (il
  /// rerouter prenderà in carico la deviazione).
  void _advanceStepLocal(
    double lat,
    double lng, {
    required String reason,
  }) {
    _stallTimer?.cancel();
    _stallTimer = null;
    _currentStepIndex++;
    _wasCloseToStepEnd = false;
    _consecutiveCloseUpdates = 0;
    print('📍 ADVANCE → $_currentStepIndex (reason: $reason)');
    _verifyAdvancementCoherence(lat, lng);
  }

  /// Verifica che dopo l'avanzamento la posizione utente sia coerente con
  /// il nuovo segmento. Loga un warning ma NON ripristina l'indice: la
  /// gestione della deviazione è già coperta dal sistema di reroute.
  void _verifyAdvancementCoherence(double lat, double lng) {
    if (_currentStepIndex >= _routeSteps.length) return;
    final newStep = _routeSteps[_currentStepIndex];
    final SegmentProjection proj = projectPointOnSegment(
      lat,
      lng,
      newStep.startLat,
      newStep.startLng,
      newStep.endLat,
      newStep.endLng,
    );
    if (proj.lateralDistanceMeters > kRouteDeviationThresholdMeters &&
        proj.t > 0.5) {
      print(
        '⚠️ ADVANCE INCOERENTE: utente non sul nuovo segmento '
        '(lat-dist=${proj.lateralDistanceMeters.toStringAsFixed(1)}m, '
        't=${proj.t.toStringAsFixed(2)}). '
        'Il rerouter dovrebbe rilevare la deviazione.',
      );
    }
  }

  /// Callback dello stall timer (15s). FIX B4.4: avanziamo SOLO se il
  /// next-step start è più vicino della current-step end. Altrimenti
  /// significa che l'utente è andato indietro o si è fermato in posizione
  /// anomala (es. intersezione complessa, strada interrotta) — avanzare
  /// sarebbe scorretto e produrrebbe istruzioni errate persistenti.
  void _onStallTimerExpired() {
    _stallTimer = null;
    if (_currentStepIndex >= _routeSteps.length) return;

    final double? lat = _currentLat;
    final double? lng = _currentLng;
    if (lat == null || lng == null) {
      print('⏱️ STALL: timer scaduto ma posizione GPS null — skip');
      return;
    }

    final cur = _routeSteps[_currentStepIndex];
    final int nextIdx = _currentStepIndex + 1;
    final bool hasNext = nextIdx < _routeSteps.length;

    final double distCurEnd = haversineDistance(
      lat,
      lng,
      cur.endLat,
      cur.endLng,
    );
    final double distNextStart = hasNext
        ? haversineDistance(
            lat,
            lng,
            _routeSteps[nextIdx].startLat,
            _routeSteps[nextIdx].startLng,
          )
        : double.infinity;

    if (!hasNext || distNextStart < distCurEnd) {
      print(
        '⏱️ STALL: avanzamento applicato '
        '(next-start=${distNextStart.toStringAsFixed(1)}m '
        '< cur-end=${distCurEnd.toStringAsFixed(1)}m)',
      );
      _currentStepIndex++;
      _wasCloseToStepEnd = false;
      _consecutiveCloseUpdates = 0;
      currentStepNotifier.value = _currentStepIndex;
      _verifyAdvancementCoherence(lat, lng);
    } else {
      print(
        '⏱️ STALL: avanzamento NON applicato — utente più vicino alla fine '
        'corrente (${distCurEnd.toStringAsFixed(1)}m) '
        'che al next-start (${distNextStart.toStringAsFixed(1)}m). '
        'Possibile deviazione: il rerouter prenderà in carico.',
      );
    }
  }

  /// FIX BUG 1 + BUG 2 — Calcola e pubblica il RouteProgress corrente.
  ///
  /// Chiamato alla fine di updatePosition(), quando la posizione e
  /// l'indice dello step corrente sono aggiornati.
  ///
  /// REGOLE DI STABILITÀ:
  /// - Non pubblichiamo nulla se il percorso attivo non ha dati
  ///   numerici validi (totalDistanceMeters <= 0).
  /// - Clampiamo `distanceToNextTurn` a zero per evitare micro-valori
  ///   negativi dovuti ad arrotondamenti.
  /// - Il tempo residuo è calcolato da: velocità_media_percorso *
  ///   distanza_residua. Questo fornisce stime coerenti con quelle
  ///   mostrate inizialmente dall'API.
  void _emitRouteProgress(double lat, double lng) {
    final RouteData? route = _activeRoute;
    if (route == null) return;
    if (_routeSteps.isEmpty) return;
    if (route.totalDistanceMeters <= 0) {
      // Senza dati numerici totali non possiamo calcolare il tempo
      // proporzionale — non emettiamo nulla.
      return;
    }

    // Clamp dell'indice corrente al range valido
    final int idx = _currentStepIndex < _routeSteps.length
        ? _currentStepIndex
        : _routeSteps.length - 1;
    final DirectionStep currentStep = _routeSteps[idx];

    // Distanza alla prossima svolta = distanza dall'utente all'endLocation
    // dello step corrente (next turn = fine tratto attuale).
    final double distToNext = distanceBetween(
      lat,
      lng,
      currentStep.endLat,
      currentStep.endLng,
    );

    // Distanza residua lungo il percorso = distanza parziale nello step
    // corrente + somma delle distanze degli step successivi.
    double remaining = distToNext;
    for (int i = idx + 1; i < _routeSteps.length; i++) {
      remaining += _routeSteps[i].distanceMeters.toDouble();
    }
    if (remaining < 0) remaining = 0;

    // Tempo residuo stimato proporzionale alla distanza residua.
    // velocità_media = totalDistanceMeters / totalDurationSeconds
    // tempo_residuo = remaining / velocità_media = remaining *
    //                 totalDurationSeconds / totalDistanceMeters
    final int totalDist = route.totalDistanceMeters;
    final int totalDur = route.totalDurationSeconds;
    int remainingSec;
    if (totalDist > 0 && totalDur > 0) {
      remainingSec = (remaining * totalDur / totalDist).round();
    } else {
      remainingSec = 0;
    }
    if (remainingSec < 0) remainingSec = 0;

    // FIX BUG 4 — Minimum instruction interval (500ms)
    // Evita aggiornamenti troppo rapidi dell'istruzione che confonderebbero
    // l'utente. Dopo una svolta, la nuova istruzione non deve apparire
    // prima di 500ms (tempo minimo per leggere/assimilare).
    if (_lastInstructionTime != null) {
      final elapsed = DateTime.now().difference(_lastInstructionTime!).inMilliseconds;
      if (elapsed < 500) {
        // Skip this update, UI already showing current instruction
        return;
      }
    }

    // Pubblica il progresso aggiornato
    progressNotifier.value = RouteProgress(
      remainingMeters: remaining,
      remainingSeconds: remainingSec,
      remainingDistanceText: _formatDistance(remaining),
      remainingDurationText: _formatDuration(remainingSec),
      distanceToNextTurn: distToNext.clamp(0.0, double.infinity),
    );

    // Aggiorna il timestamp dell'ultima istruzione emessa
    _lastInstructionTime = DateTime.now();
  }

  /// Formatta una distanza in metri come stringa human-readable.
  /// Esempi: 750 → "750 m", 1200 → "1,2 km", 12500 → "12 km".
  String _formatDistance(double meters) {
    if (meters < 1000) {
      return '${meters.round()} m';
    } else if (meters < 10000) {
      // Sotto 10 km mostriamo un decimale (es. "1,2 km"), virgola it-IT.
      final double km = meters / 1000.0;
      return '${km.toStringAsFixed(1).replaceAll('.', ',')} km';
    } else {
      return '${(meters / 1000.0).round()} km';
    }
  }

  /// Formatta una durata in secondi come stringa human-readable.
  /// Esempi: 45 → "1 min", 300 → "5 min", 3900 → "1 h 5 min".
  String _formatDuration(int seconds) {
    if (seconds < 60) {
      return '1 min'; // Minimo user-friendly, "0 min" è strano
    }
    final int totalMin = (seconds / 60).round();
    if (totalMin < 60) {
      return '$totalMin min';
    }
    final int h = totalMin ~/ 60;
    final int m = totalMin % 60;
    if (m == 0) return '$h h';
    return '$h h $m min';
  }

  /// Aggiorna la lista degli step del percorso.
  ///
  /// Chiamato quando l'utente calcola un nuovo percorso tramite la
  /// Directions API. Gli step vengono usati nel Step 2.3 per verificare
  /// se l'utente è vicino a un waypoint di svolta.
  ///
  /// PARAMETRI:
  /// - [steps]: lista di DirectionStep dal risultato della Directions API
  void updateRouteSteps(List<DirectionStep> steps) {
    _routeSteps = steps;
  }

  /// Getter pubblico per il bearing affidabile corrente.
  /// Restituisce null se nessun bearing affidabile è stato ancora acquisito.
  double? get direction => _direction;

  /// Avvia la navigazione con i percorsi ricevuti dalla Directions API (TASK 2).
  ///
  /// Questo metodo inizializza tutto il sistema di monitoraggio del percorso:
  /// 1. Salva il percorso migliore come "attivo" (quello visualizzato sulla mappa)
  /// 2. Salva tutti i percorsi alternativi per il confronto rapido (Task 2b)
  /// 3. Salva la destinazione originale come COORDINATE per i ricalcoli futuri
  /// 4. Aggiorna gli step del percorso per il check dei waypoint di svolta
  /// 5. Avvia il timer periodico a 2 secondi per il monitoraggio
  /// 6. Registra il timestamp di avvio per il grace period (15s)
  ///
  /// PARAMETRI:
  /// - [routesResult]: risultato dalla API con tutti i percorsi
  /// - [destinationCoords]: coordinate della destinazione nel formato
  ///   "lat,lng" (es. "45.478,9.234"). DEVE essere in formato coordinate,
  ///   NON un indirizzo testuale, per evitare ri-geocodifiche nei ricalcoli.
  ///
  /// SIDE EFFECTS:
  /// - Setta _isNavigating = true
  /// - Avvia il timer _routeCheckTimer
  /// - Notifica la UI tramite activeRouteNotifier
  void startNavigation(AllRoutesResult routesResult, String destinationCoords) {
    // Salva il percorso migliore (quello con durata minore) come attivo
    _activeRoute = routesResult.bestRoute;

    // Salva TUTTI i percorsi (compreso quello attivo) per il check Task 2b.
    // Quando l'utente devia, itereremo su questa lista per cercare un
    // percorso alternativo a cui "agganciare" la posizione dell'utente.
    _alternativeRoutes = List<RouteData>.from(routesResult.allRoutes);

    // FIX 1: Salva la destinazione come COORDINATE (es. "45.478,9.234").
    // Prima salvava il testo dell'indirizzo (es. "Via Roma, Milano"),
    // e ogni ricalcolo doveva ri-geocodare il testo, ottenendo punti
    // leggermente diversi → polyline diversa → falsi ricalcoli a catena.
    _originalDestination = destinationCoords;

    // Aggiorna gli step per la logica di check waypoint di svolta (Step 2.3)
    _routeSteps = routesResult.bestRoute.steps;

    // Imposta il flag di navigazione attiva
    _isNavigating = true;

    // Crea una nuova sessione di tracciamento per questa navigazione.
    // L'ID è costruito come timestamp epoch in ms per semplicità (non richiede
    // dipendenze esterne come uuid) garantendo comunque unicità pratica.
    _currentSession = NavigationSession(
      sessionId: DateTime.now().millisecondsSinceEpoch.toString(),
      destination: destinationCoords,
      startTime: DateTime.now().toIso8601String(),
    );

    // Resetta lo stato di arrivo per una nuova navigazione
    _hasArrived = false;
    _consecutiveArrivalUpdates = 0;

    // Resetta la progressione step
    _currentStepIndex = 0;
    _consecutiveCloseUpdates = 0;
    _wasCloseToStepEnd = false; // FIX BUG 2: reset stato approach-then-leave
    currentStepNotifier.value = 0;
    _consecutiveOffRouteDetects = 0;
    _routeCheckTicks = 0;

    // FIX 3: Registra il momento di avvio della navigazione.
    // I primi 15 secondi sono un "grace period" in cui il controllo
    // di deviazione viene saltato, per dare all'utente il tempo di
    // mettersi in cammino e allinearsi con la polyline.
    _navigationStartTime = DateTime.now();

    // Notifica la UI che il percorso attivo è stato impostato.
    // La UI aggiornerà la polyline sulla mappa e le indicazioni.
    activeRouteNotifier.value = _activeRoute;

    // Avvia il timer periodico che ogni 2 secondi controlla se l'utente
    // è ancora sul percorso attivo (Task 2a → 2b → 2c)
    _startRouteCheckTimer();

    // Log per debugging
    print(
      'Navigazione avviata. Percorsi disponibili: '
      '${_alternativeRoutes.length}. '
      'Percorso attivo: ${_activeRoute!.totalDuration}',
    );
  }

  /// Ferma la navigazione e cancella il timer di controllo percorso.
  ///
  /// Chiamato quando l'utente vuole interrompere la navigazione
  /// o quando la navigazione raggiunge la destinazione.
  ///
  /// FIX: Ora cancella anche il _zeroSpeedTimer e resetta _isAnalysisRunning.
  /// Prima, se il timer di 10s era partito prima del "Termina", continuava
  /// a girare e poteva emettere un overlay fantasma dopo lo stop.
  void stopNavigation() {
    print(
      '🛑 stopNavigation INIZIO: _currentSession è ${_currentSession == null ? 'NULL' : 'VALIDA'}',
    );

    // GUARD: se stopNavigation viene chiamato senza startNavigation,
    // _currentSession è null e non facciamo nulla.
    if (_currentSession == null) {
      print('🛑 stopNavigation SKIP: nessuna sessione attiva');
      return;
    }

    print(
      '🛑 stopNavigation: Sessione ha ${_currentSession!.overlays.length} overlay e ${_currentSession!.rerouteCount} ricalcoli',
    );

    // Cancella PRIMA il timer e il countdown per garantire che nessun
    // overlay venga registrato dopo il salvataggio della sessione.
    // Se non lo facessimo, il timer potrebbe completare un ciclo e registrare
    // un overlay DOPO che _currentSession diventa null (riga "nulling"),
    // causando perdita di dati (gli overlay non verrebbero salvati).
    _isNavigating = false;
    _routeCheckTimer?.cancel();
    _routeCheckTimer = null;
    _cancelZeroSpeedCountdown();
    _isAnalysisRunning = false;

    // Imposta l'ora di fine e salva la sessione con tutti gli overlay/ricalcoli
    // registrati finora. A questo punto, nessun nuovo overlay può arrivare
    // perché il timer è stato cancellato.
    _currentSession!.endTime = DateTime.now().toIso8601String();
    print('🛑 stopNavigation: Salvataggio sessione in corso...');
    // Salvataggio asincrono: non blocchiamo il thread principale.
    // unawaited è implicito — l'errore è già gestito dentro saveSession.
    _sessionService.saveSession(_currentSession!);
    _currentSession = null;
    print('🛑 stopNavigation: Sessione azzerata');

    // Resetta lo stato dei percorsi
    _activeRoute = null;
    _alternativeRoutes = [];
    _originalDestination = null;
    _consecutiveOffRouteDetects = 0;
    _routeCheckTicks = 0;
    _returnToRouteLockUntil = null;

    // Resetta lo stato di tracciamento degli Step
    _currentStepIndex = 0;
    _consecutiveCloseUpdates = 0;
    _wasCloseToStepEnd = false; // FIX BUG 2: reset stato approach-then-leave
    currentStepNotifier.value = 0;

    // Resetta lo stato di arrivo
    _hasArrived = false;
    _consecutiveArrivalUpdates = 0;

    // Resetta l'overlay: se un overlay era visibile, lo rimuoviamo
    // per evitare che resti appeso dopo lo stop.
    overlayNotifier.value = null;

    // FIX BUG 1+2: azzera il progress notifier quando la navigazione
    // termina, così la UI non mostra valori vecchi.
    progressNotifier.value = null;

    // Resetta le variabili di cooldown spaziale dell'analisi
    _lastAnalysisLat = null;
    _lastAnalysisLng = null;
    _lastApiCallTime = null;

    // Resetta la fase di ricalcolo (chiude eventuali bottom sheet aperti)
    reroutePhaseNotifier.value = ReroutePhase.none;

    // Resetta il percorso precedente salvato (scelta utente non più necessaria)
    _previousRoute = null;
    _previousRouteSteps = [];
    _previousStepIndex = 0;
    _previousAlternativeRoutes = [];

    // Notifica la UI che non c'è più un percorso attivo
    activeRouteNotifier.value = null;

    // Log per debugging
    print('Navigazione fermata. Timer e overlay azzerati.');
  }

  // ===========================================================================
  // SCELTA PERCORSO — CONFERMA O RIPRISTINO
  // ===========================================================================

  /// L'utente ha scelto di CONTINUARE con il nuovo percorso.
  ///
  /// Il nuovo percorso è GIÀ attivo (applicato al momento del ricalcolo),
  /// quindi qui ci limitiamo a:
  /// 1. Cancellare il backup del vecchio percorso (non serve più)
  /// 2. Chiudere il bottom sheet di scelta
  /// 3. Resettare i contatori di deviazione per il nuovo percorso
  void confirmNewRoute() {
    print('✅ Utente ha confermato il nuovo percorso.');

    // Il vecchio percorso non serve più
    _previousRoute = null;
    _previousRouteSteps = [];
    _previousStepIndex = 0;
    _previousAlternativeRoutes = [];

    // Resetta i contatori di deviazione per ricominciare da zero
    // col nuovo percorso (altrimenti il primo tick potrebbe scattare
    // come "off route" dal vecchio conteggio).
    _consecutiveOffRouteDetects = 0;
    _routeCheckTicks = 0;

    // FIX BUG 4: reset sicurezza dei contatori di arrivo.
    // Anche se già resettati in Task 2b/2c, ripetiamo qui come guard-rail:
    // questo metodo può essere chiamato a posteriori e garantisce che lo
    // stato di arrivo sia pulito quando l'utente conferma il nuovo percorso.
    _hasArrived = false;
    _consecutiveArrivalUpdates = 0;

    // Chiude il bottom sheet
    reroutePhaseNotifier.value = ReroutePhase.none;
  }

  /// L'utente ha scelto di TORNARE al vecchio percorso.
  ///
  /// Ripristina il percorso che era attivo prima del ricalcolo:
  /// 1. Rimette _activeRoute al percorso precedente
  /// 2. Ripristina steps, step index, e alternative
  /// 3. Notifica la UI per aggiornare mappa e indicazioni
  /// 4. Chiude il bottom sheet
  ///
  /// NOTA: l'utente potrebbe NON essere fisicamente sul vecchio percorso.
  /// Il sistema di monitoraggio continuerà a controllare la posizione
  /// e se necessario scatterà un nuovo ricalcolo.
  void restorePreviousRoute() {
    if (_previousRoute == null) {
      print('⚠️ Nessun percorso precedente da ripristinare.');
      reroutePhaseNotifier.value = ReroutePhase.none;
      return;
    }

    print('↩️ Utente ha scelto di tornare al vecchio percorso.');

    // Ripristina il percorso precedente come attivo
    _activeRoute = _previousRoute;
    _routeSteps = List<DirectionStep>.from(_previousRouteSteps);
    _alternativeRoutes = List<RouteData>.from(_previousAlternativeRoutes);

    // Ripristina l'indice dello step (dove era arrivato l'utente)
    _currentStepIndex = _previousStepIndex;
    _consecutiveCloseUpdates = 0;
    _wasCloseToStepEnd = false; // FIX BUG 2: reset stato approach-then-leave
    currentStepNotifier.value = _previousStepIndex;

    // FIX BUG 4: reset contatori di arrivo.
    // Rientrando sul percorso vecchio (che potrebbe avere l'ultimo step
    // diverso), partiamo puliti per il rilevamento arrivo.
    _hasArrived = false;
    _consecutiveArrivalUpdates = 0;

    // Cancella il backup (ripristino completato)
    _previousRoute = null;
    _previousRouteSteps = [];
    _previousStepIndex = 0;
    _previousAlternativeRoutes = [];

    // Resetta i contatori di deviazione
    _consecutiveOffRouteDetects = 0;
    _routeCheckTicks = 0;

    // Notifica la UI: la mappa deve mostrare di nuovo il vecchio percorso
    activeRouteNotifier.value = _activeRoute;

    // Chiude il bottom sheet
    reroutePhaseNotifier.value = ReroutePhase.none;

    // Attiva il lock di 15 secondi: blocca i controlli di deviazione
    // e le chiamate API per dare all'utente tempo di tornare sul percorso.
    _returnToRouteLockUntil = DateTime.now().add(const Duration(seconds: 15));

    // Emette overlay arancione "Torna indietro"
    overlayNotifier.value = NavigationOverlayState(
      type: OverlayType.returnToRoute,
      message: 'Torna indietro e riprendi il percorso!',
    );

    print('✅ Percorso precedente ripristinato: ${_activeRoute!.totalDuration}');
  }

  /// Rilascia tutte le risorse (timer, listener).
  ///
  /// DEVE essere chiamato in NavigationScreen.dispose() per evitare
  /// memory leak e timer orfani che continuano a girare dopo la
  /// distruzione del widget.
  void dispose() {
    // Cancella il timer di campionamento del bearing
    _bearingTimer?.cancel();
    _bearingTimer = null;

    // Cancella il timer di controllo percorso (TASK 2)
    _routeCheckTimer?.cancel();
    _routeCheckTimer = null;

    // Cancella il countdown velocità zero
    _cancelZeroSpeedCountdown();

    // Distrugge i notifier per evitare memory leak
    overlayNotifier.dispose();
    activeRouteNotifier.dispose();
    reroutePhaseNotifier.dispose();
    progressNotifier.dispose(); // FIX BUG 1+2
  }

  // ===========================================================================
  // METODI PRIVATI — BEARING TIMER
  // ===========================================================================

  /// Avvia il timer periodico per il campionamento del bearing.
  ///
  /// Ogni [kBearingUpdateIntervalSec] secondi:
  /// 1. Controlla se la velocità è sopra [kSpeedThresholdKmH]
  /// 2. Se sì, aggiorna [_direction] con il bearing GPS corrente
  /// 3. Se no, non fa nulla (mantiene l'ultimo valore valido)
  ///
  /// PERCHÉ LA SOGLIA DI VELOCITÀ È NECESSARIA:
  /// Il bearing GPS è calcolato dal chip del dispositivo come la direzione
  /// del vettore di spostamento tra due punti GPS consecutivi.
  /// Quando il dispositivo è fermo o si muove molto lentamente:
  /// - Lo spostamento tra due letture è minore dell'errore GPS (~3-10m)
  /// - Il vettore di spostamento risultante è dominato dal rumore
  /// - Il bearing calcolato è essenzialmente casuale (può saltare da
  ///   0° a 180° a 270° tra letture consecutive)
  ///
  /// Richiedendo una velocità minima di 4 km/h (~1.1 m/s):
  /// - In 1 secondo l'utente si sposta di ~1.1 m
  /// - Su 5 secondi (intervallo del timer) si sposta di ~5.5 m
  /// - 5.5 m è abbastanza più grande dell'errore GPS per produrre un
  ///   bearing significativo e stabile
  void _startBearingTimer() {
    _bearingTimer = Timer.periodic(
      Duration(seconds: kBearingUpdateIntervalSec),
      (timer) {
        // Solo se la velocità è sopra la soglia configurabile il bearing
        // è considerato affidabile. Sotto soglia, direction mantiene
        // il suo ultimo valore valido (o resta null se mai impostato).
        if (_currentSpeed >= kSpeedThresholdKmH) {
          final bool wasNull = _direction == null;
          _direction = _rawBearing;
          if (wasNull) {
            print(
              '🧭 OVERLAY DEBUG: PRIMO bearing acquisito! '
              'direction=$_direction° (speed=$_currentSpeed km/h). '
              'L\'analisi overlay è ora ABILITATA.',
            );
          }
        }
        // Se la velocità è sotto soglia, NON aggiorniamo _direction.
        // Questo è intenzionale: preferiamo un bearing "vecchio ma buono"
        // a un bearing "nuovo ma casuale".
      },
    );
  }

  // ===========================================================================
  // METODI PRIVATI — ZERO SPEED COUNTDOWN
  // ===========================================================================

  /// Avvia il countdown di 10 secondi quando l'utente è fermo (Step 2.1).
  ///
  /// Quando il timer scade, esegue il blocco di analisi (Steps 2.2→2.6).
  ///
  /// GESTIONE RACE CONDITION:
  /// Il timer è un one-shot (Timer, non Timer.periodic). Quando scade:
  /// 1. _zeroSpeedTimer viene settato a null
  /// 2. Si controlla che la velocità sia ancora sotto soglia
  /// 3. Si controlla che _isAnalysisRunning sia false
  /// Solo se tutte le condizioni sono soddisfatte si procede con l'analisi.
  void _startZeroSpeedCountdown() {
    // Salviamo la posizione in cui l'utente si è fermato
    final double startLat = _currentLat ?? 0.0;
    final double startLng = _currentLng ?? 0.0;

    _zeroSpeedTimer = Timer(
      const Duration(milliseconds: kZeroSpeedDelayMs),
      () {
        // Il timer è scaduto. Resettiamo il riferimento al timer perché
        // non è più cancellabile (è già scaduto).
        _zeroSpeedTimer = null;

        // Calcoliamo la distanza percorsa nei 10 secondi per capire se
        // l'utente è davvero fermo o sta solo scendendo sotto i 2.5 km/h
        // (es. camminando molto lentamente o con segnale GPS disturbato).
        final double distMoved = haversineDistance(
          startLat,
          startLng,
          _currentLat ?? 0.0,
          _currentLng ?? 0.0,
        );

        // Doppia verifica: controlliamo che la velocità istantanea sia ancora
        // bassa E che l'utente non si sia mosso di più di 4 metri.
        // 4 metri in 10 secondi = 0.4 m/s (1.4 km/h), palesemente in movimento.
        //if (_currentSpeed < kZeroSpeedThresholdKmH && distMoved <= 6.0) {
        if (_currentSpeed < kZeroSpeedThresholdKmH) {
          print(
            '⏱️ OVERLAY DEBUG: Countdown ${kZeroSpeedDelayMs}ms SCADUTO — '
            'velocità: ${_currentSpeed.toStringAsFixed(1)} km/h, '
            'spostamento: ${distMoved.toStringAsFixed(1)}m. '
            'Lancio _executeAnalysis()...',
          );
          _executeAnalysis();
        } else {
          print(
            '⏱️ OVERLAY DEBUG: Countdown scaduto MA utente in movimento '
            '(speed: ${_currentSpeed.toStringAsFixed(1)} km/h, '
            'spostamento: ${distMoved.toStringAsFixed(1)}m) — analisi SALTATA.',
          );
        }
      },
    );
  }

  /// Cancella il countdown di 10 secondi in modo sicuro.
  ///
  /// Chiamato quando:
  /// - La velocità torna sopra soglia (l'utente si è mosso)
  /// - dispose() viene chiamato (l'app si chiude)
  ///
  /// Settare _zeroSpeedTimer = null dopo il cancel è importante per
  /// il check in updatePosition: se il timer è null, sappiamo che
  /// non c'è un countdown attivo e possiamo avviarne uno nuovo.
  void _cancelZeroSpeedCountdown() {
    _zeroSpeedTimer?.cancel();
    _zeroSpeedTimer = null;
  }

  // ===========================================================================
  // METODI PRIVATI — BLOCCO DI ANALISI (Steps 2.2 → 2.6)
  // ===========================================================================

  /// Esegue il blocco completo di analisi quando l'utente è fermo da 10 secondi.
  ///
  /// FLUSSO:
  /// Step 2.2 → Snapshot della posizione e del bearing
  /// Step 2.3 → Verifica vicinanza a waypoint di svolta
  /// Step 2.4 → Calcolo punti laterali (se non su waypoint)
  /// Step 2.5 → Chiamata Roads API
  /// Step 2.6 → Analisi risposta e emissione overlay
  ///
  /// SIDE EFFECTS:
  /// - Setta _isAnalysisRunning a true durante l'esecuzione
  /// - Può emettere un evento su overlayNotifier
  /// - Effettua una chiamata HTTP asincrona (Roads API)
  Future<void> _executeAnalysis() async {
    // Evita analisi concorrenti. Se un'analisi è già in corso (es. la
    // chiamata Roads API è lenta), non ne lanciamo una seconda.
    if (_isAnalysisRunning) {
      print(
        '🔒 OVERLAY DEBUG: _executeAnalysis bloccata — analisi già in corso',
      );
      return;
    }

    // FIX: Se la navigazione è stata fermata nel frattempo (l'utente ha
    // premuto "Termina" mentre il timer di 10s era in corso), non lanciamo
    // l'analisi. Senza questo check, il timer scadeva e l'overlay appariva
    // anche dopo lo stop della navigazione.
    if (!_isNavigating) {
      print(
        '🔒 OVERLAY DEBUG: _executeAnalysis bloccata — navigazione non attiva',
      );
      return;
    }

    _isAnalysisRunning = true;
    print('🟢 OVERLAY DEBUG: _executeAnalysis AVVIATA');

    try {
      // =====================================================================
      // STEP 2.2 — ACQUISIZIONE SNAPSHOT
      // =====================================================================
      //
      // Salviamo una copia dei valori correnti IN QUESTO ESATTO ISTANTE.
      // Questo è critico perché i passi successivi sono asincroni (la chiamata
      // alla Roads API può richiedere 1-3 secondi). Durante quel tempo,
      // gli aggiornamenti GPS continuano ad arrivare e modificano _currentLat,
      // _currentLng, _direction. Se usassimo le variabili "live", potremmo
      // calcolare i punti laterali con una posizione e analizzare la risposta
      // con un'altra posizione, causando inconsistenze logiche.

      final double? snapshotLat = _currentLat;
      final double? snapshotLng = _currentLng;
      final double? snapshotDirection = _direction;

      // Se la posizione non è disponibile, non possiamo fare nulla.
      if (snapshotLat == null || snapshotLng == null) {
        print(
          '❌ OVERLAY DEBUG: ABORT — posizione GPS non disponibile (lat=$snapshotLat, lng=$snapshotLng)',
        );
        return;
      }

      // =====================================================================
      // STEP 2.3 — VERIFICA VICINANZA A WAYPOINT DI SVOLTA
      // =====================================================================
      //
      // PRIMA del check bearing! Questo step ha bisogno SOLO di lat/lng,
      // non della direzione. Così l'overlay di svolta funziona anche
      // quando l'utente è fermo alla partenza e non ha mai camminato
      // (bearing ancora null).
      //
      // Controlliamo se l'utente è fermo su un punto di svolta del
      // percorso calcolato. Se sì, l'overlay mostra l'istruzione di
      // navigazione (dal campo html_instructions dello step) e usciamo.
      //
      // COME SI NAVIGANO GLI STEP DEL JSON DELLA DIRECTIONS API:
      // La risposta della Directions API ha questa struttura:
      //   routes[0].legs[0].steps[] — array di step
      // Ogni step ha:
      //   - start_location {lat, lng} — inizio del segmento
      //   - end_location {lat, lng} — fine del segmento (= punto di svolta)
      //   - html_instructions — testo dell'istruzione (es. "Svolta a destra")
      //   - maneuver — codice della manovra (es. "turn-right")
      //
      // I PUNTI DI SVOLTA sono le end_location di ogni step: rappresentano
      // i punti dove l'utente deve cambiare direzione.

      final turnResult = _checkNearTurnWaypoint(snapshotLat, snapshotLng);

      if (turnResult != null) {
        // L'utente è vicino a un waypoint di svolta!
        // FIX BUG 3 (B3.2): rimosso il pattern `value = null; value = X`.
        // Era stato introdotto per forzare la riemissione del listener,
        // ma causava la riproduzione TTS multipla della stessa istruzione.
        // Una nuova NavigationOverlayState() ha sempre reference != della
        // precedente → il ValueNotifier fire comunque, e
        // NavigationOverlay.didUpdateWidget riavvia l'animazione.
        // Il dedup TTS (B3.1) gestisce eventuali ripetizioni semantiche.
        print(
          '🔵 OVERLAY DEBUG: WAYPOINT DI SVOLTA RILEVATO! '
          'Messaggio: "${turnResult.message}", maneuver: ${turnResult.maneuver}',
        );
        overlayNotifier.value = turnResult;
        print('🟢 Overlay impostato: turnInstruction');
        _recordOverlayEvent(turnResult);
        return;
      }

      print(
        '⬜ OVERLAY DEBUG: Nessun waypoint di svolta vicino '
        '(${_routeSteps.length} step controllati, raggio=${kTurnWaypointRadiusMeters}m). '
        'Nessun overlay emesso.',
      );

      // =====================================================================
      // FIX OVERLAY ARANCIONE — SKIP SE PROSSIMA SVOLTA VICINA (< 50m)
      // =====================================================================
      //
      // PROBLEMA: tra 25m (kTurnWaypointRadiusMeters) e ~50m da una svolta,
      // il check waypoint sopra non scatta (troppo lontano), ma se l'utente
      // si ferma 10s in quella zona l'analisi laterale emette
      // "Continua dritto" — fuorviante perché l'utente sta per dover svoltare.
      //
      // SOLUZIONE: se la prossima endLocation step è entro 50m, sopprimiamo
      // l'overlay laterale. La fascia 25-50m diventa una "zona muta": né
      // turn instruction né lateral road. L'utente vede comunque il banner
      // alto con la prossima svolta — sufficiente.
      const double kSuppressLateralIfNextTurnWithinM = 50.0;
      if (_currentStepIndex < _routeSteps.length) {
        final cur = _routeSteps[_currentStepIndex];
        final double distNextTurn = haversineDistance(
          snapshotLat,
          snapshotLng,
          cur.endLat,
          cur.endLng,
        );
        if (distNextTurn < kSuppressLateralIfNextTurnWithinM) {
          print(
            '⏸️ OVERLAY DEBUG: prossima svolta a '
            '${distNextTurn.toStringAsFixed(1)}m < ${kSuppressLateralIfNextTurnWithinM}m '
            '— skip lateralRoad (utente sta per svoltare)',
          );
          return;
        }
      }

      // =====================================================================
      // STEP 2.4 — CONTROLLO COOLDOWN SPAZIALE (ANTI-SPAM)
      // =====================================================================
      //
      // Evitiamo di spammare l'utente con continui overlay se rimane fermo
      // nella stessa area (es. seduto su una panchina) per molti minuti.
      if (_lastAnalysisLat != null && _lastAnalysisLng != null) {
        final double distFromLastAnalysis = haversineDistance(
          snapshotLat,
          snapshotLng,
          _lastAnalysisLat!,
          _lastAnalysisLng!,
        );

        if (distFromLastAnalysis < 20.0) {
          print(
            '⏸️ OVERLAY DEBUG: Utente fermo nello stesso posto '
            '(distanza ${distFromLastAnalysis.toStringAsFixed(1)}m < 20m). '
            'Skip analisi per non spammare la UI e la API.',
          );
          return;
        }
      }

      // Fallback: se il bearing stabilizzato è null, usa quello raw del GPS
      final double effectiveDirection = snapshotDirection ?? _rawBearing;

      if (snapshotDirection == null) {
        print(
          '⚠️ OVERLAY DEBUG: direction null — uso _rawBearing come fallback (${_rawBearing.toStringAsFixed(1)}°)',
        );
      }

      // questo sotto sostituito da quello sopra
      // if (snapshotDirection == null) {
      // print(
      // '❌ OVERLAY DEBUG: direction null — skip rilevamento strade laterali',
      //);
      //return;
      //}

      // =====================================================================
      // LIMITATORE CHIAMATE API (Anti-Spam se fermi dove non ci sono strade)
      // =====================================================================
      if (_lastApiCallTime != null) {
        final int elapsedSeconds = DateTime.now()
            .difference(_lastApiCallTime!)
            .inSeconds;
        if (elapsedSeconds < 30) {
          print(
            '⏸️ OVERLAY DEBUG: Rate limit Google API ($elapsedSeconds s < 30s). Skip analisi.',
          );
          return;
        }
      }

      final lateralPoints = computeAllLateralPoints(
        snapshotLat,
        snapshotLng,
        effectiveDirection, // <-- Sostituito qui prima snapDirection
      );

      _lastApiCallTime = DateTime.now(); // Registra il momento della chiamata
      final snappedPoints = await _roadsService.findNearestRoads(lateralPoints);

      // FIX OVERLAY ARANCIONE — FILTRO SNAP POINTS SUL PERCORSO
      //
      // PROBLEMA: Roads API ritorna QUALSIASI strada vicina, comprese quelle
      // che fanno parte del nostro percorso (es. lo step successivo dopo
      // una svolta). Senza filtro, l'overlay arancione "Vai dritto" usciva
      // anche all'imbocco di uscite/svolte che sono parte della rotta.
      //
      // SOLUZIONE: scartiamo gli snap points che si trovano a < 5m dalla
      // polyline del percorso attivo. Quelli rimanenti sono *davvero*
      // strade laterali esterne al percorso → l'avviso "non svoltare,
      // continua dritto" diventa appropriato.
      const double kRoutePolylineProximityM = 5.0;
      List<SnappedPoint>? filteredSnapped = snappedPoints;
      final List<List<double>>? routePolyline =
          _activeRoute?.decodedPolyline;
      if (snappedPoints != null &&
          snappedPoints.isNotEmpty &&
          routePolyline != null &&
          routePolyline.isNotEmpty) {
        filteredSnapped = snappedPoints.where((sp) {
          final double distToRoute = minDistanceToPolyline(
            sp.latitude,
            sp.longitude,
            routePolyline,
          );
          return distToRoute > kRoutePolylineProximityM;
        }).toList();
        if (filteredSnapped.length < snappedPoints.length) {
          print(
            '🔎 OVERLAY DEBUG: filtrati ${snappedPoints.length - filteredSnapped.length}/${snappedPoints.length} '
            'snap points che cadevano sulla polyline del percorso',
          );
        }
      }

      if (filteredSnapped != null && filteredSnapped.isNotEmpty) {
        final msg =
            kLateralRoadMessages[_random.nextInt(kLateralRoadMessages.length)];
        // FIX BUG 3 (B3.2): rimosso il `value = null` di force refresh.
        // Vedi commento esteso più sopra (turnInstruction). Il dedup TTS
        // ora previene la ripetizione vocale sui retrigger ravvicinati.
        overlayNotifier.value = NavigationOverlayState(
          type: OverlayType.lateralRoadDetected,
          message: msg,
        );
        print('🟠 OVERLAY DEBUG: Strada laterale rilevata. Messaggio: "$msg"');
        _recordOverlayEvent(overlayNotifier.value!);

        // Salva la posizione per evitare di ripetere l'overlay SOLO se trovato in quest'area
        _lastAnalysisLat = snapshotLat;
        _lastAnalysisLng = snapshotLng;
      } else {
        print(
          '⬜ OVERLAY DEBUG: Nessuna strada laterale OFF-ROUTE rilevata in questo punto.',
        );
      }
    } finally {
      // Assicuriamoci di resettare il flag anche in caso di eccezioni
      // non gestite. Il blocco finally viene eseguito SEMPRE, sia che
      // il try sia terminato normalmente, sia che sia uscito con return,
      // sia che sia stata lanciata un'eccezione.
      _isAnalysisRunning = false;
    }
  }

  /// Controlla se l'utente è vicino a un waypoint di svolta del percorso (Step 2.3).
  ///
  /// Per ogni step del percorso, calcola la distanza tra la posizione dell'utente
  /// e la end_location dello step (che è il punto di svolta). Se la distanza
  /// è inferiore a [kTurnWaypointRadiusMeters], l'utente è considerato
  /// "sull'incrocio" e viene restituita l'istruzione di navigazione.
  ///
  /// PARAMETRI:
  /// - [lat], [lng]: posizione snapshot dell'utente
  ///
  /// RETURN:
  /// - NavigationOverlayState con l'istruzione, se l'utente è vicino a un waypoint
  /// - null se l'utente non è vicino a nessun waypoint
  NavigationOverlayState? _checkNearTurnWaypoint(double lat, double lng) {
    if (_routeSteps.isEmpty) {
      print(
        '🔍 OVERLAY DEBUG: _checkNearTurnWaypoint — 0 step nel percorso, skip.',
      );
      return null;
    }

    double closestDistance = double.infinity;
    String closestInstruction = '';

    // =====================================================================
    // FIX BUG "VAI DRITTO": Check sulla startLocation dello step corrente
    // =====================================================================
    //
    // PROBLEMA ORIGINALE:
    // La logica di avanzamento step in updatePosition() incrementa
    // _currentStepIndex quando l'utente è a < 40m dall'endLocation.
    // Siccome 40m > kTurnWaypointRadiusMeters (25m), lo step viene
    // "consumato" PRIMA che il check di prossimità lo rilevi.
    // L'utente si trova quindi alla startLocation dello step corrente
    // (= endLocation dello step precedente = l'incrocio), ma il ciclo
    // sottostante controlla solo le endLocation → nessun match.
    //
    // FIX:
    // Controlliamo ANCHE la startLocation dello step corrente.
    // Se l'utente è entro kTurnWaypointRadiusMeters dalla start del
    // suo step attuale, mostriamo l'istruzione di QUESTO step
    // (che è esattamente ciò che l'utente deve fare ORA).
    //
    // ESEMPIO:
    // Step i:   A → B  ("Vai verso nord")
    // Step i+1: B → C  ("Continua dritto" / "Svolta a destra")
    // L'utente è a B, _currentStepIndex = i+1.
    // → Controlliamo distanza(utente, B) = distanza(utente, step[i+1].start)
    // → Match! Mostriamo l'istruzione dello step i+1
    if (_currentStepIndex < _routeSteps.length) {
      final currentStep = _routeSteps[_currentStepIndex];
      final double distToStart = haversineDistance(
        lat,
        lng,
        currentStep.startLat,
        currentStep.startLng,
      );

      if (distToStart <= kTurnWaypointRadiusMeters) {
        final String prefix =
            kTurnEncouragementPrefixes[_random.nextInt(
              kTurnEncouragementPrefixes.length,
            )];
        print(
          '🔵 OVERLAY DEBUG: Utente vicino alla START dello step corrente '
          '(${distToStart.toStringAsFixed(1)}m ≤ ${kTurnWaypointRadiusMeters}m). '
          'Istruzione: "${currentStep.instruction}"',
        );
        return NavigationOverlayState(
          type: OverlayType.turnInstruction,
          message: '$prefix${currentStep.instruction}',
          maneuver: currentStep.maneuver,
        );
      }

      // Traccia per debug anche se non ha matchato
      if (distToStart < closestDistance) {
        closestDistance = distToStart;
        closestInstruction = '(start) ${currentStep.instruction}';
      }
    }

    // FIX precedente: Iteriamo SOLO sugli step da _currentStepIndex in poi.
    // Prima iteravamo su TUTTI gli step, compresi quelli già completati
    // (dietro l'utente). Se l'utente passava vicino alla endLocation di
    // uno step passato (es. "Vai a destra" di 50m fa), l'overlay si
    // riattivava con l'istruzione sbagliata. Ora controlliamo solo
    // gli step futuri: quelli che l'utente deve ancora percorrere.
    for (int i = _currentStepIndex; i < _routeSteps.length; i++) {
      final step = _routeSteps[i];

      // Calcola la distanza tra la posizione dell'utente e la end_location
      // dello step. La end_location è il punto dove termina il segmento
      // corrente e inizia il segmento successivo — ovvero il punto dove
      // l'utente deve cambiare direzione.
      final double distance = haversineDistance(
        lat,
        lng,
        step.endLat,
        step.endLng,
      );

      if (distance < closestDistance) {
        closestDistance = distance;
        // Se siamo vicini alla fine di questo step, l'istruzione corretta
        // è quella dello step SUCCESSIVO, perché è lì che inizia la nuova manovra.
        if (i + 1 < _routeSteps.length) {
          closestInstruction = _routeSteps[i + 1].instruction;
        } else {
          closestInstruction = 'Arrivo a destinazione';
        }
      }

      if (distance <= kTurnWaypointRadiusMeters) {
        // L'utente è fermo esattamente su un punto di svolta del percorso!
        // Ma attenzione: la endLocation dello step corrente coincide con
        // l'incrocio in cui l'utente deve eseguire la manovra dello step SUCCESSIVO.
        // Quindi se c'è uno step successivo, mostriamo la sua istruzione.
        if (i + 1 < _routeSteps.length) {
          final nextStep = _routeSteps[i + 1];
          final String prefix =
              kTurnEncouragementPrefixes[_random.nextInt(
                kTurnEncouragementPrefixes.length,
              )];
          return NavigationOverlayState(
            type: OverlayType.turnInstruction,
            message: '$prefix${nextStep.instruction}',
            maneuver: nextStep.maneuver,
          );
        } else {
          // Siamo alla fine dell'ultimo step. L'arrivo a destinazione verrà
          // gestito dalla logica apposita, quindi qui non emettiamo overlay di svolta.
          return null;
        }
      }
    }

    print(
      '🔍 OVERLAY DEBUG: Waypoint più vicino a ${closestDistance.toStringAsFixed(1)}m '
      '(soglia=${kTurnWaypointRadiusMeters}m) — "$closestInstruction"',
    );

    // Nessun waypoint di svolta è abbastanza vicino
    return null;
  }

  // ===========================================================================
  // METODI PRIVATI — MONITORAGGIO PERCORSO (TASK 2)
  // ===========================================================================

  /// Avvia il timer periodico che ogni 2 secondi verifica se l'utente
  /// è ancora sul percorso attivo (TASK 2).
  ///
  /// Questo è il cuore del sistema di monitoraggio:
  /// ogni tick del timer esegue la catena di controllo Task 2a → 2b → 2c.
  ///
  /// SICUREZZA:
  /// Se il timer precedente è ancora attivo (es. startNavigation() viene
  /// chiamato due volte), lo cancelliamo prima di crearne uno nuovo
  /// per evitare timer duplicati.
  void _startRouteCheckTimer() {
    // Cancella un eventuale timer precedente per evitare duplicati
    _routeCheckTimer?.cancel();

    // Crea un nuovo timer periodico che scatta ogni kRouteCheckIntervalSec secondi
    _routeCheckTimer = Timer.periodic(Duration(seconds: kRouteCheckIntervalSec), (
      timer,
    ) {
      // Esegue il controllo solo se la navigazione è attiva.
      // Questo check è ridondante (il timer viene cancellato in stopNavigation),
      // ma aggiunge un livello di sicurezza extra.
      if (_isNavigating) {
        _onRouteCheckTick();
      }
    });
  }

  /// Callback eseguito ogni 2 secondi dal timer di controllo percorso.
  ///
  /// Implementa la logica a cascata descritta nelle specifiche:
  ///
  /// OGNI 2 SECONDI:
  /// │
  /// ├─ Posizione utente entro 40m dalla polyline attiva?
  /// │   ├─ SÌ → nessuna azione
  /// │   └─ NO → utente ha deviato
  /// │           │
  /// │           ├─ È entro 40m da un percorso alternativo?
  /// │           │   ├─ SÌ → cambia percorso attivo con quell'alternativo
  /// │           │   └─ NO → chiama API Google
  /// │           │               → salva tutti i nuovi percorsi
  /// │           │               → imposta come attivo quello con durata minore
  ///
  /// SIDE EFFECTS:
  /// - Può cambiare il percorso attivo (Task 2b)
  /// - Può effettuare una chiamata HTTP asincrona (Task 2c)
  /// - Notifica la UI tramite activeRouteNotifier se il percorso cambia
  void _onRouteCheckTick() {
    // --- PREREQUISITI ---
    // Verifica che abbiamo tutti i dati necessari prima di procedere.
    // Senza posizione o percorso attivo, non possiamo fare nessun confronto.

    // Se la posizione GPS non è ancora disponibile, saltiamo questo tick.
    // All'avvio dell'app il GPS potrebbe impiegare qualche secondo per
    // ottenere un fix.
    if (_currentLat == null || _currentLng == null) return;

    // Se non c'è un percorso attivo, non c'è nulla da controllare.
    // Questo non dovrebbe accadere se _isNavigating è true, ma è un
    // controllo di sicurezza.
    if (_activeRoute == null) return;

    // Se è già in corso un ricalcolo API (Task 2c), non lanciamo un
    // secondo controllo. Il ricalcolo è asincrono e potrebbe richiedere
    // diversi secondi.
    if (_isRerouting) return;

    // Se è attivo il lock "torna al percorso", saltiamo tutti i controlli.
    // L'utente ha scelto di tornare al vecchio percorso e ha 15 secondi
    // per manovrare senza che il sistema rilevi nuove deviazioni.
    if (_returnToRouteLockUntil != null) {
      if (DateTime.now().isBefore(_returnToRouteLockUntil!)) {
        return;
      }
      _returnToRouteLockUntil = null; // Lock scaduto, pulizia
    }

    // Cattura uno snapshot delle coordinate ATTUALI.
    // Questo è importante per coerenza: durante il controllo (che potrebbe
    // essere asincrono se si arriva al Task 2c), la posizione GPS continua
    // ad aggiornarsi. Usiamo lo snapshot per tutti i calcoli.
    final double lat = _currentLat!;
    final double lng = _currentLng!;

    // FIX 3: Grace period dei primi 15 secondi dopo l'avvio della navigazione.
    // Nei primi 15 secondi saltiamo il controllo di deviazione per dare
    // all'utente il tempo di mettersi in cammino e allinearsi alla polyline.
    if (_navigationStartTime != null) {
      final elapsed = DateTime.now()
          .difference(_navigationStartTime!)
          .inSeconds;
      if (elapsed < 15) {
        return;
      }
    }

    // TASK 5 - Filtro Signal Drift basato sull'accuratezza GPS
    if (_currentAccuracy > 30.0) {
      print(
        '⚠️ Segnale GPS debole (accuracy: ${_currentAccuracy}m). Ignoro controllo percorso.',
      );
      return;
    }

    // TASK 5 - Adaptive Polling basato sulla velocità
    _routeCheckTicks++;
    int requiredTicks = 1; // >60km/h: ogni 2 secondi (1 tick)
    if (_currentSpeed <= 15.0) {
      requiredTicks = 1; // <=15km/h (pedonale): ogni 2 secondi (1 tick)
      // FIX: era 3 (6 secondi). Troppo lento per navigazione pedonale.
      // A piedi servono risposte rapide, l'utente potrebbe aver già
      // imboccato una strada sbagliata dopo 6 secondi.
    } else if (_currentSpeed <= 60.0) {
      requiredTicks = 2; // 15-60km/h: ogni 4 secondi (2 tick)
    }

    if (_routeCheckTicks < requiredTicks) return;
    _routeCheckTicks = 0; // Resetta i tick e procedi al controllo

    // =========================================================================
    // TASK 2a — CONFRONTO POSIZIONE CON PERCORSO ATTIVO
    // =========================================================================
    //
    // Verifica se la posizione dell'utente è entro 40 metri dalla polyline
    // del percorso attivo. Se sì, l'utente sta seguendo il percorso
    // correttamente → non facciamo nulla e aspettiamo il prossimo tick.

    // Chiama isOnRoute() che internamente:
    // 1. Calcola la distanza tra (lat, lng) e ogni punto della polyline
    // 2. Trova la distanza minima
    // 3. Confronta con la soglia (FIX BUG 5: adattiva, 50m per pedoni)
    final bool onActiveRoute = isOnRoute(
      lat,
      lng,
      _activeRoute!.decodedPolyline,
      speedKmH: _currentSpeed,
    );

    // Se l'utente è sul percorso, tutto OK. Nessuna azione necessaria.
    if (onActiveRoute) {
      _consecutiveOffRouteDetects = 0; // Azzera strike di deviazione
      // Se era in fase di ricalcolo (offRoute o rerouting), resetta
      // perché l'utente è tornato da solo. MA se siamo in routeChanged,
      // NON resettiamo: il bottom sheet di scelta deve restare visibile
      // finché l'utente non decide (conferma nuovo o torna al vecchio).
      if (reroutePhaseNotifier.value == ReroutePhase.offRoute ||
          reroutePhaseNotifier.value == ReroutePhase.rerouting) {
        reroutePhaseNotifier.value = ReroutePhase.none;
      }
      return; // ← L'utente segue il percorso, aspettiamo il prossimo tick
    }

    // =========================================================================
    // L'UTENTE HA DEVIATO DAL PERCORSO ATTIVO!
    // =========================================================================
    //
    // La distanza minima dalla polyline attiva è > 40 metri.

    // Se il bottom sheet "routeChanged" è ancora aperto (l'utente non ha
    // ancora scelto), NON lanciamo un altro ricalcolo. Aspettiamo che
    // l'utente faccia la sua scelta prima di fare qualsiasi altra cosa.
    if (reroutePhaseNotifier.value == ReroutePhase.routeChanged) {
      return;
    }

    // TASK 5 - Strikes System (Verifica su più letture)
    // FIX BUG 5: strikes adattativi per velocità.
    // Pedoni (< 10 km/h): 3 strike = 6 secondi. Il GPS pedonale è più
    // rumoroso e l'utente sul lato opposto della strada non deve scatenare
    // ricalcoli per un jitter momentaneo.
    // Veicoli (>= 10 km/h): 2 strike = 4 secondi (comportamento precedente).
    final int requiredStrikes = _currentSpeed < 10.0 ? 3 : 2;
    _consecutiveOffRouteDetects++;
    if (_consecutiveOffRouteDetects < requiredStrikes) {
      print(
        '⚠️ Deviazione rilevata (Strike $_consecutiveOffRouteDetects/$requiredStrikes). Attendo conferma...',
      );
      return;
    }
    _consecutiveOffRouteDetects = 0; // Azzera prima del varo ricalcolo

    // FIX BUG 5: Tolerance laterale per pedestriani
    // Se l'utente è a piedi (< 10 km/h) E si sta muovendo nella direzione
    // generale del percorso, non forzare il ricalcolo.
    // Questo gestisce il caso di utente sul marciapiede opposto ma che
    // sta comunque andando nella direzione corretta.
    if (_currentSpeed < 10.0 && _activeRoute != null) {
      final bool movingTowardRoute = _isMovingGenerallyTowardRoute(lat, lng);
      if (movingTowardRoute) {
        print(
          '✅ FIX BUG 5: Utente a piedi fuori dal percorso ma direzione corretta. '
          'Nessun ricalcolo forzato. Velocità: ${_currentSpeed.toStringAsFixed(1)} km/h',
        );
        return; // Non considerare off-route, continua navigazione
      }
    }

    // Ora controlliamo se è finito su uno dei percorsi alternativi.

    // Log per debugging: segnala la deviazione confermata
    print('⚠️ Deviazione confermata! L\'utente è fuori dal percorso attivo.');

    // Notifica la UI che l'utente ha deviato → mostra bottom sheet
    // "Ricalcolo in corso..." con spinner e messaggio rassicurante.
    reroutePhaseNotifier.value = ReroutePhase.offRoute;

    // =========================================================================
    // TASK 2b — CONTROLLO PERCORSI ALTERNATIVI
    // =========================================================================
    //
    // Iteriamo su tutti i percorsi alternativi salvati al TASK 1.
    // Per ciascuno, verifichiamo se la posizione dell'utente è entro 40 metri
    // dalla polyline di quel percorso.
    //
    // VANTAGGI DI QUESTO APPROCCIO:
    // - Nessuna chiamata API necessaria → risparmio tempo e quota
    // - Risposta istantanea → l'utente vede subito il nuovo percorso
    // - Zero latenza di rete → funziona anche offline (con percorsi in memoria)

    for (final alternativeRoute in _alternativeRoutes) {
      // Salta il percorso attivo: lo abbiamo già controllato sopra
      // e sappiamo che l'utente NON è su di esso.
      if (alternativeRoute == _activeRoute) continue;

      // Verifica se l'utente è entro soglia (FIX BUG 5: adattiva per pedoni)
      final bool onAlternative = isOnRoute(
        lat,
        lng,
        alternativeRoute.decodedPolyline,
        speedKmH: _currentSpeed,
      );

      if (onAlternative) {
        // =====================================================================
        // TROVATO! L'utente è su un percorso alternativo.
        // =====================================================================
        //
        // Sostituiamo il percorso attivo con questo alternativo.
        // Non effettuiamo nessuna nuova chiamata API: abbiamo già tutti
        // i dati necessari in memoria (polyline, steps, durata).

        // Log per debugging
        print(
          '✅ Percorso alternativo trovato! '
          'Durata: ${alternativeRoute.totalDuration}. '
          'Cambio percorso attivo.',
        );

        // SALVA IL PERCORSO PRECEDENTE per dare all'utente la scelta
        // di tornare indietro. Viene cancellato quando l'utente conferma
        // (confirmNewRoute) o ripristinato (restorePreviousRoute).
        _previousRoute = _activeRoute;
        _previousRouteSteps = List<DirectionStep>.from(_routeSteps);
        _previousStepIndex = _currentStepIndex;
        _previousAlternativeRoutes = List<RouteData>.from(_alternativeRoutes);

        // Sostituisce il percorso attivo con l'alternativo
        _activeRoute = alternativeRoute;

        // Aggiorna gli step del percorso per il check dei waypoint di svolta
        _routeSteps = alternativeRoute.steps;

        // Siccome ci siamo agganciati magicamente al percorso di scorta,
        // azzeriamo tutti i conteggi per fargli ricalcolare dal rigo 0 le sue istruzioni
        _currentStepIndex = 0;
        _consecutiveCloseUpdates = 0;
        _wasCloseToStepEnd = false; // FIX BUG 2: reset stato approach-then-leave
        currentStepNotifier.value = 0;

        // FIX BUG 4: reset contatori di arrivo sul nuovo percorso.
        // Senza questo reset, un contatore residuo (es. 2) dal percorso
        // precedente poteva portare a falsi arrivi o comunque a
        // comportamenti incoerenti sul nuovo percorso.
        _hasArrived = false;
        _consecutiveArrivalUpdates = 0;

        // Notifica la UI che il percorso attivo è cambiato.
        // La NavigationScreen si occuperà di aggiornare:
        // - La polyline disegnata sulla mappa
        // - Le indicazioni passo-passo
        // - Distanza e durata totale nell'header
        activeRouteNotifier.value = _activeRoute;

        // Notifica la UI che il percorso è cambiato → mostra animazione
        // "Va tutto bene. Sembra che il percorso sia cambiato."
        reroutePhaseNotifier.value = ReroutePhase.routeChanged;

        // Registra il ricalcolo nella sessione
        if (_currentSession == null) {
          print('⚠️ Ricalcolo: _currentSession è NULL! Ricalcolo perso');
        } else {
          _currentSession!.rerouteCount++;
          print(
            '🔄 Ricalcolo registrato! Totale ricalcoli: ${_currentSession!.rerouteCount}',
          );
        }

        // Usciamo dalla funzione: abbiamo trovato un percorso compatibile,
        // non serve controllare gli altri né fare chiamate API.
        return;
      }
    }

    // =========================================================================
    // TASK 2c — RICALCOLO PERCORSO VIA API GOOGLE
    // =========================================================================
    //
    // Se siamo arrivati qui, significa che:
    // 1. L'utente NON è sul percorso attivo (Task 2a fallito)
    // 2. L'utente NON è su nessun percorso alternativo (Task 2b fallito)
    //
    // L'unica opzione rimasta è ricalcolare il percorso:
    // - Partenza: posizione GPS ATTUALE dell'utente
    // - Destinazione: la STESSA destinazione originale (non cambia mai)
    // - alternatives: true (per ricevere di nuovo percorsi alternativi)

    // Log per debugging
    print(
      '❌ Nessun percorso alternativo compatibile. '
      'Ricalcolo via API Google...',
    );

    // Notifica la UI che il ricalcolo API è in corso.
    // Il bottom sheet aggiorna il messaggio per rassicurare l'utente.
    reroutePhaseNotifier.value = ReroutePhase.rerouting;

    // Lancia il ricalcolo asincrono. Non usiamo await perché siamo in un
    // callback del timer (non è async). _executeReroute() gestisce
    // internamente il flag _isRerouting per evitare ricalcoli concorrenti.
    _executeReroute(lat, lng);
  }

  /// Esegue il ricalcolo del percorso via API Google (Task 2c).
  ///
  /// Questo metodo è asincrono perché effettua una chiamata HTTP alla
  /// Directions API di Google.
  ///
  /// PARAMETRI:
  /// - [lat], [lng]: coordinate GPS dell'utente al momento della richiesta.
  ///   Queste diventano la nuova "partenza" del percorso.
  ///
  /// FLUSSO:
  /// 1. Setta _isRerouting = true per bloccare tick concorrenti
  /// 2. Chiama getDirectionsWithAlternatives() con posizione corrente
  /// 3. Se successo: aggiorna tutti i percorsi e il percorso attivo
  /// 4. Se fallimento: log dell'errore, nessuna azione (fallback silenzioso)
  /// 5. Setta _isRerouting = false
  ///
  /// SIDE EFFECTS:
  /// - Effettua una chiamata HTTP
  /// - Può aggiornare _activeRoute, _alternativeRoutes, _routeSteps
  /// - Può notificare la UI tramite activeRouteNotifier
  Future<void> _executeReroute(double lat, double lng) async {
    // Evita ricalcoli concorrenti: se un ricalcolo è già in corso,
    // non ne lanciamo un altro.
    if (_isRerouting) return;

    // Setta il flag di ricalcolo in corso
    _isRerouting = true;

    try {
      // Verifica che abbiamo la destinazione originale.
      // Senza destinazione non possiamo ricalcolare il percorso.
      if (_originalDestination == null) {
        print('Ricalcolo impossibile: destinazione originale mancante');
        return;
      }

      // Costruisce la stringa di partenza come coordinate GPS.
      // Il formato "lat,lng" è accettato dalla Directions API come
      // alternativa a un indirizzo testuale.
      final String currentOrigin = '$lat,$lng';

      // Chiama la Directions API con:
      // - origin: posizione GPS ATTUALE (dove si trova l'utente ORA)
      // - destination: la destinazione ORIGINALE (invariata)
      // - alternatives: true (incluso nel metodo)
      //
      // Questa è la STESSA logica del TASK 1: la API restituisce più
      // percorsi, li ordiniamo per durata, e selezioniamo il migliore.
      final AllRoutesResult? newResult = await _directionsService
          .getDirectionsWithAlternatives(
            origin: currentOrigin,
            destination: _originalDestination!,
          );

      // --- GESTIONE RISULTATO ---

      // Se la chiamata è fallita (errore di rete, API, ecc.),
      // non facciamo nulla. L'utente continuerà a navigare con il
      // vecchio percorso (anche se fuori rotta). Al prossimo tick
      // il sistema riproverà.
      if (newResult == null) {
        print('⚠️ Ricalcolo fallito. Riproverò al prossimo ciclo.');
        // Reset della fase: il prossimo tick riproverà
        reroutePhaseNotifier.value = ReroutePhase.none;
        return;
      }

      // --- AGGIORNAMENTO PERCORSI (stessa logica del TASK 1) ---

      // SALVA IL PERCORSO PRECEDENTE per dare all'utente la scelta
      // di tornare indietro. Viene cancellato quando l'utente conferma
      // (confirmNewRoute) o ripristinato (restorePreviousRoute).
      _previousRoute = _activeRoute;
      _previousRouteSteps = List<DirectionStep>.from(_routeSteps);
      _previousStepIndex = _currentStepIndex;
      _previousAlternativeRoutes = List<RouteData>.from(_alternativeRoutes);

      // Il percorso migliore (durata minore) diventa il nuovo attivo
      _activeRoute = newResult.bestRoute;

      // Salva tutti i nuovi percorsi per futuri check (Task 2b)
      _alternativeRoutes = List<RouteData>.from(newResult.allRoutes);

      // Aggiorna gli step per il check dei waypoint di svolta
      _routeSteps = newResult.bestRoute.steps;

      // Resetta la progressione step per il nuovo percorso
      _currentStepIndex = 0;
      _consecutiveCloseUpdates = 0;
      _wasCloseToStepEnd = false; // FIX BUG 2: reset stato approach-then-leave
      currentStepNotifier.value = 0;

      // FIX BUG 4: reset contatori di arrivo sul nuovo percorso ricalcolato.
      // Il nuovo percorso può avere una endLocation "snapped" leggermente
      // diversa dall'originale; resettiamo anche perché senza questo reset,
      // eventuali conferme parziali accumulate sul vecchio percorso
      // restavano dirty e potevano produrre arrivi prematuri oppure
      // impedire il normale conteggio sul nuovo.
      _hasArrived = false;
      _consecutiveArrivalUpdates = 0;

      // Notifica la UI che il percorso è cambiato.
      // La NavigationScreen aggiornerà mappa, indicazioni, ecc.
      activeRouteNotifier.value = _activeRoute;

      // Notifica la UI che il ricalcolo è completato → mostra animazione
      // "Va tutto bene. Sembra che il percorso sia cambiato."
      reroutePhaseNotifier.value = ReroutePhase.routeChanged;

      // Log per debugging
      print(
        '✅ Ricalcolo completato! '
        'Nuovi percorsi: ${_alternativeRoutes.length}. '
        'Percorso attivo: ${_activeRoute!.totalDuration}',
      );

      // Registra il ricalcolo nella sessione
      if (_currentSession == null) {
        print('⚠️ Ricalcolo API: _currentSession è NULL! Ricalcolo perso');
      } else {
        _currentSession!.rerouteCount++;
        print(
          '🔄 Ricalcolo API registrato! Totale ricalcoli: ${_currentSession!.rerouteCount}',
        );
      }
    } catch (e) {
      // Gestisce eccezioni non previste (parsing, rete, ecc.)
      print('❌ Eccezione durante il ricalcolo: $e');
      // Reset della fase in caso di errore
      reroutePhaseNotifier.value = ReroutePhase.none;
    } finally {
      // Resetta SEMPRE il flag, anche in caso di errore.
      // Senza questo reset, il sistema resterebbe bloccato per sempre
      // (nessun nuovo ricalcolo verrebbe mai avviato).
      _isRerouting = false;
    }
  }

  /// FIX BUG 5: Verifica se l'utente si sta muovendo nella direzione
  /// generale del percorso (invece che nella direzione opposta).
  ///
  /// Questo è usato per la tolerance laterale: un pedone sul marciapiede
  /// opposto che cammina nella direzione del percorso non viene forzato
  /// al ricalcolo.
  ///
  /// LOGICA:
  /// 1. Trova il punto della polyline più vicino all'utente
  /// 2. Trova il PROSSIMO punto sulla polyline (direzione di marcia)
  /// 3. Calcola il bearing da utente → prossimo punto polyline
  /// 4. Confronta con la direzione di movimento dell'utente (_rawBearing)
  /// 5. Se la differenza è < 90°, l'utente sta andando verso il percorso
  bool _isMovingGenerallyTowardRoute(double lat, double lng) {
    if (_activeRoute == null || _activeRoute!.decodedPolyline.isEmpty) {
      return false;
    }

    final polyline = _activeRoute!.decodedPolyline;

    // FIX BUG 5A: trovare il segmento più vicino con proiezione ortogonale,
    // non il vertice più vicino. La overview_polyline è compressa: un tratto
    // di 200m può avere solo 2 punti. Il vertice più vicino può essere a
    // centinaia di metri mentre la proiezione sul segmento è vicina.
    int nearestSegIdx = 0;
    double minLateralDist = double.infinity;

    for (int i = 0; i < polyline.length - 1; i++) {
      final proj = projectPointOnSegment(
        lat, lng,
        polyline[i][0], polyline[i][1],
        polyline[i + 1][0], polyline[i + 1][1],
      );
      if (proj.lateralDistanceMeters < minLateralDist) {
        minLateralDist = proj.lateralDistanceMeters;
        nearestSegIdx = i;
      }
    }

    // Il bearing della direzione di marcia del percorso sul segmento più vicino
    // (non verso il vertice successivo, ma nella direzione del segmento stesso).
    final double routeSegBearing = calculateBearing(
      polyline[nearestSegIdx][0],
      polyline[nearestSegIdx][1],
      polyline[nearestSegIdx + 1][0],
      polyline[nearestSegIdx + 1][1],
    );

    // FIX BUG 5B: usa _direction (bearing filtrato GPS, aggiornato solo sopra
    // soglia di velocità) invece di _rawBearing (inaffidabile a bassa velocità).
    // Se _direction è null (utente mai mosso abbastanza), preferiamo non
    // ricalcolare: è più probabile che l'utente stia percorrendo il percorso
    // sul lato sbagliato della strada che non che abbia realmente deviato.
    final double? userBearing = _direction ?? (_rawBearing != 0.0 ? _rawBearing : null);
    if (userBearing == null) {
      print(
        '🧭 FIX BUG 5: bearing utente sconosciuto — nessun ricalcolo (fail-safe)',
      );
      return true; // Fail-safe: senza bearing, non ricalcolare
    }

    // L'utente è "generalmente nella direzione del percorso" se la sua
    // direzione di marcia è entro ±90° rispetto alla direzione del segmento.
    // Usiamo il bearing del SEGMENTO (stabile, geometrico) invece del bearing
    // verso un vertice (instabile, dipende dalla posizione relativa).
    double diff = (routeSegBearing - userBearing + 360) % 360;
    if (diff > 180) diff -= 360;
    final absDiff = diff.abs();

    final bool movingToward = absDiff < 90.0;
    print(
      '🧭 FIX BUG 5: segBearing=${routeSegBearing.toStringAsFixed(1)}°, '
      'userBearing=${userBearing.toStringAsFixed(1)}°, diff=${absDiff.toStringAsFixed(1)}° '
      '→ movingTowardRoute=$movingToward (lateralDist=${minLateralDist.toStringAsFixed(1)}m)',
    );
    return movingToward;
  }

  /// Registra un overlay emesso nella sessione corrente.
  ///
  /// Viene chiamato ogni volta che il NavigationMonitor emette un overlay
  /// (svolta, strada laterale, arrivo). La registrazione include il tipo,
  /// il messaggio, e il timestamp.
  void _recordOverlayEvent(NavigationOverlayState overlayState) {
    if (_currentSession == null) {
      print(
        '⚠️ _recordOverlayEvent: _currentSession è NULL! Overlay perso: ${overlayState.type}',
      );
      return;
    }
    _currentSession!.overlays.add(
      OverlayRecord(
        type: overlayState.type.name,
        message: overlayState.message ?? '',
        timestamp: DateTime.now().toIso8601String(),
      ),
    );
    print(
      '📋 _recordOverlayEvent: Overlay registrato! Totale: ${_currentSession!.overlays.length}',
    );
  }
}
