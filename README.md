# AGFEO Presence Bridge

Verbindet den eigenen Teams-Status mit der AGFEO-Telefonanlage — in beide
Richtungen.

Telefonierst du in Teams, schaltet das Firmentelefon automatisch auf ein
anderes Rufprofil und leitet um; legst du auf, geht es zurück. Und telefonierst
du am Festnetz, steht dein Teams-Status auf „Beschäftigt“, damit dich niemand
parallel dort anruft.

Läuft als Menüleisten- beziehungsweise Infobereich-Programm für **macOS** und
**Windows**. Die Präsenzdaten bleiben auf dem Rechner; gesendet wird nur an
Microsoft Graph und an das lokale AGFEO Dashboard.

## Herunterladen

Die fertigen Programme liegen bei den
[Releases](https://github.com/papsbear354/AgfeoPresenceBridge/releases):

| | Datei | Hinweis |
|---|---|---|
| macOS 13+ | `…​.dmg` | signiert und notariell beglaubigt, startet ohne Warnung |
| Windows 10/11 | `…​-win-x64.exe` | bringt alles mit, keine .NET-Installation nötig |

Die Windows-Datei ist nicht signiert — beim ersten Start erscheint eine
SmartScreen-Warnung; unter *Weitere Informationen* steht *Trotzdem ausführen*.

## Was das Programm tut

### Regelwerk

Eine geordnete Liste, **die erste zutreffende Regel gewinnt**. Trifft keine, gilt
das Grundprofil.

| Auslöser | Beispiel |
|---|---|
| Teams-Activity | `InACall`, `InAConferenceCall`, `Presenting` → Profil „Meeting“ |
| Nicht am Platz | Bildschirm gesperrt, keine Eingabe, Ruhezustand → Profil „Abwesend“ |

Dass beide Arten in derselben Liste stehen, erspart eine versteckte Rangfolge:
Steht „Im Gespräch“ oben, bleibt es beim Gesprächsprofil, auch wenn der
Bildschirm sperrt. Umsortieren dreht das um.

Die Abwesenheit wird **lokal** erkannt, ohne Teams und ohne Netz — Teams meldet
`Away` erst nach Minuten und gar nicht, wenn der Status von Hand festgehalten
wird.

### Weitere Funktionen

- **Arbeitszeit** — außerhalb wird nichts abgefragt, nichts erkannt und nichts
  geschaltet. Zum Feierabend geht das Rufprofil einmal zurück, danach ist Ruhe.
- **Befristetes Schalten** — „Abwesend für 30 Minuten“; danach übernimmt die
  Automatik von selbst wieder.
- **Tastenkurzbefehl** (macOS) — schaltet auf ein festes Profil und hält es.
- **Verlauf** — die letzten fünf Schaltvorgänge mit Uhrzeit und Grund.
- **Rückmeldung der Anlage** — optional über die kostenpflichtige Funktion
  *AGFEO Klick*; erst damit kann ein Festnetzgespräch den Teams-Status setzen.

## Einrichtung

Beim ersten Start führt eine Anleitung im Programm durch die Schritte. In Kürze:

1. **Anwendung in Microsoft Entra registrieren** — Single Tenant, Plattform
   „Mobile Geräte- und Desktopanwendungen“, öffentliche Clientflows erlauben.
   Umleitungs-URI: `de.baz.agfeopresence://auth` (macOS) beziehungsweise
   `http://localhost` (Windows). Beide dürfen nebeneinanderstehen.
2. **Berechtigungen** (delegiert, mit Administratorzustimmung):
   `Presence.Read` zwingend, `User.Read` für die Namensanzeige,
   `Presence.ReadWrite` nur für die Rückmeldung an Teams.
3. **Tenant- und Client-ID eintragen** und anmelden.
4. **Rufprofile eintragen** — exakt wie in der Anlage geschrieben — und mit
   „Testen“ prüfen.

## Zwei Eigenheiten, die man kennen muss

**Der AGFEO-Handler ist eine Einbahnstraße.**
`adashboard:activate_call_profile` liefert keine Bestätigung, und weder das
aktive Profil noch die Liste der vorhandenen lässt sich auslesen. Deshalb sind
Profilnamen Freitext, jedes Feld hat einen Testen-Knopf, und die Oberfläche sagt
immer „zuletzt gesendet“, nie „aktiv“. Startet das Dashboard neu, sendet das
Programm seinen Stand vorsichtshalber erneut.

**Bei unbekanntem Status wird nicht geschaltet.**
Ein Netzausfall ist keine Aussage über den Gesprächszustand. Bleibt der Status
länger als das Blind-Timeout unbekannt und steht ein Regelprofil, fällt das
Programm einmalig auf das Grundprofil zurück — sonst bliebe das Telefon
umgeleitet, weil das WLAN weg war. Dasselbe gilt beim Ruhezustand und beim
Beenden: Was das Programm verstellt hat, nimmt es vorher zurück.

## Aufbau

Zwei Fassungen mit gemeinsamem Verhalten, aber getrenntem Code:

```
Sources/            macOS: Swift 6, SwiftUI, AppKit
├── App/            Oberfläche und Systemanbindung
├── Core/           Auth, Präsenz, Regeln, Zustandsautomat — ohne SwiftUI
└── Support/        Logging
Tests/              111 Tests

windows/            Windows: .NET 10, WinForms
├── src/…​.Core/     dieselbe Fachlogik, plattformneutral
├── src/…​.Windows/  Infobereich, Einstellungen, Systemanbindung
└── tests/          60 Tests
```

`Core` importiert in beiden Fassungen bewusst nichts von der Oberfläche und ist
ohne Netz und ohne Fenster testbar. Dort liegen `ProfileController` und
`RuleEngine` — die Stellen, an denen Fehler im Betrieb wehtun, und deshalb die
mit der dichtesten Testabdeckung.

Das Format von `Settings.json` ist auf beiden Systemen identisch; eine auf dem
Mac eingerichtete Datei liest die Windows-Fassung unverändert.

## Selbst bauen

```bash
# macOS
brew install xcodegen
xcodegen generate
xcodebuild -project AGFEOPresenceBridge.xcodeproj -scheme AGFEOPresenceBridge test

# Windows-Fassung (Kern und Tests laufen auf jedem System)
cd windows && dotnet test
```

Das Xcode-Projekt wird aus `project.yml` erzeugt und liegt nicht im Repo. Ein
Tag der Form `v*` baut über GitHub Actions beide Fassungen und hängt sie an ein
Release — für macOS signiert und notarisiert, siehe
[docs/Auslieferung.md](docs/Auslieferung.md).

## Wo etwas liegt

| | macOS | Windows |
|---|---|---|
| Einstellungen | `~/Library/Application Support/de.baz.agfeopresence/` | `%APPDATA%\de.baz.agfeopresence\` |
| Protokoll | `~/Library/Logs/AGFEOPresenceBridge/` | `%LOCALAPPDATA%\AGFEOPresenceBridge\Logs\` |
| Aktualisierungstoken | Keychain | verschlüsselt im Benutzerprofil (DPAPI) |

Das Zugriffstoken wird nirgends abgelegt, es lebt nur im Arbeitsspeicher. Im
Protokoll stehen Statuswechsel, gesendete Profilbefehle mit Grund und Fehler —
niemals Tokens.
