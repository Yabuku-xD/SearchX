#!/bin/bash
# Assembles a double-clickable .app around the SwiftPM binary — and, when
# asked, the disk image people install it from and the ZIP the updater
# fetches.
#
#   ./build.sh                 debug-free release build, ad-hoc signed: runs here
#   ./build.sh release dmg     + build/Search.dmg, build/Search.zip and
#                                build/appcast.json, signed with Developer ID
#                                if there is one in the keychain
#   ./build.sh release ship    + both notarised, the DMG stapled
#
# Same shape as the one next door: SwiftPM builds the executable, and a macOS
# app bundle is just a folder with a plist and the binary in the right place.
#
# The three files keep the same names from release to release, so the site
# links to them once and the updater reads one address forever. ./publish.sh
# copies them into the site.
#
# "dmg" lays the disk image's window out with dmgbuild, installed into .build
# on first use (Python 3 and a network, once).
#
# What "ship" needs, once:
#   - a Developer ID Application certificate in the login keychain
#     (SEARCH_SIGN_IDENTITY names it; otherwise the first one found is used)
#   - a notarytool profile: xcrun notarytool store-credentials "search"
#     (SEARCH_NOTARY_PROFILE names it; default "search")
#   - SEARCH_DOWNLOAD_URL, the https folder the three files are served from,
#     for the appcast. Default the latest GitHub release of Yabuku-xD/SearchX,
#     which is where Updater.feed in Updater.swift looks.
#
# NOTES.md, next to this script, is what's new: newest release first, one
# paragraph each. The first paragraph goes into the appcast, and from there
# under the version line in Settings.
set -euo pipefail

cd "$(dirname "$0")"
CONFIG="${1:-release}"
STEP="${2:-app}"
APP="build/SearchX.app"
# SearchX (Search, extended). The SwiftPM products keep their Search names;
# the app, its executable and everything a person sees are SearchX.
NAME="SearchX"
VERSION="$(tr -d '[:space:]' < VERSION)"
# A build number that only ever goes up, so the updater can tell newer from
# older without parsing version strings.
BUILD="$(date +%Y%m%d%H%M)"
# The oldest macOS this runs on — in the plist, and in the appcast so an
# older Mac is not handed a build it can't open.
MINIMUM="14.0"

# A build for both Apple Silicon and Intel Macs by default, so one app runs
# on every machine a copy might travel to. The archs are a plain list, so a
# single-arch build is one environment variable away
# (ARCHS="$(uname -m)") — the faster thing to do while working here. Each
# architecture is built on its own triple and the results are merged below,
# because SwiftPM's shared PIF build system writes both archs to the same
# path and one of them is lost.
ARCHS="${ARCHS:-arm64 x86_64}"
# Released builds are optimised for size: -Osize keeps -O's speed where it
# shows — the page is WebKit's to draw — and made the Apple silicon binary
# 15% smaller (5.77 MB to 4.93 MB, 26 September 2026).
SIZE=()
[ "$CONFIG" = "release" ] && SIZE=(-Xswiftc -Osize)
BUILT=()
for ARCH in $ARCHS; do
  echo "building ($ARCH)..."
  swift build --scratch-path ".build/slices/$ARCH" -c "$CONFIG" --triple "$ARCH-apple-macosx" ${SIZE[@]+"${SIZE[@]}"}
  BUILT+=("$(swift build --scratch-path ".build/slices/$ARCH" -c "$CONFIG" --triple "$ARCH-apple-macosx" ${SIZE[@]+"${SIZE[@]}"} --show-bin-path)")
