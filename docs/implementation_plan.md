# Google Maps Navigation Web App - Flutter/Dart

Creare una web app di navigazione stile Google Maps usando Flutter Web e Dart, con funzionalità MVP: mappa, ricerca percorso e indicazioni passo-passo.

---

## API Google richieste

- **Maps JavaScript API**
- **Directions API**
- **Geocoding API** (opzionale, per autocompletamento)

Queste devono essere abilitate nella [Google Cloud Console](https://console.cloud.google.com/apis/library).

---

## Struttura File

```
lib/
├── main.dart                    # Entry point modificato
├── screens/
│   └── navigation_screen.dart   # Schermata principale
├── services/
│   └── directions_service.dart  # Servizio API Directions
└── widgets/
    ├── map_widget.dart          # Widget mappa
    ├── search_input.dart        # Input partenza/destinazione
    └── directions_list.dart     # Lista indicazioni
```

---

## Descrizione Componenti

### Servizi

**directions_service.dart**
- Chiamata a Google Directions API
- Parsing risposta JSON
- Restituzione lista step con istruzioni
- Restituzione polyline per visualizzazione mappa

### Widget

**map_widget.dart**
- Visualizzazione mappa Google
- Gestione marker origine/destinazione
- Visualizzazione polyline del percorso

**directions_list.dart**
- Lista scrollabile indicazioni
- Istruzioni passo-passo con icone
- Distanza e durata per ogni step

**search_input.dart**
- Due TextField (partenza/destinazione)
- Pulsante calcolo percorso

### Schermate

**navigation_screen.dart**
- Combina tutti i widget
- Gestisce state dell'app
- Coordina chiamate a DirectionsService

---

## Configurazione API Key

1. Apri `web/index.html`
2. Sostituisci `YOUR_API_KEY_HERE` con la tua Google Maps API Key
3. Fai lo stesso in `lib/services/directions_service.dart`

---

## Come Avviare

```bash
flutter pub get
flutter run -d chrome
```
