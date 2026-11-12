English version: [SETUP.md](SETUP.md)

# SIP Phone: Einrichtungsanleitung

Diese Anleitung richtet sich an FRITZ!Box-Besitzer, die SIP Phone auf einem Mac nutzen möchten. Sie müssen kein Entwickler sein, um ihr zu folgen.

Hinweis: Die Oberfläche der App ist englisch (sie ist nicht lokalisiert). Beschriftungen, Statusmeldungen und Meldungen der App stehen deshalb in dieser Anleitung auf Englisch und werden bei Bedarf auf Deutsch erklärt.

## 1. Was die App kann und was Sie brauchen

SIP Phone ist ein kleines Telefon für Ihren Mac, das in der Menüleiste lebt. Es meldet sich als IP-Telefon an Ihrer FRITZ!Box an. Sie können Anrufe tätigen und annehmen, sehen, wer anruft (mit Namen aus den Telefonbüchern Ihrer FRITZ!Box), und Ihre Anrufliste durchsehen.

Sie benötigen:

- Einen Mac mit macOS 14 oder neuer (Apple Silicon oder Intel).
- Eine FRITZ!Box mit einem IP-Telefon, im selben Netzwerk wie der Mac.
- Optional: eine WireGuard-Verbindung in der FRITZ!Box, wenn Sie das Telefon unterwegs nutzen möchten (siehe Abschnitt 7).

## 2. Die App beschaffen

