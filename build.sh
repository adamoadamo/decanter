#!/bin/bash
# Builds Decanter.app (universal: arm64 + x86_64) into ./build.
#
#   ./build.sh              quick local build, ad-hoc signed (runs on this Mac only)
#   ./build.sh --notarise   Developer ID signed, notarised, stapled, zipped into ./dist
#   ./build.sh --release    --notarise, then publishes the zip as a GitHub release, which
#                           is what tells existing copies of Decanter there's an update
#
# Notarising needs an unlocked keychain holding the Developer ID key and the
# notary profile below. See RELEASING.md.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Decanter.app"
# Developer ID Application: Adam O'Reilly (83YKH78UXW), signed by hash.
IDENTITY="${DECANTER_SIGN_IDENTITY:-755F880D8DBA3C9C44D4244F110D3469DA72F37A}"
PROFILE="${DECANTER_NOTARY_PROFILE:-perturbazione-notary}"
REPO="adamoadamo/decanter"   # must match Updates.repo in Sources/Decanter/Updates.swift

NOTARISE=0
RELEASE=0
case "${1:-}" in
    --notarise|--notarize) NOTARISE=1 ;;
    --release) NOTARISE=1; RELEASE=1 ;;
    "") ;;
    *) echo "usage: $0 [--notarise | --release]" >&2; exit 2 ;;
esac

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
NOTES="release-notes/$VERSION.md"
if [ $RELEASE = 1 ]; then
    # Check everything a release needs before spending minutes on notarising.
    [ -f "$NOTES" ] || { echo "Write the release notes first: $NOTES" >&2; exit 1; }
    gh auth status >/dev/null 2>&1 || { echo "Log in to GitHub first: gh auth login" >&2; exit 1; }
    if gh release view "v$VERSION" --repo "$REPO" >/dev/null 2>&1; then
        echo "v$VERSION is already released. Bump CFBundleShortVersionString in Resources/Info.plist." >&2
        exit 1
    fi
    if [ -n "$(git status --porcelain)" ]; then
        echo "Commit your changes first, so the release matches the source on GitHub:" >&2
        git status --short >&2
        exit 1
    fi
fi

if [ ! -f Resources/AppIcon.icns ]; then
    echo "Making app icon…"
    ICONSET="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$ICONSET"
    swift scripts/make-icon.swift "$ICONSET/icon_512x512@2x.png"
    for s in 16 32 128 256 512; do
        sips -z $s $s "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
        sips -z $((s * 2)) $((s * 2)) "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
fi

# Command Line Tools can't build both architectures in one go, so build each and merge.
echo "Compiling (arm64 + x86_64)…"
for arch in arm64 x86_64; do
    swift build -c release --triple "$arch-apple-macosx14.0"
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create -output "$APP/Contents/MacOS/Decanter" \
    .build/arm64-apple-macosx/release/Decanter \
    .build/x86_64-apple-macosx/release/Decanter
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
xattr -cr "$APP" 2>/dev/null || true

if [ $NOTARISE = 0 ]; then
    codesign --force --sign - "$APP"
    echo "Built $APP (ad-hoc signed)"
    exit 0
fi

echo "Signing with Developer ID…"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "Submitting to Apple (usually one to two minutes)…"
SUBMIT_ZIP="build/Decanter-submit.zip"
RESULT="build/notary-result.json"
rm -f "$SUBMIT_ZIP"
ditto -c -k --keepParent "$APP" "$SUBMIT_ZIP"   # ditto, never zip
xcrun notarytool submit "$SUBMIT_ZIP" --keychain-profile "$PROFILE" --wait --output-format json > "$RESULT"
rm -f "$SUBMIT_ZIP"
STATUS=$(plutil -extract status raw -o - "$RESULT")
SUBMISSION=$(plutil -extract id raw -o - "$RESULT")
echo "Apple says: $STATUS (submission $SUBMISSION)"
if [ "$STATUS" != "Accepted" ]; then
    echo "See why with: xcrun notarytool log $SUBMISSION --keychain-profile $PROFILE" >&2
    exit 1
fi

# stapler fails with Error 73 when the path contains a space (as "untitled folder"
# does), so staple a copy in a temporary folder and copy it back.
STAPLE_DIR="$(mktemp -d)"
ditto "$APP" "$STAPLE_DIR/Decanter.app"
xcrun stapler staple "$STAPLE_DIR/Decanter.app"
xcrun stapler validate "$STAPLE_DIR/Decanter.app"
rm -rf "$APP"
ditto "$STAPLE_DIR/Decanter.app" "$APP"
rm -rf "$STAPLE_DIR"
ASSESSMENT=$(spctl -a -vvv -t install "$APP" 2>&1)
echo "$ASSESSMENT"
if ! grep -q "source=Notarized Developer ID" <<<"$ASSESSMENT"; then
    echo "Gatekeeper did not accept the stapled app." >&2
    exit 1
fi

mkdir -p dist
OUT="dist/Decanter-$VERSION.zip"
rm -f "$OUT"
ditto -c -k --keepParent "$APP" "$OUT"
echo "Notarised and ready to share: $OUT"

if [ $RELEASE = 1 ]; then
    echo "Publishing v$VERSION on GitHub…"
    git push origin HEAD
    gh release create "v$VERSION" "$OUT" --repo "$REPO" --target "$(git rev-parse HEAD)" \
        --title "Decanter $VERSION" --notes-file "$NOTES"
    echo "Released. Copies of Decanter will offer it the next time they open (checked once a day)."
fi
