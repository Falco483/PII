/// SearchInput — Widget per la ricerca con Places Autocomplete (TASK 1 + TASK 2)
///
/// Questo widget fornisce:
/// 1. Un campo di testo per la destinazione con autocomplete
/// 2. Lista di suggerimenti che appare sotto il campo mentre si digita
/// 3. Debounce di 300ms (non invia richieste ad ogni battitura)
/// 4. Filtro minimo 3 caratteri (non invia richieste per input troppo corti)
/// 5. Session Token che raggruppa autocomplete + details in una sessione
///
/// FLUSSO DI INTERAZIONE:
/// 1. L'utente digita nella barra di ricerca
/// 2. Dopo 300ms di inattività E se input >= 3 caratteri:
///    - Genera un session token (se non ce n'è già uno)
///    - Chiama Places Autocomplete API con il token
///    - Mostra i suggerimenti in una lista sotto il campo
/// 3. L'utente tocca un suggerimento:
///    - Chiama Places Details API con lo STESSO token
///    - Ottiene le coordinate (lat/lng)
///    - Chiude la lista suggerimenti
///    - Riempie il campo di testo con l'indirizzo selezionato
///    - Rinnova il session token per la prossima ricerca
///    - Notifica il parent con le coordinate (callback onDestinationSelected)
///
/// PERCHÉ È UN STATEFULWIDGET:
/// Deve gestire stato interno: timer di debounce, lista suggerimenti,
/// session token, stato di caricamento.
library;

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart';
import '../models/search_history_item.dart';
import '../services/places_service.dart';

/// Widget per la ricerca della destinazione con autocomplete
class SearchInput extends StatefulWidget {
  /// Controller per il campo di testo della destinazione.
  /// Il parent (NavigationScreen) lo usa per leggere/scrivere il testo.
  final TextEditingController destinationController;

  /// Callback chiamato quando l'utente seleziona un suggerimento.
  /// Riceve latitudine, longitudine e indirizzo formattato.
  /// Il parent usa queste coordinate per calcolare il percorso (TASK 4).
  final void Function(double lat, double lng, String address)
  onDestinationSelected;

  /// Flag per mostrare il caricamento del percorso (non dell'autocomplete).
  /// Mentre il percorso è in fase di calcolo, il widget viene disabilitato.
  final bool isLoading;

  /// Nodo di focus per il campo di testo.
  /// Gestito dal parent per sapere quando la barra di ricerca è attiva.
  final FocusNode focusNode;

  /// Ultime ricerche recenti (massimo 3) da mostrare quando il campo è vuoto.
  /// Passate dalla NavigationScreen che le carica dal SearchHistoryService.
  final List<SearchHistoryItem> recentSearches;

  /// Costruttore — tutti i parametri tranne isLoading e recentSearches sono obbligatori.
  const SearchInput({
    super.key,
    required this.destinationController,
    required this.onDestinationSelected,
    required this.focusNode,
    this.isLoading = false,
    this.recentSearches = const [],
  });

  @override
  State<SearchInput> createState() => _SearchInputState();
}

class _SearchInputState extends State<SearchInput> {
  // ===========================================================================
  // COSTANTI
  // ===========================================================================

  /// Durata del debounce in millisecondi.
  ///
  /// PERCHÉ 300ms:
  /// - Una persona digita mediamente 5-7 caratteri al secondo
  /// - 300ms è il tempo tra una battitura e l'altra se si digita velocemente
  /// - Con 300ms di debounce, se l'utente digita "Duomo di Milano" in modo
  ///   fluido, vengono inviate ~2-3 richieste invece di 15
  /// - Se fosse troppo corto (es. 100ms) non risparmieremmo molto
  /// - Se fosse troppo lungo (es. 1000ms) l'utente percepirebbe lentezza
  static const int _debounceDurationMs = 300;

