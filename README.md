# AGFEO Presence Bridge

Menüleisten-App für macOS, die die eigene Teams-Präsenz per Microsoft Graph
liest und davon abhängig das Rufprofil in der AGFEO-Telefonanlage umschaltet.
Telefoniert man in Teams, leitet das Firmentelefon automatisch um; danach geht
es auf das Grundprofil zurück.

Die Präsenzdaten bleiben lokal und werden nirgendwohin gesendet.

## Bauen

Das Xcode-Projekt wird aus `project.yml` erzeugt und liegt nicht im Repo:

```bash
brew install xcodegen
xcodegen generate
xcodebuild -project AGFEOPresenceBridge.xcodeproj \
           -scheme AGFEOPresenceBridge -configuration Debug test
```

Voraussetzungen: macOS 13+, Xcode 16+, keine externen Paketabhängigkeiten.

## Aufbau

```
Sources/
├── App/      SwiftUI, AppKit, Lebenszyklus
├── Core/     Auth, Präsenz, Regeln, Zustandsautomat — ohne SwiftUI
└── Support/  Logging
```

`Core/` importiert bewusst kein SwiftUI und ist ohne Netz und ohne Oberfläche
testbar. `ProfileController` und `RuleEngine` sind das Herzstück; dort liegen
die Fehler, die im Betrieb wehtun, deshalb hängen die Unit-Tests vor allem
daran.

## Auslöser

Das Regelwerk ist eine geordnete Liste, erste Übereinstimmung gewinnt. Darin
stehen zwei Arten von Auslösern gleichberechtigt nebeneinander:

- **Teams-Activity** — `InACall`, `Presenting` und die übrigen Graph-Werte.
- **Nicht am Platz** — lokal erkannt aus Bildschirmsperre, fehlenden Eingaben
  und Ruhezustand. Ohne Teams, ohne Netz, ohne Berechtigung: die Leerlaufzeit
  kommt von `CGEventSource` und ist derselbe Wert, den `ioreg` unter
  `HIDIdleTime` führt.

Dass beide in derselben Liste stehen, erspart eine versteckte Rangfolge: Steht
„Im Gespräch“ oben, bleibt es beim Gesprächsprofil, auch wenn der Bildschirm
sperrt. Umsortieren dreht das um.

Der Ruhezustand schaltet auf das Abwesenheitsprofil — Deckel zu heißt weg vom
Platz. Beim Herunterfahren und Beenden bleibt es beim Grundprofil, weil die App
danach nichts mehr korrigieren kann.

## Zwei Eigenheiten, die man kennen muss

**Der AGFEO-Handler ist eine Einbahnstraße.** `adashboard:activate_call_profile`
liefert keine Bestätigung, und weder das aktive Profil noch die Liste der
vorhandenen Profile lassen sich auslesen. Deshalb sind Profilnamen Freitext,
jedes Feld hat einen Testen-Knopf, und die Oberfläche sagt immer „zuletzt
gesendet“, nie „aktiv“.

**Bei unbekanntem Status wird nicht geschaltet.** Ein Netzausfall ist keine
Aussage über den Gesprächszustand. Bleibt der Status länger als das
Blind-Timeout unbekannt und steht ein Regelprofil, fällt die App einmalig auf
das Grundprofil zurück — sonst bliebe das Telefon umgeleitet, weil das WLAN weg
war.

## Konfiguration

`~/Library/Application Support/de.baz.agfeopresence/Settings.json`, im Programm
über die Einstellungen bearbeitbar. Der Refresh Token liegt ausschließlich in
der Keychain, das Zugriffstoken nur im Arbeitsspeicher.

Log: `~/Library/Logs/AGFEOPresenceBridge/bridge.log` (rotierend, 5 × 1 MB).
