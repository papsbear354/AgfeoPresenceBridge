# Auslieferung

Wie aus einem Versions-Tag eine Datei wird, die man weitergeben kann.

## Lokal bauen

```bash
Scripts/build-release.sh 1.7.0
```

Erzeugt `build/AGFEOPresenceBridge-1.7.0.dmg`. Ohne gesetzte Signatur-Angaben
entsteht ein **unsigniertes** Bündel: Es läuft auf dem eigenen Rechner, wird auf
fremden Rechnern aber von Gatekeeper angehalten. Für die Weitergabe fehlen dann
noch die beiden folgenden Schritte.

## Einmalige Einrichtung für die Weitergabe

### 1. Developer-ID-Zertifikat

Das vorhandene **Apple-Development**-Zertifikat reicht nicht — es ist zum
Entwickeln gedacht, nicht zum Verteilen. Gebraucht wird **Developer ID
Application**:

1. <https://developer.apple.com/account/resources/certificates> → **+**
2. Art: *Developer ID Application*
3. Zertifikatsanforderung aus der Schlüsselbundverwaltung hochladen
   (*Schlüsselbundverwaltung → Zertifikatsassistent → Zertifikat einer
   Zertifizierungsinstanz anfordern*)
4. Fertiges Zertifikat laden und per Doppelklick in den Schlüsselbund legen

Danach prüfen:

```bash
security find-identity -v -p codesigning | grep "Developer ID"
```

### 2. Zugang für die Notarisierung

Apple prüft jede ausgelieferte App automatisiert. Dafür braucht es ein
**app-spezifisches Passwort** (nicht das Apple-ID-Passwort):

1. <https://account.apple.com> → Anmeldung und Sicherheit → App-spezifische
   Passwörter
2. Lokal hinterlegen:

```bash
xcrun notarytool store-credentials release \
  --apple-id "deine@apple-id.de" \
  --team-id "ZHH543APHL" \
  --password "abcd-efgh-ijkl-mnop"
```

### 3. Signiert bauen

```bash
export SIGN_IDENTITY="Developer ID Application: Dein Name (ZHH543APHL)"
export NOTARY_PROFILE="release"
Scripts/build-release.sh 1.7.0
```

Die Notarisierung dauert meist ein bis fünf Minuten. Danach ist das Ergebnis an
die App geheftet (`stapler`), sodass sie auch ohne Internetverbindung als
geprüft gilt.

## Automatisch über GitHub

`.github/workflows/release.yml` macht dasselbe auf einem GitHub-Runner, sobald
ein Tag der Form `v*` geschoben wird, und hängt das DMG an das Release.

Dafür müssen unter *Settings → Secrets and variables → Actions* hinterlegt sein:

| Secret | Inhalt |
|---|---|
| `MACOS_CERTIFICATE` | Das Developer-ID-Zertifikat als `.p12`, base64-kodiert |
| `MACOS_CERTIFICATE_PASSWORD` | Passwort des `.p12` |
| `MACOS_SIGN_IDENTITY` | `Developer ID Application: Dein Name (TEAMID)` |
| `NOTARY_APPLE_ID` | Apple-ID |
| `NOTARY_TEAM_ID` | `ZHH543APHL` |
| `NOTARY_PASSWORD` | app-spezifisches Passwort |

Das `.p12` entsteht so: Schlüsselbundverwaltung → Zertifikat samt privatem
Schlüssel auswählen → *Exportieren*. Dann:

```bash
base64 -i Zertifikat.p12 | pbcopy
```

Fehlen die Secrets, baut der Workflow trotzdem — nur eben unsigniert. Ein Fork
ohne Zugänge scheitert dadurch nicht.

## Warum GitHub und nicht Bitbucket

Bitbucket Pipelines bietet keine macOS-Runner; dort lässt sich eine Mac-App
nicht bauen. GitHub Actions stellt macOS- und Windows-Runner bereit, für
öffentliche Repositories ohne Kosten. Für eine spätere Windows-Fassung ist
derselbe Weg damit schon gebahnt.