  /// Numero minimo di caratteri per inviare una richiesta API.
  ///
  /// PERCHÉ 3 CARATTERI:
  /// - Con 1 carattere (es. "R") la API restituirebbe risultati troppo
  ///   generici e inutili (Roma, Rimini, Ravenna, Ragusa...)
  /// - Con 2 caratteri (es. "Ro") ancora troppo generici
  /// - Con 3 caratteri (es. "Rom") i risultati iniziano ad essere pertinenti
  /// - Sotto i 3 caratteri sprechiamo chiamate API senza beneficio per l'utente
  static const int _minInputLength = 3;

  // ===========================================================================
  // STATO INTERNO
  // ===========================================================================

  /// Istanza del servizio Places API per le chiamate autocomplete e details
  final PlacesService _placesService = PlacesService();

  /// Session token corrente per raggruppare le chiamate API.
  ///
  /// Viene generato alla prima digitazione dell'utente e riutilizzato
  /// per tutte le chiamate autocomplete successive + la chiamata details.
  /// Dopo la selezione di un suggerimento, viene rigenerato.
  String _sessionToken = '';

  /// Flag che indica se il token è stato generato per la sessione corrente.
  /// Serve per sapere quando generare un nuovo token: solo alla PRIMA
  /// digitazione di una nuova sessione di ricerca.
  bool _hasActiveSession = false;

  /// Timer per il debounce. Viene cancellato e ricreato ad ogni battitura.
  ///
  /// COME FUNZIONA IL DEBOUNCE:
  /// 1. L'utente digita 'D' → crea timer di 300ms
  /// 2. L'utente digita 'u' (dopo 100ms) → CANCELLA il timer precedente,
  ///    crea un NUOVO timer di 300ms
  /// 3. L'utente digita 'o' (dopo 150ms) → CANCELLA, crea nuovo timer
  /// 4. L'utente smette di digitare → il timer scade dopo 300ms → INVIA richiesta
  ///
  /// Risultato: viene inviata UNA sola richiesta per "Duo" invece di tre
  /// richieste per "D", "Du", "Duo".
  Timer? _debounceTimer;

  /// Lista dei suggerimenti ricevuti dall'API Autocomplete.
  /// Vuota = nessun suggerimento da mostrare.
  /// Quando l'utente seleziona un suggerimento, la lista viene svuotata.
  List<PlaceSuggestion> _suggestions = [];

  /// Flag di caricamento per l'autocomplete (diverso da widget.isLoading
  /// che è per il calcolo del percorso).
  bool _isLoadingSuggestions = false;

  final SpeechToText _speechToText = SpeechToText();
  bool _speechEnabled = false;
  bool _isListening = false;

  // ===========================================================================
  // CICLO DI VITA
  // ===========================================================================

  @override
  void initState() {
    super.initState();
    // Ascolta i cambiamenti di focus per mostrare/nascondere la cronologia
    widget.focusNode.addListener(() {
      if (mounted) {
        // Quando perde il focus chiudiamo anche eventuali suggerimenti rimasti aperti
        if (!widget.focusNode.hasFocus) {
          _suggestions = [];
        }
        setState(() {}); // Ricostruisce per aggiornare la visibilità della history
      }
    });
    _initSpeech();
  }

  Future<void> _initSpeech() async {
    _speechEnabled = await _speechToText.initialize();
    if (mounted) setState(() {});
  }

  Future<void> _startListening() async {
    if (!_speechEnabled) return;
    await _speechToText.listen(
      onResult: (result) {
        if (result.finalResult) {
          widget.destinationController.text = result.recognizedWords;
          _onTextChanged(result.recognizedWords);
          setState(() { _isListening = false; });
        } else {
          widget.destinationController.text = result.recognizedWords;
          setState(() {});
        }
      },
      localeId: 'it_IT',
      cancelOnError: true,
      partialResults: true,
    );
    setState(() { _isListening = true; });
  }

  Future<void> _stopListening() async {
    await _speechToText.stop();
    setState(() { _isListening = false; });
  }

  @override
  void dispose() {
    // Cancella il timer di debounce per evitare memory leak.
    // Se il timer è ancora attivo quando il widget viene distrutto,
    // il callback del timer tenterà di chiamare setState() su un widget
    // non più montato, causando un errore.
    _debounceTimer?.cancel();
    _speechToText.cancel();

    // Chiama il dispose del parent (StatefulWidget)
    super.dispose();
  }

