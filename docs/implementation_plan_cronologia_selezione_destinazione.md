# Implementation Plan - Cronologia con sorgente destinazione

Obiettivo: differenziare il momento di salvataggio in cronologia in base a come viene scelta la destinazione:

- ricerca da barra: salvataggio immediato alla selezione (quando compare il log di selezione);
- tap su mappa: salvataggio differito, solo se dopo il tap l'utente preme "Indicazioni" oppure "Avvia".

Per il flusso ricerca, il riferimento resta il log:

Destinazione selezionata da ricerca: Milano MI, Italia (45.468503, 9.182402699999999)

In questo modo non serve piu' avviare la navigazione per salvare una destinazione selezionata da ricerca, mentre per il tap mappa il salvataggio resta legato all'intenzione esplicita di navigare.

## Stato attuale

Attualmente la registrazione in cronologia avviene in `NavigationScreen._calculateRouteFromCoordinates(...)`, prima della chiamata a Directions API.

Conseguenza:

- la destinazione viene salvata solo quando parte il flusso di calcolo percorso;
- non c'e' distinzione tra sorgente "ricerca" e sorgente "tap mappa";
- il comportamento richiesto (ricerca immediata vs tap differito) non e' ancora rispettato.

## Modifica richiesta

Applicare una logica a doppio comportamento:

- se la destinazione arriva da ricerca, salvarla subito in `_onDestinationSelected(...)`;
- se la destinazione arriva da tap mappa, salvarla solo alla pressione di "Indicazioni" o "Avvia".

## Proposed Changes

### 1) Introdurre tracciamento della sorgente destinazione

File: `lib/screens/navigation_screen.dart`

Intervento:

- aggiungere un indicatore di sorgente, ad esempio enum o flag:
  - `DestinationSelectionSource.search`
  - `DestinationSelectionSource.mapTap`
- aggiornare il flag in:
  - `_onDestinationSelected(...)` -> `search`
  - `_onMapTapped(...)` -> `mapTap`

Motivazione:

- consente di decidere in modo deterministico quando salvare in cronologia.

### 2) Salvataggio immediato per selezione da ricerca

File: `lib/screens/navigation_screen.dart`

Intervento:

- in `_onDestinationSelected(double lat, double lng, String address)` aggiungere:
  - costruzione `SearchHistoryItem(address, lat, lng, timestamp)`;
  - chiamata a `await _searchHistoryService.recordSearch(...)`.

Nota tecnica:

- il metodo puo' diventare `Future<void>` o `async void` in base alla firma del callback usata dal widget di ricerca.
- mantenere il log esistente invariato, per avere la stessa traccia di debug del momento di selezione.

### 3) Salvataggio differito per tap su mappa (solo su azione utente)

File: `lib/screens/navigation_screen.dart`

Intervento:

- non salvare cronologia in `_onMapTapped(...)`.
- al click su "Indicazioni" oppure "Avvia", se la sorgente corrente e' `mapTap`, salvare la destinazione in cronologia prima di proseguire con il flusso.
- aggiungere una guardia anti-doppio-salvataggio per la stessa destinazione selezionata, ad esempio con flag temporaneo o controllo su ultimo elemento gia' registrato in sessione.

Motivazione:

- il tap mappa puo' essere esplorativo; la cronologia va aggiornata solo con intenzione esplicita di navigazione.

### 4) Rimuovere il salvataggio "generico" dal calcolo percorso

File: `lib/screens/navigation_screen.dart`

Intervento:

- eliminare da `_calculateRouteFromCoordinates(...)` il blocco che salva la cronologia.

Motivazione:

- il punto di salvataggio deve dipendere dalla sorgente evento e non dal metodo tecnico di calcolo;
- si evita che entrambe le sorgenti passino da un salvataggio indistinto.

### 5) Gestione errori non bloccante per la UX

File: `lib/screens/navigation_screen.dart`

Intervento:

- il salvataggio cronologia in `_onDestinationSelected` non deve bloccare il rendering del pin destinazione.
- anche nel caso `mapTap` + "Indicazioni"/"Avvia", eventuali errori di storage non devono bloccare il calcolo percorso o l'avvio navigazione.
- in caso di errore storage, loggare l'errore e continuare comunque con l'aggiornamento UI (`_selectedDestinationAddress`, `_appState`, `_directionsResult`).

## Impatto atteso

- Da ricerca: la cronologia si aggiorna immediatamente alla selezione.
- Da tap mappa: la cronologia si aggiorna solo se l'utente conferma con "Indicazioni" o "Avvia".
- Nessuna regressione nel flusso di calcolo percorso e avvio navigazione.

## Verification Plan

1. Caso ricerca:

- cercare "Milano MI, Italia" dalla barra ricerca;
- selezionare il risultato e verificare il log `Destinazione selezionata da ricerca: ...`;
- senza premere "Indicazioni", riaprire i suggerimenti e verificare che la destinazione sia in cronologia.

2. Caso tap mappa senza conferma:

- fare tap su un punto mappa;
- non premere "Indicazioni" o "Avvia";
- verificare che la destinazione non venga salvata in cronologia.

3. Caso tap mappa con conferma:

- fare tap su un punto mappa;
- premere "Indicazioni" (o direttamente "Avvia" se disponibile);
- verificare che la destinazione venga salvata in cronologia.

4. Verificare assenza di duplicati anomali quando si ripete il flusso sulla stessa destinazione.

## Criteri di accettazione

- AC1: per destinazioni da ricerca, la registrazione avviene al momento della selezione.
- AC2: per destinazioni da tap mappa, la registrazione avviene solo dopo pressione di "Indicazioni" o "Avvia".
- AC3: il tap mappa senza conferma non produce inserimenti in cronologia.
- AC4: non si introducono duplicati anomali rispetto alla logica di dedup esistente.
