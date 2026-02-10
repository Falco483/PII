# Navigation App - Flutter Android

App di navigazione stile Google Maps per **Android** in Flutter/Dart.

---

## Struttura File

```
lib/
├── main.dart                    # Entry point
├── screens/
│   └── navigation_screen.dart   # Schermata principale
├── services/
│   └── directions_service.dart  # Servizio API Directions
└── widgets/
    ├── map_widget.dart          # Widget mappa Google
    ├── search_input.dart        # Input partenza/destinazione
    └── directions_list.dart     # Lista indicazioni
```

---

## Come Avviare

### 1. Inserire la API Key

**File `android/app/src/main/AndroidManifest.xml`:**
```xml
<meta-data
    android:name="com.google.android.geo.API_KEY"
    android:value="LA_TUA_API_KEY"/>
```

**File `lib/services/directions_service.dart`:**
```dart
static const String apiKey = 'LA_TUA_API_KEY';
```

### 2. Avviare l'app

```bash
flutter pub get
flutter run
```

---

## API Google Richieste

In [Google Cloud Console](https://console.cloud.google.com/apis/library):

1. **Maps SDK for Android**
2. **Directions API**