  // ===========================================================================
  // LOGICA AUTOCOMPLETE
  // ===========================================================================

  /// Callback chiamato ad ogni modifica del testo nel campo destinazione.
  ///
  /// Implementa il flusso: digitazione → debounce → min chars → API call.
  ///
  /// PARAMETRI:
  /// - [value]: testo corrente nel campo di input
  void _onTextChanged(String value) {
    // --- STEP 1: Cancella il timer di debounce precedente ---
    // Se l'utente sta ancora digitando (il timer precedente non è scaduto),
    // lo cancelliamo per ricominciare il conteggio da zero.
    _debounceTimer?.cancel();

    // --- STEP 2: Controlla il numero minimo di caratteri ---
    // Se il testo è troppo corto, non inviamo nessuna richiesta.
    // Svuotiamo anche la lista dei suggerimenti perché eventuali risultati
    // precedenti non sono più pertinenti per un input così corto.
    if (value.length < _minInputLength) {
      // Svuota i suggerimenti se il testo è troppo corto
      setState(() {
        _suggestions = [];
      });
      // Non creiamo nessun timer: non c'è nulla da cercare
      return;
    }

    // --- STEP 3: Genera il session token se necessario ---
    // Il token viene generato UNA sola volta per sessione di ricerca.
    // "Sessione" = dall'inizio della digitazione fino alla selezione
    // di un suggerimento. Dopo la selezione, _hasActiveSession torna
    // a false e alla prossima digitazione verrà generato un nuovo token.
    if (!_hasActiveSession) {
      // Genera un nuovo UUID v4 come session token
      _sessionToken = generateSessionToken();
      // Segna che la sessione è attiva (non rigenerare il token)
      _hasActiveSession = true;
      // Log per debugging
      print('Nuova sessione di ricerca. Token: $_sessionToken');
    }

    // --- STEP 4: Crea il timer di debounce ---
    // Il timer aspetta 300ms DOPO L'ULTIMA BATTITURA prima di chiamare l'API.
    // Se l'utente digita un altro carattere prima che i 300ms scadano,
    // il timer viene cancellato (step 1 al prossimo _onTextChanged)
    // e ricreato con un nuovo countdown di 300ms.
    _debounceTimer = Timer(
      const Duration(milliseconds: _debounceDurationMs),
      () {
        // Il timer è scaduto: l'utente ha smesso di digitare per 300ms.
        // Ora possiamo inviare la richiesta API.
        _fetchSuggestions(value);
      },
    );
  }

  /// Chiama la Places Autocomplete API e aggiorna la lista dei suggerimenti.
  ///
  /// Questa funzione viene chiamata SOLO dopo che il debounce è scaduto,
  /// quindi viene invocata molto meno frequentemente di _onTextChanged.
  ///
  /// PARAMETRI:
  /// - [input]: testo digitato dall'utente (già verificato >= 3 caratteri)
  Future<void> _fetchSuggestions(String input) async {
    // Mostra l'indicatore di caricamento sotto il campo di testo
    setState(() {
      _isLoadingSuggestions = true;
    });

    // Chiama il servizio Places API con il testo e il session token.
    // Il token è lo STESSO per tutta la sessione di ricerca.
    final suggestions = await _placesService.getAutocompleteSuggestions(
      input,
      _sessionToken,
    );

    // Aggiorna la UI con i suggerimenti ricevuti (o lista vuota se nessuno)
    // Verifica che il widget sia ancora montato prima di chiamare setState.
    // Tra la chiamata API e la risposta, l'utente potrebbe aver navigato
    // via dalla schermata, e setState() su un widget non montato è un errore.
    if (mounted) {
      setState(() {
        _suggestions = suggestions;
        _isLoadingSuggestions = false;
      });
    }
  }