done
# Where the binaries are, rather than guessing a path: with a site app helper
# in the package there is more than one, and Xcode's build system does not
# promise the flat layout it used to.
BINARY="${BUILT[0]}/Search"
SEARCH_BINARIES=()
for DIR in "${BUILT[@]}"; do SEARCH_BINARIES+=("$DIR/Search"); done
SITE_BINARIES=()
for DIR in "${BUILT[@]}"; do SITE_BINARIES+=("$DIR/SearchSite"); done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
# One binary, whichever way it was built: the single arch itself when there
# is one, or a universal one the slices are merged into.
if [ "${#BUILT[@]}" -eq 1 ]; then
  cp "${SEARCH_BINARIES[0]}" "$APP/Contents/MacOS/$NAME"
else
  lipo -create -output "$APP/Contents/MacOS/$NAME" "${SEARCH_BINARIES[@]}"
fi
# A site app carries just this small WebKit host, never a second browser
# engine. It is signed with Search here, then signed locally under the new
# site's identity when someone creates an app from the Tabs menu.
if [ "${#BUILT[@]}" -eq 1 ]; then
  cp "${SITE_BINARIES[0]}" "$APP/Contents/Helpers/SearchSite"
else
  lipo -create -output "$APP/Contents/Helpers/SearchSite" "${SITE_BINARIES[@]}"
fi

# Symbols stay out of the app. The linker leaves every function's name and a
# map back to the source in the binary — 15,000 entries, more than half of
# what the app weighed (6.5 MB of binary, 2.7 without them), and nothing the
# app reads while it runs. They are kept beside the build instead, as a dSYM
# that turns the addresses in a crash report back into names (Console, or
# atos -o build/Search.app.dSYM/Contents/Resources/DWARF/Search).
if [ "$CONFIG" = "release" ]; then
  rm -rf "$APP.dSYM"
  # The merged binary is what shipped, so it is what the symbols are read from.
  dsymutil "$APP/Contents/MacOS/$NAME" -o "$APP.dSYM" 2>/dev/null || echo "no dSYM this time" >&2
  strip -x "$APP/Contents/MacOS/$NAME"
  strip -x "$APP/Contents/Helpers/SearchSite"
fi

# The icon, drawn fresh each time — it is thirty lines of Swift, not an asset
# to keep in step with anything.
ICONSET="build/AppIcon.iconset"
ICONDOC="build/AppIcon.icon"
rm -rf "$ICONSET" "$ICONDOC"
cp Search.sdef "$APP/Contents/Resources/"
swift Icon/icon.swift "$ICONSET" "$ICONDOC" > /dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"
# macOS 26's Dark, Clear and Tinted Dock styles read the icon from an asset
# catalog compiled from the Icon Composer document; without one the Dock
# darkens the flat image and the mark goes black on black. actool comes with
# Xcode 26 — with anything older, or only the command-line tools, the app
# keeps the .icns alone, as before. Only Assets.car is kept: the .icns above
# stays the disk image's icon and the fallback. Full paths: actool hands the
# document to a helper that runs elsewhere, and with "build/…" finds nothing.
ICONNAME=""
ICONCAR="build/AppIcon.car"
rm -rf "$ICONCAR"
mkdir -p "$ICONCAR"
if xcrun actool "$PWD/$ICONDOC" --compile "$PWD/$ICONCAR" --platform macosx \
     --minimum-deployment-target "$MINIMUM" --app-icon AppIcon \
     --output-partial-info-plist "$PWD/$ICONCAR/partial.plist" > /dev/null 2>&1 \
   && [ -f "$ICONCAR/Assets.car" ]; then
  cp "$ICONCAR/Assets.car" "$APP/Contents/Resources/Assets.car"
  ICONNAME="<key>CFBundleIconName</key><string>AppIcon</string>"
else
  echo "note: actool from Xcode 26 didn't compile the icon — no Dark or Tinted style this time" >&2
fi
rm -rf "$ICONCAR" "$ICONDOC"

