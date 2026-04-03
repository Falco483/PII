# Casi d'Uso - Applicazione di Navigazione

## Attori
- **Utente**: La persona che utilizza il dispositivo per la navigazione.
- **Sistema**: L'applicazione client Flutter.
- **Servizi Esterni**: Google Maps API (Directions, Places, Roads).

---

## 1. Cercare destinazione
**Descrizione**: L'utente inserisce testo nella barra di ricerca ed estrae i luoghi corrispondenti.
**Attori**: Utente, Sistema, Servizi Esterni (Places API).
**Flusso Principale**:
1. L'utente digita un indirizzo parziale.
2. Il Sistema interroga Places API (autocomplete).
3. Il Sistema mostra suggerimenti auto-completati a cascata.
4. L'utente seleziona un suggerimento.
5. Il Sistema interroga Places API per risolvere l'indirizzo nelle coordinate esatte.

---

## 2. Visualizzare percorso
**Descrizione**: L'utente richiede le indicazioni stradali per il luogo selezionato.
**Attori**: Utente, Sistema, Servizi Esterni (Directions API).
**Flusso Principale**:
1. L'utente preme il pulsante "Indicazioni".
2. Il Sistema calcola il bounding box che collega l'origine e la destinazione.
3. Il Sistema invia la richiesta asincrona a Directions API.
4. Il Sistema elabora il JSON di risposta tracciando la Polyline ("best route") sulla mappa.
5. Il Sistema espone la vista utente completa di banner della durata in minuti e della distanza in km.

---

## 3. Avviare e monitorare la navigazione
**Descrizione**: Inizia il monitoraggio attivo del GPS lungo il tragitto pianificato.
**Attori**: Utente, Sistema.
**Flusso Principale**:
1. L'utente preme il pulsante primario "Avvia".
2. Il Sistema acquisisce il lock sul GPS e sul magnetometro iniziando lo stream periodico.
3. Il Sistema incrocia costantemente le coordinate utente con gli `Steps` calcolati.
4. La telecamera automatizza l'angolo visuale e segue lo spostamento reale via Polyline.
5. Il Sistema dirama eventi visuali alla UI in base alle posizioni (istruzioni di svolta e notifiche push contestuali).
6. Una volta vicinissimo alla meta, viene validata la sequenza ed emesso il BottomSheet "Sei Arrivato".

---

## 4. Ricevere analisi strade parallele
**Descrizione**: Il sistema valuta l'incostanza dello stream e protegge contro errori GPS qualora l'utente sia fermo di fianco ad incroci equivoci.
**Attori**: Sistema, Servizi Esterni (Roads API).
**Flusso Principale**:
1. Il sensore GPS stima una derivazione di velocità molto vicina allo 0.
2. Un timer di 10 secondi esegue un countdown controllato dal Sistema.
3. Lo stream interpella la Roads API passandogli le coordinate spazzate lateralmente.
4. Constatata un'alta confidenza in strade vicine, il Sistema proietta il rinforzo positivo "continua dritto stai andando bene".

---

## 5. Ricalcolo del percorso (Rerouting)
**Descrizione**: L'utente prende una strada errata e il percorso viene aggiornato per riagganciare la strada giusta.
**Attori**: Utente, Sistema, Servizi Esterni (Directions API).
**Flusso Principale**:
1. Il Sistema individua una traslazione logica incompatibile con la tolleranza del segmento attivo (>30m errore).
2. Tenta preliminarmente il match all'interno delle Rotte Alternative precaricate in memoria per velocizzare.
3. In caso di fallimento, un overlay asincrono blocca la UI annunciando "Ricalcolo in corso".
4. Viene consumata una nuova query API per stabilire ex-novo il best route dall'origine corrente.
5. Viene esposta all'utente l'opportunità di approvare il roll-forward sul nuovo itinerario o rifiutarlo.