  /// Gestisce la selezione di un suggerimento dall'elenco.
  ///
  /// FLUSSO:
  /// 1. Chiama Places Details API con il placeId del suggerimento selezionato
  ///    usando lo STESSO session token dell'autocomplete
  /// 2. Ottiene le coordinate (lat/lng) del luogo
  /// 3. Aggiorna il campo di testo con l'indirizzo selezionato
  /// 4. Chiude la lista dei suggerimenti
  /// 5. Rinnova il session token per la prossima ricerca
  /// 6. Notifica il parent (NavigationScreen) con le coordinate
  ///
  /// PARAMETRI:
  /// - [suggestion]: il suggerimento selezionato dall'utente
  Future<void> _onSuggestionSelected(PlaceSuggestion suggestion) async {
    // Mostra il caricamento mentre la Details API risponde
    setState(() {
      _isLoadingSuggestions = true;
      // Chiude immediatamente la lista dei suggerimenti per feedback visivo
      _suggestions = [];
    });

    // Imposta il testo del campo con la descrizione del luogo selezionato.
    // Questo dà all'utente un feedback immediato su cosa ha selezionato.
    widget.destinationController.text = suggestion.description;

    // Chiama Places Details API usando lo STESSO session token.
    // Questo è il momento cruciale per la fatturazione: Google
    // raggruppa tutte le autocomplete + questa details come UNA sessione.
    final details = await _placesService.getPlaceDetails(
      suggestion.placeId,
      _sessionToken,
    );

    // --- FINE SESSIONE: rinnova il token ---
    // La sessione di ricerca è finita (l'utente ha selezionato un risultato).
    // Resettiamo il flag per far sì che alla prossima digitazione
    // venga generato un NUOVO token.
    _hasActiveSession = false;

    // Log per debugging
    print('Sessione terminata. Prossima digitazione genererà nuovo token.');

    // Nascondi il caricamento
    if (mounted) {
      setState(() {
        _isLoadingSuggestions = false;
      });
    }

    // Se i dettagli sono disponibili, notifica il parent con le coordinate
    if (details != null) {
      // Chiama il callback del parent (NavigationScreen) con:
      // - lat/lng: coordinate del luogo per il calcolo del percorso
      // - address: indirizzo formattato per mostrare nell'UI
      widget.onDestinationSelected(
        details.lat,
        details.lng,
        details.formattedAddress.isNotEmpty
            ? details.formattedAddress
            : suggestion.description,
      );
    }
  }

  // ===========================================================================
  // BUILD UI
  // ===========================================================================

