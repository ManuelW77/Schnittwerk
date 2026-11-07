#!/bin/bash
# Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later
#
# Builds a signed, notarized DMG and publishes it as a GitHub release.
#
#   tools/release/release.sh              everything: build, notarize, upload
#   tools/release/release.sh --dry-run    build and sign the DMG only
#                                          (no notarization, no upload)
#   tools/release/release.sh --no-upload  notarize, but do not publish
#
# Needs once (see tools/release/README.md):
#   - certificate "Developer ID Application" in the keychain
#   - notary profile:  xcrun notarytool store-credentials schnittwerk-notary
#   - gh logged in:    gh auth login
# Passwords never go into this script; notarytool reads them from the keychain.
#
# In GitHub Actions (.github/workflows/release.yml) the script runs for a
# pushed tag v<version>; notarization then uses an App Store Connect API key
# given in NOTARY_KEY_PATH, NOTARY_KEY_ID and NOTARY_ISSUER.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

APP_NAME="Schnittwerk"
IDENTITY="Developer ID Application: Manuel Weiser (LWWM5RV3D9)"
NOTARY_PROFILE="schnittwerk-notary"
BUILD_DIR="$ROOT/build/release"
DRY_RUN=0
UPLOAD=1

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1; UPLOAD=0 ;;
    --no-upload) UPLOAD=0 ;;
    -h|--help) sed -n '3,16p' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

step() { printf '\n\033[1m▶ %s\033[0m\n' "$1"; }
fail() { printf '\033[31m✗ %s\033[0m\n' "$1" >&2; exit 1; }

VERSION="$(sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([0-9.]*\)"\{0,1\}.*/\1/p' project.yml | head -1)"
[ -n "$VERSION" ] || fail "MARKETING_VERSION not found in project.yml"
TAG="v$VERSION"
DMG="$BUILD_DIR/$APP_NAME-$VERSION.dmg"

IN_CI=0
[ "${GITHUB_ACTIONS:-}" = "true" ] && IN_CI=1

# Notarization login: API key (CI) or keychain profile (your Mac)
if [ -n "${NOTARY_KEY_PATH:-}" ]; then
  NOTARY_ARGS=(--key "$NOTARY_KEY_PATH" --key-id "${NOTARY_KEY_ID:?}" --issuer "${NOTARY_ISSUER:?}")
else
  NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
fi

# ---------------------------------------------------------------- checks
step "Checks for $APP_NAME $VERSION"
command -v xcodegen >/dev/null || fail "xcodegen missing (brew install xcodegen)"
[ -f /opt/homebrew/lib/libusb-1.0.a ] || fail "libusb missing (brew install libusb)"
IDENTITIES="$(security find-identity -v -p codesigning)"
[[ "$IDENTITIES" == *"$IDENTITY"* ]] || fail "Certificate not found: $IDENTITY"
if [ $DRY_RUN -eq 0 ]; then
  xcrun notarytool history "${NOTARY_ARGS[@]}" >/dev/null 2>&1 \
    || fail "Notarization login failed. On your Mac run: xcrun notarytool store-credentials $NOTARY_PROFILE"
fi
if [ $UPLOAD -eq 1 ]; then
  gh auth status >/dev/null 2>&1 || fail "gh is not logged in (gh auth login)"
  if [ $IN_CI -eq 1 ]; then
    # The workflow runs for a tag; it must match the version in project.yml
    [ "${GITHUB_REF_TYPE:-}" = "tag" ] || fail "Releases are only made for tags (v<version>)."
    [ "${GITHUB_REF_NAME:-}" = "$TAG" ] || fail "Tag ${GITHUB_REF_NAME:-} does not match MARKETING_VERSION ($TAG)."
  else
    [ -z "$(git status --porcelain)" ] || fail "Uncommitted changes. Commit first, a release must match a commit."
    git fetch -q origin
    [ "$(git rev-parse HEAD)" = "$(git rev-parse @{u} 2>/dev/null || echo none)" ] \
      || fail "This commit is not pushed. Push first."
  fi
  if gh release view "$TAG" >/dev/null 2>&1; then
    fail "Release $TAG already exists. Raise MARKETING_VERSION in project.yml."
  fi
