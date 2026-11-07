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

## AI design via MCP / KI-Gestaltung über MCP
Schnittwerk has a built-in [MCP](https://modelcontextprotocol.io) server, so an AI assistant can design on the mat.
Off by default. Turn it on in Settings → AI (MCP); it listens on `127.0.0.1` only and needs a secret key
(`Authorization: Bearer …`). Copy the ready-made command from that settings tab, it looks like this:

```bash
claude mcp add --transport http --scope user schnittwerk http://127.0.0.1:39170/mcp --header "Authorization: Bearer <key>"
```

Tools: `get_document`, `render_preview`, `add_svg`, `add_text`, `add_shape`, `update_object`, `delete_objects`,
`duplicate_objects`, `combine`, `add_offset`, `arrange`, `set_mat`, `list_fonts`, `new_document`.
They work on the front project window; every change is one undo step (⌘Z). Cutting is not available through MCP.

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