  @override
  Widget build(BuildContext context) {
    return Container(
      // Padding interno del container
      padding: const EdgeInsets.all(16),
      // Decorazione del container: sfondo bianco con ombra
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.1),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        // La colonna si adatta alla dimensione dei figli
        mainAxisSize: MainAxisSize.min,
        children: [
          // --- TITOLO --- Amichevole per ragazzi con disabilità cognitive
          Text(
            'Dove vuoi andare?',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: Colors.blue.shade800,
            ),
          ),
          // Spazio tra titolo e campo di testo
          const SizedBox(height: 16),

          // --- CAMPO DI TESTO DESTINAZIONE ---
          // Questo è il campo principale dove l'utente digita la destinazione.
          // Il callback onChanged attiva la logica di debounce + autocomplete.
          TextFormField(
            // Controller passato dal parent per leggere/scrivere il testo
            controller: widget.destinationController,
            focusNode: widget.focusNode,
            enabled: !widget.isLoading, // Disabilita durante il calcolo
            // Callback chiamato ad ogni modifica del testo (ogni battitura)
            onChanged: _onTextChanged,
            // Font grande per accessibilità
            style: const TextStyle(fontSize: 18),
            // Decorazione del campo di testo
            decoration: InputDecoration(
              // Etichetta sopra il campo quando è attivo
              labelText: 'Destinazione',
              labelStyle: const TextStyle(fontSize: 16),
              // Testo suggerimento quando il campo è vuoto
              hintText: 'Scrivi dove vuoi andare...',
              hintStyle: TextStyle(fontSize: 16, color: Colors.grey.shade500),
              // Icona a sinistra del campo (pin rosso)
              prefixIcon: const Icon(Icons.place, color: Colors.red),
              // Icona a destra: mostra il caricamento se in corso,
              // oppure un pulsante per cancellare il testo
              suffixIcon: _isLoadingSuggestions
                  // Se sta caricando, mostra un indicatore di progresso
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  // Se il campo non è vuoto, mostra un pulsante "X"
                  // per cancellare rapidamente il testo
                  : widget.destinationController.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        // Svuota il campo di testo
                        widget.destinationController.clear();
                        // Svuota la lista dei suggerimenti
                        setState(() {
                          _suggestions = [];
                        });
                      },
                    )
                  : _speechEnabled
                      ? IconButton(
                          icon: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 200),
                            child: _isListening
                                ? const Icon(Icons.mic, color: Colors.red, key: ValueKey('mic_on'))
                                : const Icon(Icons.mic_none, color: Colors.grey, key: ValueKey('mic_off')),
                          ),
                          onPressed: _isListening ? _stopListening : _startListening,
                          tooltip: _isListening ? 'Ferma ascolto' : 'Cerca con la voce',
                        )
                      : null,
              // Bordo standard del campo
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              // Bordo quando il campo è attivo (focus)
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: Colors.blue, width: 2),
              ),
              // Sfondo leggermente grigio
              filled: true,
              fillColor: Colors.grey.shade50,
            ),
          ),

          // --- LISTA SUGGERIMENTI AUTOCOMPLETE ---
          // Mostrata solo se ci sono suggerimenti disponibili.
          // La lista appare direttamente sotto il campo di testo.
          if (_suggestions.isNotEmpty)
            _buildDropdown(
              children: _suggestions.map((suggestion) {
                return ListTile(
                  leading: const Icon(
                    Icons.location_on_outlined,
                    color: Colors.blue,
                    size: 28,
                  ),
                  title: Text(
                    suggestion.description,
                    style: const TextStyle(fontSize: 16),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  onTap: () => _onSuggestionSelected(suggestion),
                );
              }).toList(),
            ),

          // --- CRONOLOGIA RICERCHE RECENTI ---
          // Visibile SOLO quando:
          //  1. Il campo di testo è focalizzato (l'utente ha toccato la barra)
          //  2. Il campo di testo è vuoto (l'utente non sta digitando)
          //  3. Non ci sono suggerimenti API in corso
          //  4. Ci sono ricerche recenti da mostrare
          if (widget.focusNode.hasFocus &&
              _suggestions.isEmpty &&
              widget.destinationController.text.isEmpty &&
              widget.recentSearches.isNotEmpty)
            _buildDropdown(
              header: Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
                child: Text(
                  'Ricerche recenti',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Colors.grey.shade500,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
              children: widget.recentSearches.map((item) {
                return ListTile(
                  leading: const Icon(
                    Icons.history,
                    color: Colors.grey,
                    size: 26,
                  ),
                  title: Text(
                    item.address,
                    style: const TextStyle(fontSize: 16),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  // Al tap, usa direttamente le coordinate salvate
                  // senza chiamare nessuna API (è già tutto in memoria)
                  onTap: () {
                    // Toglie il focus per chiudere la tendina
                    widget.focusNode.unfocus();
                    
                    widget.destinationController.text = item.address;
                    setState(() {
                      _suggestions = [];
                    });
                    widget.onDestinationSelected(
                      item.lat,
                      item.lng,
                      item.address,
                    );
                  },
                );
              }).toList(),
            ),

          // --- INDICATORE "CARICAMENTO IN CORSO" ---
          // Mostrato mentre il percorso è in fase di calcolo (TASK 4)
          if (widget.isLoading)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 3),
                  ),
                  SizedBox(width: 10),
                  Text(
                    'Sto preparando il percorso...',
                    style: TextStyle(fontSize: 16),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  // ===========================================================================
  // HELPER UI
  // ===========================================================================

  /// Contenitore a tendina condiviso da suggerimenti autocomplete e cronologia.
  Widget _buildDropdown({
    required List<Widget> children,
    Widget? header,
  }) {
    return Container(
      margin: const EdgeInsets.only(top: 4),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.shade300),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.1),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      constraints: const BoxConstraints(maxHeight: 240),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: ListView(
          shrinkWrap: true,
          padding: EdgeInsets.zero,
          children: [
            ?header,
            ...children,
          ],
        ),
      ),
    );
  }
}
