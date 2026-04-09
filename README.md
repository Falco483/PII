**Guida alla Clonazione e Build dell'App su cellulare Android Fisico**

Prerequisiti necessari
Un PC con AndroidStudio installato.
Un telefono fisico e un cavo per collegarlo al PC.

Attivare modalità sviluppatore sul telefono
Collegare al PC
Selezionare il proprio dispositivo da menu a tendina in alto
Eseguire il codice

1. Clonare la Repository da GitHub
Apri AndroidStudio.
Nella schermata di benvenuto, clicca su Clone an existing project (in alternativa, dal menu in alto vai su File > New > Clone).
Incolla l'URL della repository GitHub nel campo di ricerca e clicca su Clone.
Seleziona la cartella sul tuo PC in cui vuoi salvare il progetto e conferma. Xcode scaricherà il codice e aprirà il progetto.


**Guida alla Clonazione e Build dell'App su iPhone Fisico**
Prerequisiti necessari
Un Mac con Xcode installato (scaricabile gratuitamente dal Mac App Store).
Un Apple ID (anche un account gratuito va bene).
Un iPhone fisico e un cavo per collegarlo al Mac.

1. Clonare la Repository da GitHub
Apri Xcode.
Nella schermata di benvenuto, clicca su Clone an existing project (in alternativa, dal menu in alto vai su File > New > Clone).
Incolla l'URL della repository GitHub nel campo di ricerca e clicca su Clone.
Seleziona la cartella sul tuo Mac in cui vuoi salvare il progetto e conferma. Xcode scaricherà il codice e aprirà il progetto.

2. Configurare l'Account Sviluppatore (Signing)
Per installare un'app su un dispositivo fisico, Apple richiede di firmare il codice (Code Signing).
Nella barra dei menu di Xcode, vai su Xcode > Settings (o Preferences nelle versioni più vecchie) e seleziona la tab Accounts.
Clicca sul tasto + in basso a sinistra, seleziona Apple ID e fai l'accesso con il tuo account Apple.
Chiudi le impostazioni. Nel pannello di sinistra di Xcode (Project Navigator), clicca sul file principale del progetto (l'icona blu in cima).
Nella schermata centrale, seleziona il Target dell'app e vai nella tab Signing & Capabilities.
Spunta la casella Automatically manage signing.
Nel menu a tendina Team, seleziona il tuo nome (es. Nome Cognome (Personal Team)).
Nel campo Bundle Identifier, aggiungi una parola o dei numeri alla fine della stringa per renderla unica a livello globale (es. com.tuonome.nomeapp.docente).

3. Preparare l'iPhone
Collega l'iPhone al Mac tramite il cavo.
Sblocca l'iPhone. Se appare un avviso, tocca Autorizza questo computer e inserisci il codice di sblocco.
(Solo per iOS 16 e successivi): Vai su Impostazioni > Privacy e sicurezza > Modalità sviluppatore. Attiva l'interruttore e riavvia l'iPhone quando richiesto. Dopo il riavvio, conferma l'attivazione inserendo il codice.

4. Compilare ed Eseguire (Build & Run)
Torna su Xcode. Nella barra superiore, clicca sul nome del dispositivo (di solito mostra un iPhone simulato, es. iPhone 15 Pro).
Dal menu a tendina, scorri verso l'alto fino alla sezione iOS Devices e seleziona il tuo iPhone fisico.
Clicca sul pulsante Play (▶) in alto a sinistra, oppure usa la scorciatoia da tastiera Cmd + R.
Attendi che Xcode compili il codice. Al termine, apparirà la scritta Build Succeeded.

5. Autorizzare l'App sull'iPhone (Solo al primo avvio)
L'app verrà installata sull'iPhone, ma aprendola potresti ricevere un avviso di "Sviluppatore non attendibile".
Sull'iPhone, vai in Impostazioni > Generali > VPN e gestione dispositivi.
Sotto la voce App sviluppatore, tocca il tuo Apple ID.
Tocca Autorizza [Tuo Apple ID] e conferma.

Torna alla schermata Home dell'iPhone: ora puoi aprire l'app e testarla.