Laden Sie die `.dmg`-Datei von der [Releases-Seite](https://github.com/AarneAarebye/sip-phone/releases) herunter (mit Developer ID signiert und von Apple notarisiert, macOS öffnet sie ohne Warnung), öffnen Sie sie und ziehen Sie SIP Phone in den Ordner „Programme“. Der Bau aus dem Quellcode ist ebenfalls möglich: siehe Abschnitt „Build“ in der [README](../README.md).

Sobald Sie `SipPhone.app` haben:

1. Verschieben Sie sie in den Ordner `/Applications` (Programme). Das ist für die VPN-Erweiterung erforderlich (siehe Abschnitt 7).
2. Öffnen Sie sie. Es gibt kein Dock-Symbol und kein Fenster. Suchen Sie das Telefonsymbol in der Menüleiste oben rechts auf dem Bildschirm.
3. Wenn Sie das Symbol nicht sehen, ist es möglicherweise verdeckt. Auf Macs mit Notch oder mit einem Menüleisten-Manager können Symbole hinter der Notch oder im Überlaufbereich des Managers landen. Halten Sie die Befehlstaste (⌘) gedrückt und ziehen Sie andere Symbole weg, um Platz zu schaffen, oder öffnen Sie den Überlaufbereich Ihres Menüleisten-Managers.

Klicken Sie auf das Symbol, um das Popover zu öffnen. Es zeigt eine Statuszeile, drei Tabs (Contacts, History, Keypad) und die Schaltflächen „Settings…“ und „Quit“.

## 3. Die FRITZ!Box vorbereiten

Öffnen Sie die Benutzeroberfläche der FRITZ!Box (meist `http://fritz.box`) und melden Sie sich an. Die Menünamen der FRITZ!Box sind hier auf Deutsch angegeben, englische Entsprechungen stehen bei Bedarf in Klammern. Die genauen Menünamen hängen von der FRITZ!OS-Version ab; diese Schritte wurden mit FRITZ!OS 8.25 geschrieben, bei Ihnen kann es anders aussehen.

### 3a. Ein IP-Telefon einrichten

1. Gehen Sie zu Telefonie > Telefoniegeräte (Telephony > Telephony Devices).
2. Klicken Sie auf Neues Gerät einrichten (Set up new device).
3. Wählen Sie Telefon (mit und ohne Anrufbeantworter), dann LAN/WLAN (IP-Telefon).
4. Wählen Sie einen Namen für das Telefon, zum Beispiel „Mac“.
5. Notieren Sie auf der Registerkarte Anmeldedaten (Login data) den von der FRITZ!Box erzeugten Benutzernamen und legen Sie das Kennwort fest oder notieren Sie es. Beides tragen Sie in der App als Anmeldung der „Phone extension“ ein.
6. Legen Sie fest, welche Ihrer Rufnummern an diesem Telefon klingeln soll und welche Nummer es für ausgehende Anrufe verwendet. Die ausgehende Rufnummer wird hier eingestellt, nicht in der App.
7. Schließen Sie den Assistenten ab und übernehmen Sie die Änderungen.

### 3b. Einen FRITZ!Box-Benutzer für Telefonbuch und Anrufliste anlegen

Die App liest Ihre Telefonbücher und die Anrufliste über eine andere Anmeldung als das Telefon.

1. Gehen Sie zu System > FRITZ!Box-Benutzer (System > FRITZ!Box Users) und legen Sie einen Benutzer mit Kennwort an.
2. Geben Sie dem Benutzer die Berechtigungen für FRITZ!Box Einstellungen sowie für Sprachnachrichten, Faxnachrichten, FRITZ!App Fon und Anrufliste.

Dies sind die Berechtigungen nach bestem Wissen. Wenn die App später meldet, die FRITZ!Box habe Benutzername oder Kennwort „rejected“ (abgelehnt), obwohl beides korrekt ist, lesen Sie Abschnitt 8 und versuchen Sie, Berechtigungen hinzuzufügen oder zu entfernen.

### 3c. Zugriff für Anwendungen erlauben (TR-064)

Stellen Sie sicher, dass die FRITZ!Box den Zugriff für Anwendungen erlaubt. Der Menüpfad kann abweichen: Meist finden Sie die Option unter Heimnetz > Netzwerk > Netzwerkeinstellungen > Heimnetzfreigaben (Home Network > Network > Network Settings > Home Network Sharing) als „Zugriff für Anwendungen zulassen“ (Allow access for applications).

## 4. Erster Start und Einstellungen

Klicken Sie auf das Menüleistensymbol, dann auf „Settings…“. Füllen Sie die folgenden Felder aus und klicken Sie dann auf „Save“.

| Feld in den Settings | Was Sie eintragen |
|---|---|
| **Address** | `fritz.box` oder die IP-Adresse Ihrer FRITZ!Box. |
| **Phone extension user (SIP)** | Der Benutzername des IP-Telefons aus Schritt 3a. |
| **SIP password (leave empty to keep)** | Das Kennwort des IP-Telefons aus Schritt 3a. Leer lassen, um das gespeicherte Kennwort zu behalten. |
| **FRITZ!Box user (TR-064)** | Der FRITZ!Box-Benutzer aus Schritt 3b. |
| **TR-064 password (leave empty to keep)** | Das Kennwort dieses Benutzers. Leer lassen, um das gespeicherte Kennwort zu behalten. |
| **Country code** | Ihre Landesvorwahl ohne `+` oder `00`. Standard ist `49` (Deutschland). |
| **Local area code (e.g. 030)** | Ihre Ortsvorwahl, damit auch Nummern ohne Vorwahl funktionieren. |
| **Keep Mac awake while on power** | Standardmäßig an. Verhindert den Ruhezustand des Macs im Netzbetrieb, damit er klingeln kann. |
| **Launch at login** | Startet die App bei der Anmeldung. macOS bittet Sie möglicherweise, das in den Systemeinstellungen unter Allgemein > Anmeldeobjekte & Erweiterungen zu bestätigen (System Settings > General > Login Items; Bezeichnungen können je nach macOS-Version abweichen). |
| **Phone books** | Ein Schalter pro FRITZ!Box-Telefonbuch, standardmäßig alle an; neue Telefonbücher starten eingeschaltet. Ein ausgeschaltetes Telefonbuch ist unter Contacts ausgeblendet und wird nicht für die Anzeige von Anrufernamen verwendet. Wird mit Save übernommen. Die in History angezeigten Namen stammen aus der Anrufliste der FRITZ!Box selbst; das Ausschalten eines Telefonbuchs in der App ändert sie daher nicht. Zeigt „Not loaded yet“, bis zum ersten erfolgreichen Laden. |
| **VPN (WireGuard)** | Nur für die Nutzung unterwegs, siehe Abschnitt 7. Lassen Sie „Only send home-network traffic through the VPN (recommended)“ eingeschaltet und „Home network (CIDR)“ leer, außer Ihr Heimnetz ist nicht das `/24`-Netz der WireGuard-Address. |
| **Keypad tone method** (Diagnostics) | Auf „In-band audio tones (recommended)“ belassen. |

Der Bereich „Diagnostics“ enthält außerdem:

- **Test TR-064 login**: prüft den gespeicherten FRITZ!Box-Benutzer samt Kennwort und zeigt ein Ergebnis an. Es enthält weder Benutzername noch Kennwort und kann daher gefahrlos kopiert und weitergegeben werden.
- **Forget pinned certificate**: siehe Abschnitt 8. Der Bereich „Certificate“ zeigt, ob ein Zertifikat festgesetzt (gepinnt) ist.

So werden Kennwörter behandelt:

- Kennwörter werden im macOS-Schlüsselbund (Keychain) gespeichert, nie in einer einfachen Datei.
- Nach dem Speichern zeigt ein Kennwortfeld „Stored in Keychain“ mit einem Häkchen daneben.
- Bleibt ein Kennwortfeld leer, bleibt das gespeicherte Kennwort erhalten. Geben Sie nur dann ein neues ein, wenn Sie es ändern möchten.

„Save“ speichert alles, verbindet neu und schließt bei Erfolg das Settings-Fenster. Geht etwas schief, bleibt das Fenster offen und zeigt eine rote Meldung.

Ein gesunder Start sieht so aus: Das Popover zeigt einen grünen Punkt mit „Connected“, und die Tabs Contacts und History füllen sich mit Ihren Telefonbucheinträgen und Anrufen.

## 5. Berechtigungen, nach denen macOS fragt

Die Bezeichnungen der Systemeinstellungen können je nach macOS-Version abweichen.

| Berechtigung | Wofür | Wenn Sie ablehnen |
|---|---|---|
| **Microphone** (Mikrofon) | Anrufe führen und annehmen. Wird beim ersten Anruf abgefragt. | Anrufe starten nicht. Das Popover oder das Anruffenster zeigt „Microphone access needed“ und bietet „Open System Settings“ an. Erlauben Sie SIP Phone unter Systemeinstellungen > Datenschutz & Sicherheit > Mikrofon (System Settings > Privacy & Security > Microphone) und versuchen Sie es erneut. |
| **Notifications** (Mitteilungen) | Banner für eingehende Anrufe, mit „Answer“ und „Decline“. | Sie sehen kein Banner, aber das schwebende Anruffenster erscheint trotzdem. |
| **Local network** (Lokales Netzwerk) | macOS fragt eventuell danach, weil die App mit Ihrer FRITZ!Box kommuniziert (kann je nach macOS-Version abweichen). | Erlauben Sie es unter Systemeinstellungen > Datenschutz & Sicherheit > Lokales Netzwerk (System Settings > Privacy & Security > Local Network), falls die FRITZ!Box nicht erreichbar ist. |

Für Mitteilungen öffnen Sie Systemeinstellungen > Mitteilungen > SIP Phone und stellen Vorschau anzeigen auf Immer (System Settings > Notifications > SIP Phone > Show Previews: Always). Sind Vorschauen ausgeblendet, zeigt das Banner weiterhin den Anrufer und „Incoming call“, ist aber weniger aussagekräftig.

## 6. Die App benutzen

**Wählen über den Tab Keypad.** Geben Sie eine Nummer ein oder tippen Sie sie an und klicken Sie auf „Call“. Für internationale Nummern halten Sie die Taste 0 lange gedrückt oder klicken auf die Schaltfläche +, um ein führendes + einzugeben. Beides funktioniert nur als erstes Zeichen.

**Wählen über Contacts.** Das Suchfeld findet Namen, Nummern und Telefonbuchnamen. Jeder Kontakt zeigt, aus welchem Telefonbuch er stammt. Sind zwei oder mehr Telefonbücher eingeschaltet, schränkt ein Menü neben dem Suchfeld („All phone books“ oder ein einzelnes Telefonbuch) die Liste ein; es wirkt zusammen mit der Suche. Klicken Sie auf eine Nummer, um sie anzurufen. Sie können auch eine Nummer ins Suchfeld eingeben und die Eingabetaste drücken, wenn nichts gefunden wird.

**Wählen über History.** Klicken Sie bei einem beliebigen Eintrag auf die Telefonschaltfläche.

**Während eines Anrufs** zeigt ein Anruffenster den Namen und einen Zeitzähler. Dort stehen zur Verfügung:

- **Mute / Unmute**, um Ihr Mikrofon stummzuschalten.
- **Keypad**, um Töne zu senden, zum Beispiel für Menüs einer Hotline. Eine kurze Einblendung bestätigt jeden Tastendruck.
- **Hang up**, um den Anruf zu beenden.

**Eingehende Anrufe** zeigen ein schwebendes Fenster und eine Mitteilung, jeweils mit „Answer“ und „Decline“. Hat Ihre FRITZ!Box mehrere Rufnummern, sagt die Zeile „Incoming call on <number>“, welche Ihrer Nummern angerufen wurde. Das ist nur nach bestem Bemühen möglich: Es hängt davon ab, was die FRITZ!Box sendet.

Wenn ein Anruf endet, zeigt das Anruffenster eine dieser Meldungen:

| Meldung | Bedeutung |
|---|---|
| Call ended | Sie haben ein verbundenes Gespräch beendet. |
| Call ended by the other party | Die Gegenseite hat aufgelegt. |
| Call declined | Sie haben einen eingehenden Anruf abgelehnt. |
| Missed call | Der Anrufer hat aufgegeben, bevor Sie abgenommen haben. |
| Call cancelled | Sie haben Ihren eigenen Anruf abgebrochen, während es klingelte. |
| Declined by the other party | Die angerufene Person hat den Anruf abgelehnt. |
| Busy | Die Leitung ist besetzt. |
| Not available | Die Nummer war nicht erreichbar. |
| No answer | Niemand hat rechtzeitig abgenommen. |
| Call failed: <code> | Etwas anderes ist schiefgegangen. Wird rot angezeigt. Nur dieser Fall wird als Fehler behandelt. |

## 7. Unterwegs (WireGuard) — experimentell

**Experimentell: Die VPN-Erweiterung wurde noch nicht auf einem echten System getestet.** Alles zu Hause funktioniert auch ohne sie. Betrachten Sie diesen Abschnitt als Vorschau.

Um das Telefon unterwegs zu nutzen, verbindet sich die App über ein WireGuard-VPN mit Ihrer FRITZ!Box.

1. Legen Sie in der FRITZ!Box eine WireGuard-Verbindung für diesen Mac an: Internet > Freigaben > VPN (WireGuard) (Internet > Permit Access > VPN (WireGuard)). Der Pfad kann abweichen.
2. Exportieren Sie die Verbindung als `.conf`-Datei.
3. Öffnen Sie die Datei in einem Texteditor, kopieren Sie den gesamten Inhalt und fügen Sie ihn in den Settings unter „VPN (WireGuard)“ ein. Klicken Sie auf „Save“. Die Konfiguration wird im Schlüsselbund gespeichert.
4. Die App muss sich in `/Applications` befinden. Wenn das VPN zum ersten Mal gebraucht wird, blockiert macOS die Netzwerkerweiterung, bis Sie sie in den Systemeinstellungen unter Allgemein > Anmeldeobjekte & Erweiterungen > Netzwerkerweiterungen genehmigen (System Settings > General > Login Items & Extensions > Network Extensions; Bezeichnungen können je nach macOS-Version abweichen). Möglicherweise werden Sie auch gebeten, eine VPN-Konfiguration zu erlauben.

Die App startet und beendet das VPN selbst:

- **Unterwegs**: Ist Ihre FRITZ!Box nicht erreichbar, startet die App das VPN.
- **Wieder zu Hause**: Antwortet die FRITZ!Box direkt über WLAN oder Ethernet (nicht über das VPN), beendet die App das VPN, meist innerhalb von etwa 10 Sekunden und zeigt „VPN off – you are home“. Sie prüft zweimal im Abstand von 3 Sekunden, damit ein kurzer WLAN-Wechsel das VPN nicht beendet. Während eines Gesprächs beendet sie das VPN nie; sie wartet, bis Sie auflegen.
- **Beenden**: Wenn Sie die App beenden, wird auch das VPN beendet.

Mit „Only send home-network traffic through the VPN (recommended)“ (voreingestellt) läuft nur der Verkehr für Ihr Heimnetz durch das VPN, zum Beispiel `192.168.65.0/24`. Alles andere (Web, E-Mail, Updates) nutzt weiter Ihre normale Verbindung, und Abfragen für `fritz.box` gehen an die FRITZ!Box. Als Heimnetz gilt das `/24`-Netz der WireGuard-`Address`. Ist Ihr Heimnetz ein anderes, tragen Sie es unter „Home network (CIDR)“ ein, zum Beispiel `192.168.65.0/24`. Änderungen gelten ab dem nächsten Start des VPN. Ist der Schalter aus, nutzt das VPN die Routen aus der `.conf`-Datei (`AllowedIPs = 0.0.0.0/0` leitet den gesamten Verkehr über Ihr Zuhause).

Der VPN-Eintrag „FRITZ!Box“ in den Systemeinstellungen unter VPN lässt sich nicht von Hand starten: Er meldet „Start the VPN from SIP Phone“. Das ist so gewollt. Die Konfiguration bleibt im Schlüsselbund der App, und die App startet das VPN bei Bedarf.

Einschränkungen:

- Der Mac klingelt nur, solange er wach ist. Mit eingeschaltetem „Keep Mac awake while on power“ bleibt er im Netzbetrieb wach. Im Akkubetrieb kann er in den Ruhezustand gehen.
- Es gibt keine Push-Weckrufe. Anrufe, die Sie während des Ruhezustands verpasst haben, erscheinen in „History“, sobald der Mac wieder wach ist.

## 8. Fehlerbehebung

| Was Sie sehen | Was zu tun ist |
|---|---|
| Rot: „Login rejected – check Settings“ | Die SIP-Anmeldung ist falsch. Vergleichen Sie „Phone extension user (SIP)“ und das SIP-Kennwort mit der Registerkarte Anmeldedaten des IP-Telefons (Schritt 3a). Geben Sie das Kennwort neu ein und klicken Sie auf „Save“. |
| Orange: „Connecting…“, das nicht verschwindet | Prüfen Sie, ob der Mac im selben Netzwerk wie die FRITZ!Box ist und ob die „Address“ stimmt. Klicken Sie auf „Retry“, falls angeboten. Unterwegs siehe Abschnitt 7. |
| Rot: „Offline: …“ | Lesen Sie den angezeigten Grund. Klicken Sie auf „Retry“, sobald die Ursache behoben ist. |
| „Phone book unavailable (The FRITZ!Box rejected the TR-064 user name or password)“ | Prüfen Sie FRITZ!Box-Benutzer und Kennwort, öffnen Sie dann Settings > Diagnostics > „Test TR-064 login“ und lesen Sie das Ergebnis. Ist die Anmeldung korrekt, prüfen Sie, ob der Zugriff für Anwendungen eingeschaltet ist (3c), und versuchen Sie, die Berechtigungen des Benutzers anzupassen (3b). Bis dahin zeigt die App Ihre gespeicherten Kontakte. |
| „The FRITZ!Box certificate changed…“ | Sie haben die Box ersetzt oder zurückgesetzt. Öffnen Sie die Settings und klicken Sie auf „Forget pinned certificate“. Tun Sie das nur, wenn Sie wissen, dass die Box ausgetauscht wurde. |
| Kein Ton oder Ton nur in eine Richtung | Prüfen Sie die Mikrofonberechtigung (Abschnitt 5). Stellen Sie sicher, dass nur ein Softphone mit diesem IP-Telefon angemeldet ist. Nutzen zwei Apps dasselbe IP-Telefon-Konto, klingeln beide und konkurrieren um den Anruf. |
| Tastentöne sind nicht zu hören | Probieren Sie in Settings > Diagnostics eine andere „Keypad tone method“, klicken Sie auf „Save“ und testen Sie erneut. „In-band audio“ ist die Voreinstellung und wird empfohlen. |
| Das Banner zeigt nur „Notification“ | Stellen Sie für SIP Phone in den Systemeinstellungen unter Mitteilungen „Vorschau anzeigen“ auf „Immer“ (Show Previews: Always). |
| Das Settings-Fenster erscheint nicht | Das Menüleistensymbol ist möglicherweise verdeckt (siehe Abschnitt 2). |
| Die App ist nicht in der Menüleiste | Sie ist möglicherweise hinter der Notch oder im Überlaufbereich Ihres Menüleisten-Managers versteckt. Schauen Sie dort nach, oder beenden Sie die App und starten Sie sie neu. |
| „Start the VPN from SIP Phone“ in den Systemeinstellungen unter VPN | So gewollt: Nur die App kann das VPN starten. Lassen Sie es aus; die App startet es, wenn Sie unterwegs sind (Abschnitt 7). |

## 9. Datenschutz und Sicherheit

- Kennwörter und die WireGuard-Konfiguration werden ausschließlich im macOS-Schlüsselbund gespeichert.
- Das Zertifikat der FRITZ!Box wird bei der ersten Verwendung festgesetzt (gepinnt). Ändert es sich später, verweigert die App die Verbindung, bis Sie „Forget pinned certificate“ wählen.
- Der Kontakt-Cache ist eine einfache JSON-Datei im Container der App auf Ihrem Mac. Sie ist nicht verschlüsselt.
- Die App sendet nichts an andere Server als Ihre FRITZ!Box (und die WireGuard-Gegenstelle, falls Sie das VPN nutzen).
- SIP Phone ist freie Software unter der GNU General Public License v3.0 oder später. Den Quellcode finden Sie unter https://github.com/AarneAarebye/sip-phone; über „About SIP Phone…“ im Menüleisten-Fenster oder in den Einstellungen sehen Sie die Version, den GitHub-Link und die Lizenzen der verwendeten Open-Source-Komponenten.

## 10. Hilfe und Fehlerberichte

Für Fragen, Fehler und Funktionswünsche nutzen Sie das Projekt-Repository auf GitHub: https://github.com/AarneAarebye/sip-phone (dort können Sie ein Issue anlegen). Entwicklerdetails finden Sie in der [README](../README.md) und in [docs/MANUAL_TEST.md](MANUAL_TEST.md).
