# Release

Schnittwerk wird als signiertes, notarisiertes DMG über GitHub Releases verteilt
(nicht über den App Store: GPL-3 und Sandbox passen nicht).

Grenzen: nur Apple silicon (arm64, weil die Homebrew-libusb nur arm64 ist) und macOS 26.

Normalerweise baut **GitHub Actions** das Release. Das lokale Skript bleibt als Ersatz
und zum Ausprobieren.

## Neue Version veröffentlichen (GitHub Actions)

1. `MARKETING_VERSION` in `project.yml` erhöhen (z. B. `0.2.0`), committen, nach `main` mergen, pushen.
2. Tag setzen und pushen – der Tag muss genau zur Version passen:

   ```bash
   git tag v0.2.0
   git push origin v0.2.0
   ```

3. Der Workflow **Release** (`.github/workflows/release.yml`) testet, baut, signiert,
   notarisiert und legt das GitHub-Release mit DMG und Änderungsliste an. Fortschritt unter
   *Actions* im Repository. Schlägt die Notarisierung fehl, liegen die Protokolle als
   Artefakt `release-logs` am Lauf.

Bei jedem Push auf `main`, `devel` und `feature/…` sowie bei Pull Requests laufen außerdem
die Tests (`.github/workflows/tests.yml`).

## Secrets für GitHub Actions (einmalig)

Unter *Settings → Secrets and variables → Actions* fünf Secrets anlegen
(oder mit `gh secret set`, siehe unten). Passwörter und Schlüssel nie ins Repository.

| Secret | Inhalt |
|---|---|
| `MACOS_CERTIFICATE_P12` | Zertifikat „Developer ID Application“ **mit privatem Schlüssel** als .p12, Base64 |
| `MACOS_CERTIFICATE_PASSWORD` | Passwort, das du beim Export der .p12 vergibst |
| `NOTARY_API_KEY_P8` | App-Store-Connect-API-Schlüssel (`AuthKey_….p8`), Base64 |
| `NOTARY_API_KEY_ID` | Schlüssel-ID dieses API-Schlüssels (10 Zeichen) |
| `NOTARY_API_ISSUER_ID` | Issuer-ID (UUID, steht über der Schlüsselliste) |

### 1. Zertifikat exportieren

1. Schlüsselbundverwaltung → *Meine Zertifikate* → „Developer ID Application: Manuel Weiser (LWWM5RV3D9)“
   (aufklappen: der private Schlüssel muss darunter hängen).
2. Rechtsklick → *Exportieren …* → Format *Persönlicher Informationsaustausch (.p12)* →
   ein neues, starkes Passwort vergeben.
3. In GitHub speichern und die Datei danach löschen:

   ```bash
   base64 -i ~/Desktop/DeveloperID.p12 | gh secret set MACOS_CERTIFICATE_P12 --repo ManuelW77/Schnittwerk
   gh secret set MACOS_CERTIFICATE_PASSWORD --repo ManuelW77/Schnittwerk
   rm ~/Desktop/DeveloperID.p12
   ```

   (`gh secret set` ohne Wert fragt das Passwort verdeckt ab.)

### 2. API-Schlüssel für die Notarisierung

Statt Apple-ID und app-spezifischem Passwort nutzt der Workflow einen API-Schlüssel –
der lässt sich einzeln widerrufen und braucht keine Zwei-Faktor-Anmeldung.

1. [App Store Connect](https://appstoreconnect.apple.com) → *Benutzer und Zugriff* →
   *Integrationen* → *App Store Connect API* → *Team-Schlüssel* → **+**.
2. Name z. B. „Schnittwerk Notarisierung“, Zugriff **Developer**.
3. `AuthKey_XXXXXXXXXX.p8` herunterladen (geht nur einmal!), Schlüssel-ID und Issuer-ID notieren.
4. In GitHub speichern:

   ```bash
   base64 -i ~/Downloads/AuthKey_XXXXXXXXXX.p8 | gh secret set NOTARY_API_KEY_P8 --repo ManuelW77/Schnittwerk
   gh secret set NOTARY_API_KEY_ID --repo ManuelW77/Schnittwerk
   gh secret set NOTARY_API_ISSUER_ID --repo ManuelW77/Schnittwerk
   ```

   Die .p8-Datei an einem sicheren Ort aufheben oder löschen.

## Lokal veröffentlichen (Ersatzweg)

Einmalig das Notarisierungs-Profil im Schlüsselbund anlegen – entweder mit dem API-Schlüssel
von oben oder mit Apple-ID und app-spezifischem Passwort (account.apple.com →
*Anmeldung und Sicherheit* → *App-spezifische Passwörter*):

```bash
xcrun notarytool store-credentials schnittwerk-notary --key ~/Downloads/AuthKey_XXXXXXXXXX.p8 --key-id XXXXXXXXXX --issuer DEINE-ISSUER-ID
```

Dann auf `main`:

```bash
tools/release/release.sh
```

| Aufruf | Wirkung |
|---|---|
| `tools/release/release.sh` | bauen, signieren, notarisieren, GitHub-Release anlegen |
| `tools/release/release.sh --dry-run` | nur bauen, signieren, DMG – keine Notarisierung, kein Upload |
| `tools/release/release.sh --no-upload` | notarisieren, aber nicht veröffentlichen |

Das Skript bricht ab, wenn es ungespeicherte Änderungen gibt, der Commit nicht gepusht ist
oder das Release schon existiert. In GitHub Actions prüft es stattdessen, dass der Tag
zur Version passt.

## Wenn die Notarisierung scheitert

Das Protokoll von Apple liegt unter `build/release/notary-log.json` (in Actions im Artefakt
`release-logs`). Häufige Ursachen: Hardened Runtime aus, fehlender Zeitstempel, unsignierte
Teile im Bundle.

## Später

- Updates mit Sparkle, optional ein Homebrew-Cask.
