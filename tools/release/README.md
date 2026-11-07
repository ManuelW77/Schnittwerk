# Release

Schnittwerk wird als signiertes, notarisiertes DMG über GitHub Releases verteilt
(nicht über den App Store: GPL-3 und Sandbox passen nicht).

Grenzen: nur Apple silicon (arm64, weil die Homebrew-libusb nur arm64 ist) und macOS 26.

## Einmalig einrichten

1. **Zertifikat** „Developer ID Application: Manuel Weiser (LWWM5RV3D9)“ im Schlüsselbund
   (ist vorhanden). Prüfen:

   ```bash
   security find-identity -v -p codesigning
   ```

2. **App-spezifisches Passwort** für die Notarisierung anlegen: account.apple.com →
   Anmeldung und Sicherheit → App-spezifische Passwörter.

3. **Notarisierungs-Profil** im Schlüsselbund speichern (fragt nach Apple-ID und dem
   Passwort aus Schritt 2; es landet nur im Schlüsselbund, nie im Skript):

   ```bash
   xcrun notarytool store-credentials schnittwerk-notary --apple-id DEINE_APPLE_ID --team-id LWWM5RV3D9
   ```

4. **GitHub CLI** angemeldet: `gh auth status`

## Neue Version veröffentlichen

1. `MARKETING_VERSION` in `project.yml` erhöhen (z. B. `0.2.0`), committen, nach `main` mergen, pushen.
2. Auf `main`:

   ```bash
   tools/release/release.sh
   ```

   Das Skript baut, prüft die Signatur (Developer ID, Hardened Runtime, Zeitstempel),
   erstellt `build/release/Schnittwerk-<Version>.dmg`, signiert es, notarisiert es
   (dauert meist 1–5 Minuten), heftet das Ticket an (`stapler`) und legt das
   GitHub-Release `v<Version>` mit dem DMG und einer Änderungsliste an.

Weitere Aufrufe:

| Aufruf | Wirkung |
|---|---|
| `tools/release/release.sh --dry-run` | nur bauen, signieren, DMG – keine Notarisierung, kein Upload |
| `tools/release/release.sh --no-upload` | notarisieren, aber nicht veröffentlichen |

Das Skript bricht ab, wenn es ungespeicherte Änderungen gibt, der Commit nicht
gepusht ist oder das Release schon existiert.

## Wenn die Notarisierung scheitert

Das Skript legt das Protokoll von Apple unter `build/release/notary-log.json` ab.
Häufige Ursachen: Hardened Runtime aus, fehlender Zeitstempel, unsignierte Teile im Bundle.

## Später

- Gleiches Skript in GitHub Actions, ausgelöst durch einen Tag (vorher prüfen, ob es
  macOS-26-Runner mit passendem Xcode gibt; libusb per `brew install libusb`).
- Updates mit Sparkle, optional ein Homebrew-Cask.
