# Reverse Geocoding al Tap sulla Mappa

Quando l'utente tocca un punto sulla mappa, mostrare il nome della via/luogo nella barra di ricerca anziché le coordinate raw.

## Proposed Changes

### PlacesService

#### [MODIFY] [places_service.dart](file:///c:/Users/Antonio/Desktop/pii2/lib/services/places_service.dart)

Aggiungere un metodo `reverseGeocode(double lat, double lng)` che chiama la **Google Geocoding API** (`https://maps.googleapis.com/maps/api/geocode/json?latlng=...&key=...&language=it`).

- Restituisce l'`formatted_address` del primo risultato, oppure `null` in caso di errore.
- Usa la stessa `apiKey` già presente nel servizio.

---

### NavigationScreen

#### [MODIFY] [navigation_screen.dart](file:///c:/Users/Antonio/Desktop/pii2/lib/screens/navigation_screen.dart)

Modificare [_onMapTapped](file:///c:/Users/Antonio/Desktop/pii2/lib/screens/navigation_screen.dart#520-562) (riga 532):

1. Rendere il metodo `async`.
2. Impostare subito lo stato `placeSelected` con le coordinate come testo temporaneo (feedback istantaneo).
3. Chiamare [PlacesService().reverseGeocode(lat, lng)](file:///c:/Users/Antonio/Desktop/pii2/lib/services/places_service.dart#185-380) in background.
4. Se la risposta contiene un indirizzo, aggiornare `_destinationController.text` e `_selectedDestinationAddress` con l'indirizzo reale.

Questo approccio dà un feedback visivo immediato (coordinate) che viene poi sostituito dall'indirizzo reale appena la risposta API arriva (~200ms).

## Verification Plan

### Manual Verification
1. Avviare l'app su un dispositivo/emulatore
2. Toccare un punto qualsiasi sulla mappa
3. Verificare che nella barra di ricerca compaia un indirizzo leggibile (es. "Via Roma 15, Milano") e non le coordinate numeriche