# The language files. English is the source — it lives in the code and needs
# no file — so each folder under Localization/ is one more language the app
# can speak, matched by its name. An untranslated sentence simply stays the
# sentence in the code.
_localizations() {
  echo "<string>en</string>"
  for L in Localization/*.lproj; do
    [ -d "$L" ] && echo "<string>$(basename "$L" .lproj)</string>"
  done
}
for L in Localization/*.lproj; do
  [ -d "$L" ] && cp -R "$L" "$APP/Contents/Resources/"
done

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>com.shyamalankannan.searchx</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  $ICONNAME
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key>
  <array>$(_localizations)</array>
  <key>LSMinimumSystemVersion</key><string>$MINIMUM</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 Shyamalan Kannan · SearchX</string>
  <key>NSHighResolutionCapable</key><true/>
  <!-- AppleScript in Safari's words: the tabs of a window, and each tab's
       address and name (see Search.sdef and Scripting.swift). -->
  <key>NSAppleScriptEnabled</key><true/>
  <key>OSAScriptingDefinition</key><string>Search.sdef</string>
  <!-- Owning http and https is what sends a link clicked in Mail here.
       Appearing in Desktop & Dock → Default web browser also needs the
       XHTML document type below. -->
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>Web address</string>
      <key>CFBundleURLSchemes</key>
      <array><string>http</string><string>https</string></array>
    </dict>
  </array>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Web page</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSItemContentTypes</key>
      <array><string>public.html</string><string>com.apple.web-internet-location</string></array>
    </dict>
    <!-- macOS only lists an app under Desktop & Dock → Default web browser
         when it claims public.xhtml as well as public.html. http and https
         alone, which Search already had, are not enough. -->
    <dict>
      <key>CFBundleTypeName</key><string>XHTML page</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSItemContentTypes</key>
      <array><string>public.xhtml</string></array>
    </dict>
  </array>
  <!-- A browser goes wherever it is pointed, including at http sites and at
       whatever is running on localhost. -->
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsArbitraryLoads</key><true/></dict>
  <!-- A browser is asked for these by the pages it shows, not by itself. macOS
       still wants a sentence to put in its own prompt, and touching the APIs
       without one is a crash rather than a refusal. -->
  <key>NSCameraUsageDescription</key>
  <string>Websites you visit can ask to use your camera. SearchX asks you the first time each site does and keeps your answer; Settings › Privacy forgets them.</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>Websites you visit can ask to use your microphone. SearchX asks you the first time each site does and keeps your answer; Settings › Privacy forgets them.</string>
  <key>NSDownloadsFolderUsageDescription</key>
  <string>Files you download are saved to your Downloads folder.</string>
</dict>
</plist>
PLIST

# Signing. A Developer ID certificate, when there is one, with the hardened
# runtime Gatekeeper insists on for anything notarised; otherwise ad-hoc,
# which is enough for the app to run on the machine that built it — and
# which the updater refuses to swap anything in under.
# An explicitly empty identity forces a local ad-hoc build.
if [ "${SEARCH_SIGN_IDENTITY+x}" = x ]; then
  IDENTITY="$SEARCH_SIGN_IDENTITY"
else
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)"
fi
# Passkeys need an entitlement Apple grants to browsers on request, and a
# Developer ID provisioning profile that carries it. With the profile next to
# this script, both go in; without it, the app is signed as before, because
# a restricted entitlement with no profile behind it is an app that won't open.
ENTITLEMENTS="Search.entitlements"
if [ -f "Search.provisionprofile" ]; then
  cp "Search.provisionprofile" "$APP/Contents/embedded.provisionprofile"
  # The profile names the team; the entitlements must name the same one.
  TEAM="$(security cms -D -i Search.provisionprofile | plutil -extract TeamIdentifier.0 raw -)"
  ENTITLEMENTS="$(mktemp -t searchx-entitlements).plist"
  sed "s/TEAMID/$TEAM/g" Search.passkeys.entitlements > "$ENTITLEMENTS"
  echo "passkeys: profile embedded"
fi
if [ -n "$IDENTITY" ]; then
  codesign --force --deep --timestamp --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --sign "$IDENTITY" "$APP"
  echo "signed as: $IDENTITY"
else
  # A build that cannot sign at all is not a build: `|| true` here let one
  # through as though it had finished, leaving a bundle that would not open.
  # set -e stops it now, with codesign's own words above.
  codesign --force --deep --sign - "$APP"
  [ "$STEP" != "app" ] && echo "no Developer ID certificate found — the DMG will only open on this Mac" >&2
fi

echo "built: $APP ($VERSION, build $BUILD)"
[ "$STEP" = "app" ] && exit 0

# The disk image: the app beside a shortcut to Applications, on a white
# window with an arrow between them — drawn by Installer/background.swift and
# laid out by Installer/dmg.py through dmgbuild, which writes the Finder's
# layout file itself, so no Finder is scripted and no window opens mid-build.
# dmgbuild is installed into .build the first time, and needs Python 3 and a
# network then; without it the image is the plain one it always was.
DMG="build/$NAME.dmg"
ART="build/installer"
rm -rf "$ART" "$DMG"
DMGBUILD=".build/dmgbuild/bin/dmgbuild"
if [ ! -x "$DMGBUILD" ]; then
  { python3 -m venv .build/dmgbuild && .build/dmgbuild/bin/pip install --quiet "dmgbuild==1.6.7"; } >/dev/null 2>&1 || true
fi
if [ -x "$DMGBUILD" ] \
  && swift Installer/background.swift "$ART" >/dev/null \
  && tiffutil -cathidpicheck "$ART/background.png" "$ART/background@2x.png" -out "$ART/background.tiff" >/dev/null 2>&1
then
  "$DMGBUILD" -s Installer/dmg.py \
    -D app="$APP" -D background="$ART/background.tiff" -D icon="$APP/Contents/Resources/AppIcon.icns" \
    "$NAME" "$DMG" >/dev/null
else
  echo "note: no dmgbuild — a plain disk image, without its window laid out" >&2
  STAGE="build/dmg"
  rm -rf "$STAGE"
  mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "$NAME" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
  rm -rf "$STAGE"
fi
rm -rf "$ART"
[ -n "$IDENTITY" ] && codesign --force --timestamp --sign "$IDENTITY" "$DMG"
echo "packed: $DMG"

# The ZIP is what the updater fetches, and its hash is what the updater
# checks before opening it.
ZIP="build/$NAME.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
echo "packed: $ZIP"

# What the updater reads. The first paragraph of NOTES.md, with the two
# characters JSON minds escaped, is the line under the version in Settings.
BASE="${SEARCH_DOWNLOAD_URL:-https://github.com/Yabuku-xD/SearchX/releases/latest/download}"
BASE="${BASE%/}"
NOTES=""
if [ -f NOTES.md ]; then
  NOTES="$(awk 'NF { printf "%s%s", (n++ ? " " : ""), $0; next } n { exit }' NOTES.md \
    | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
fi
cat > build/appcast.json <<JSON
{
  "version": "$VERSION",
  "build": $BUILD,
  "url": "$BASE/$NAME.zip",
  "dmg": "$BASE/$NAME.dmg",
  "sha256": "$SHA",
  "notes": "$NOTES",
  "minimumSystemVersion": "$MINIMUM"
}
JSON
echo "wrote: build/appcast.json ($VERSION, build $BUILD)"
[ "$STEP" = "dmg" ] && exit 0

# Notarisation: Apple looks both over. The ticket is stapled to the image,
# so it opens on a Mac that has never seen this app and is offline; the ZIP
# is fetched by an app that already trusts it, and is left as hashed.
[ -z "$IDENTITY" ] && { echo "can't ship without a Developer ID certificate" >&2; exit 1; }
for FILE in "$DMG" "$ZIP"; do
  xcrun notarytool submit "$FILE" --keychain-profile "${SEARCH_NOTARY_PROFILE:-search}" --wait
done
xcrun stapler staple "$DMG"
echo "shipped: $DMG, $ZIP and build/appcast.json — ./publish.sh <folder> puts them on the site"
