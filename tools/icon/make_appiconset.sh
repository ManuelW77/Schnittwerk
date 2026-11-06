#!/bin/zsh
# Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later
# Renders icon variant C and writes all macOS AppIcon sizes.
# Usage: tools/icon/make_appiconset.sh
set -e
ROOT=${0:A:h:h:h}
SET="$ROOT/Schnittwerk/Resources/Assets.xcassets/AppIcon.appiconset"
TMP=$(mktemp -d)
mkdir -p "$SET"
env -u TOOLCHAINS xcrun swift "$ROOT/tools/icon/render_icons.swift" "$TMP" C >/dev/null
for size in 16 32 128 256 512; do
  sips -z $size $size "$TMP/C-klinge.png" --out "$SET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size*2)) $((size*2)) "$TMP/C-klinge.png" --out "$SET/icon_${size}x${size}@2x.png" >/dev/null
done
cat > "$SET/Contents.json" <<JSON
{
  "images" : [
$(for size in 16 32 128 256 512; do
  for scale in 1 2; do
    suffix=$([ $scale = 2 ] && echo "@2x" || echo "")
    echo "    { \"filename\" : \"icon_${size}x${size}${suffix}.png\", \"idiom\" : \"mac\", \"scale\" : \"${scale}x\", \"size\" : \"${size}x${size}\" },"
  done
done | sed '$ s/,$//')
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON
cat > "$ROOT/Schnittwerk/Resources/Assets.xcassets/Contents.json" <<JSON
{
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON
rm -rf "$TMP"
echo "AppIcon written to $SET"
