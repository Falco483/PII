# Presentazione Progetto: Smart Navigation App
*Traccia testuale per la creazione delle 10 slide in PowerPoint.*

---

## SLIDE 1: Titolo
**Titolo Principale:** Smart Navigation App
**Sottotitolo:** Un'applicazione di navigazione mobile reattiva, sicura e contestuale.
**Testo in basso:** 
- Sviluppato da: Antonio
- Corso/Esame: [Inserire Nome Corso]
- Data: [Inserire Data]

---

## SLIDE 2: Il Problema
**Titolo:** Perché un nuovo navigatore? (Il Problema)
**Punti Elenco:**
- **Feature Creep:** I navigatori moderni (Google Maps, Waze) sono diventati "super-app" cariche di distrazioni (social, pubblicità, recensioni).
- **Carico Cognitivo:** Troppe informazioni a schermo aumentano i tempi di reazione del guidatore.
- **Ricalcoli Inefficienti:** I sistemi tradizionali usano "geofence" circolari larghi. Accorgersi di aver sbagliato strada richiede troppo tempo e spazio percorso.

---

## SLIDE 3: Obiettivi del Progetto
**Titolo:** Gli Obiettivi
**Punti Elenco:**
- **Reattività:** Sviluppare un algoritmo matematico proprietario per il ricalcolo istantaneo del percorso.
- **Minimalismo UI/UX:** Fornire informazioni essenziali riducendo a zero le distrazioni.
- **Consapevolezza (Context Awareness):** Avvisare l'utente del contesto stradale circostante solo quando è sicuro farlo (es. veicolo fermo).
- **Fluidità:** Implementare un'architettura "Single-Screen" senza caricamenti tra le pagine di ricerca e navigazione.

---

## SLIDE 4: Lavori Correlati (Stato dell'Arte)
**Titolo:** Analisi dei Competitor
**Tabella o Punti Elenco Comparativi:**
- **Google Maps:** Dati eccellenti, ma appesantito da POI commerciali. Ricalcolo conservativo.
- **Waze:** Ottimo crowdsourcing, ma UI "giocattolosa" e confusionaria. Propone deviazioni troppo complesse.
- **Apple Maps:** Design pulito, ma chiuso nell'ecosistema iOS.
- **La Nostra Soluzione:** Prende il minimalismo di Apple Maps, ma aggiunge intelligenza locale (calcoli on-device) e supporto multipiattaforma (Android/iOS).

---

## SLIDE 5: L'Innovazione - Lateral Road Detection
**Titolo:** Innovazione: Rilevamento Strade Laterali
**Contenuto:**
- **Cos'è:** Il sistema "sente" le strade adiacenti agli incroci.
- **Come funziona (Il Cooldown Logico):**
  - Si attiva *solo* se la velocità scende a 0 (es. semaforo rosso).
  - Utilizza un timer di "cooldown" per non inondare l'utente (e i server) di richieste in caso di traffico stop-and-go.
  - Verifica di non essere vicino a una svolta critica per non confondere le istruzioni.
*(Spazio per inserire lo screenshot dell'overlay arancione delle strade laterali)*

---

## SLIDE 6: L'Innovazione - Ricalcolo Geometrico
**Titolo:** Innovazione: Geometric Off-Route
**Contenuto:**
- **Approccio Standard:** Geofence circolare attorno al GPS.
- **Nostro Approccio (Punto-Poligono):** Calcolo in tempo reale della *distanza proiettata ortogonalmente* tra l'auto e i vettori della polyline del percorso.
- **Vantaggio:** Il sistema capisce in frazioni di secondo se si sta percorrendo una strada parallela errata, innescando il ricalcolo molto prima dei sistemi commerciali.

---

## SLIDE 7: Sviluppo e Tecnologie
**Titolo:** Lo Stack Tecnologico
**Punti Elenco:**
- **Framework:** Flutter (rendering a 60 fps nativo).
- **Linguaggio:** Dart (gestione eccellente dell'asincronia tramite Future/Stream per il GPS).
- **API (Google Maps Platform):**
  - *Directions API* (routing).
  - *Places Autocomplete* (ricerca).
  - *Snap-to-Roads* (rilevamento laterale).
- **Librerie Core:** `geolocator` (stream GPS hardware), `flutter_polyline_points`.

---

## SLIDE 8: Architettura del Sistema
**Titolo:** Architettura a Livelli (Layered Architecture)
**Contenuto:**
- **Domain Logic:** `NavigationMonitor` (Il "cervello", ascolta il GPS e calcola le distanze).
- **State Management:** `NavigationHistoryService` (Gestisce lo stack LIFO dell'interfaccia senza ricaricare la mappa).
- **Data Layer:** Servizi di rete isolati che dialogano in JSON con i server Google.
*(Spazio per incollare il diagramma a blocchi o il diagramma di stato)*

---

## SLIDE 9: Risultati (Demo UI)
**Titolo:** Risultati Visivi
**Contenuto:**
*(Layout suggerito: 3 o 4 screenshot affiancati con brevi didascalie)*
- **Screen 1:** Ricerca fluida.
- **Screen 2:** Anteprima del percorso vettoriale.
- **Screen 3:** Navigazione attiva (Tilt 3D, Chevron direzionali generati dinamicamente).
- **Screen 4:** Ricalcolo istantaneo in caso di deviazione.

---

## SLIDE 10: Conclusioni
**Titolo:** Conclusioni e Sviluppi Futuri
**Punti Elenco:**
- **Traguardi:** Sviluppata un'app robusta, fluida e con logiche spaziali avanzate che superano i limiti dei framework standard.
- **UX Sicura:** Dimostrata la fattibilità di un'interfaccia "distraction-free".
- **Sviluppi Futuri:**
  - Motore di routing Offline (OpenStreetMap).
  - Dati sul traffico in tempo reale.
  - Sintesi Vocale nativa (Text-to-Speech) per le istruzioni.

---
*Fine della presentazione*