fi
echo "ok"

# ---------------------------------------------------------------- build
step "Build (Release, signed with Developer ID)"
xcodegen generate >/dev/null
rm -rf "$BUILD_DIR"
xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Release \
  -derivedDataPath "$BUILD_DIR/derived" clean build >"$BUILD_DIR.log" 2>&1 \
  || { tail -30 "$BUILD_DIR.log"; fail "Build failed (full log: $BUILD_DIR.log)"; }
APP="$BUILD_DIR/derived/Build/Products/Release/$APP_NAME.app"
mkdir -p "$BUILD_DIR"
mv "$BUILD_DIR.log" "$BUILD_DIR/build.log"

step "Check signature"
codesign --verify --deep --strict "$APP" || fail "Signature invalid"
SIGNATURE="$(codesign -dvv "$APP" 2>&1)"
[[ "$SIGNATURE" == *"(runtime)"* ]] || fail "Hardened Runtime is off"
[[ "$SIGNATURE" == *"Timestamp="* ]] || fail "Signature has no secure timestamp"
/usr/bin/lipo -archs "$APP/Contents/MacOS/$APP_NAME"
echo "ok"

# ---------------------------------------------------------------- dmg
step "Build DMG"
STAGE="$BUILD_DIR/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --sign "$IDENTITY" --timestamp "$DMG"
codesign --verify "$DMG"
echo "$DMG"

if [ $DRY_RUN -eq 1 ]; then
  step "Dry run: no notarization, no upload"
  echo "DMG: $DMG"
  exit 0
fi

# ---------------------------------------------------------------- notarize
step "Notarize (takes a few minutes)"
SUBMIT_LOG="$BUILD_DIR/notary.json"
xcrun notarytool submit "$DMG" "${NOTARY_ARGS[@]}" --wait --output-format json >"$SUBMIT_LOG" || true
STATUS="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status",""))' "$SUBMIT_LOG" 2>/dev/null || echo "")"
if [ "$STATUS" != "Accepted" ]; then
  ID="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("id",""))' "$SUBMIT_LOG" 2>/dev/null || echo "")"
  [ -n "$ID" ] && xcrun notarytool log "$ID" "${NOTARY_ARGS[@]}" "$BUILD_DIR/notary-log.json" || true
  fail "Notarization: ${STATUS:-failed}. Details: $BUILD_DIR/notary-log.json"
fi
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose "$DMG"
echo "ok"

if [ $UPLOAD -eq 0 ]; then
  step "Done without upload"
  echo "DMG: $DMG"
  exit 0
fi

# ---------------------------------------------------------------- publish
step "GitHub release $TAG"
NOTES="$BUILD_DIR/notes.md"
{
  echo "Schnittwerk $VERSION for macOS 26 or newer, Apple silicon (arm64)."
  echo
  echo "Download the DMG, open it and drag Schnittwerk into Applications."
  echo
  echo "## Changes"
  # Previous tag, not the one of this commit
  PREV="$(git describe --tags --abbrev=0 HEAD^ 2>/dev/null || true)"
  if [ -n "$PREV" ]; then
    git log --no-merges --format='- %s' "$PREV..HEAD"
  else
    git log --no-merges --format='- %s' -n 30
  fi
} >"$NOTES"
if [ $IN_CI -eq 1 ]; then
  gh release create "$TAG" "$DMG" --title "$APP_NAME $VERSION" --notes-file "$NOTES" --verify-tag
else
  gh release create "$TAG" "$DMG" --title "$APP_NAME $VERSION" --notes-file "$NOTES" --target "$(git rev-parse HEAD)"
fi
step "Published: $(gh release view "$TAG" --json url -q .url)"
