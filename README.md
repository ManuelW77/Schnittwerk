# Schnittwerk

Native macOS app for cutting on a **Silhouette Cameo 4** – a lean alternative to Silhouette Studio.
Native macOS-App zum Schneiden auf dem **Silhouette Cameo 4** – ein schlanker Ersatz für Silhouette Studio.

> Not affiliated with Silhouette America, Inc. "Silhouette" and "Cameo" are trademarks of their owners.
> Kein Produkt von Silhouette America, Inc. „Silhouette“ und „Cameo“ sind Marken ihrer Inhaber.

## Features (planned for 0.1)
- Import SVG and DXF
- Text from Mac fonts as cut lines
- Move, scale, rotate, mirror on a 12×12 / 12×24 mat or roll
- Cut settings: blade, force, speed, passes, material presets, test cut
- Send directly via USB (GPGL)

## Design tools / Gestaltung
- Basic shapes: rectangle (rounded corners), ellipse, polygon, star – editable afterwards
- Multiple selection: shift/⌘ click, rubber band
- Weld, subtract, intersect
- Offset outwards or inwards, round or sharp corners
- Align and distribute

Languages: English, Deutsch.

## Build
Requirements: macOS 26+ on Apple silicon, Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen), libusb (`brew install xcodegen libusb`).
libusb is linked statically, so the built app runs without Homebrew.

```bash
xcodegen generate
xcodebuild -project Schnittwerk.xcodeproj -scheme Schnittwerk -derivedDataPath build build
```

Translations: edit `tools/l10n/de.json`, then run `python3 tools/l10n/build_catalogs.py`.

## Branches
- `main` – released state
- `devel` – testing
- `feature/…` – one branch per feature, merged into `devel` for testing

## License
GPL-3.0-or-later, see [LICENSE](LICENSE).
The USB protocol details were learned from the open-source project
[inkscape-silhouette](https://github.com/fablabnbg/inkscape-silhouette); no code was copied.
