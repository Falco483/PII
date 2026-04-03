# UX/UI Description & User Experience Assessment

### Architettura dell'interfaccia (Material Design Platform)
L'applicazione fa un uso massivo di componenti nativi ed espansi per il framework Flutter, mantenendo rigorosamente il focus sull'accessibilità cognitiva e riducendo al minimo l'eccesso visivo potenziale.
L'interfaccia segue un pattern Single-Page-Application (SPA) adattato per il mobile: un singolo widget manager, il `NavigationScreen`, coordina le transizioni degli strati senza ricorrere ad un app-routing spaghettato. Gestisce le mutazioni logiche direttamente tramutandole in strati di layer (es. search overlay -> route preview dialog).

### Sovrapposizione Z-Index (Livelli della View):
1. **Z-Index 0 (Base)**: Il Render Surface occupato dal `MapWidget` (Google Maps Android Rendering View). Include le Polyline tracciate ma nasconde attivamente elementi distraenti come i MapControls nativi.
2. **Z-Index 1 (Overlay Controlli Superiori)**: La barra di ricerca (`SearchInput`) tranciabile, reattiva in auto-hide al dismiss della keyboard.
3. **Z-Index 2 (Modal & BottomSheets)**: Finestre modali comportamentali (`DirectionsList` e riepiloghi di fine corsa) che scorrono a comparsa dal basso in maniera Draggable. Questa meccanica incoraggia lo swiping agevole da una singola mano.
4. **Z-Index 3 (Banner di Allerta e Notifica)**: Il container `NavigationOverlay`, appeso ad altissima priorità alla root visiva, che interviene in determinati tick della lifecycle iniettando testo rafforzante o avvisi di ricalcolo animati da una mascotte.

### Design Pattern per Accessibilità Cognitiva:
- **Testo e Colore Semantico Coordinato**: Le colorway rispondono all'infrastruttura di feedback. Segnali informativi usano blu neutrali, segnali di instabilità (come il lateral road fallback) usano arancioni di warning affievoliti per destare l'attenzione senza indurre panico, segnali di goal completato (arrivo) attivano verdi celebrativi.
- **Costruzione Morfologica Semplice**: Completa assenza del gergo tecnico della navigazione (niente calcoli sui bearing gradi, coordinate GPS o log sui fallback). Totale predisposizione di messaggi attivi a cinque parole, assistiti da emoji di parsing visivo come `👉` o `✅`.
- **Grace Period Dinamici (Delayed UI)**: Elementi come il checkmark di fine tragitto o l'errore del ricalcolo vengono "rallentati" via Future logic a passaggi di 1.5/2 secondi in un'animazione a 3 step progressivi. Questa scelta protegge gli utenti da una cascata di informazioni immediate che stresserebbe il focus cognitivo.
