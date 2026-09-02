#!/bin/bash
# Signs, notarizes and packages AirStats as a .dmg users can download and open.
#
# Scripts/build.sh signs ad-hoc, which proves only that the bundle is intact. macOS
# refuses an ad-hoc bundle that arrived over the internet outright ("AirStats is
# damaged"), so distribution needs a real Developer ID signature, Apple's notarization
# ticket, and that ticket stapled onto the file so it validates with no network.
#
#   Scripts/release.sh          → .dmg in dist/
#
# Requires a Developer ID Application certificate in the keychain and a notarytool
# credential profile. Both are one-time setup; see the preflight errors below.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
PROFILE="${NOTARY_PROFILE:-AirStats}"
DIST="dist"

# Sparkle ships generate_keys and sign_update alongside the framework SwiftPM fetched,
# so a checkout that can build can also sign an update. SPARKLE_BIN overrides it for a
# copy unpacked from the tarball.
SPARKLE_BIN="${SPARKLE_BIN:-.build/artifacts/sparkle/Sparkle/bin}"

# The same key `generate_keys -x` wrote, read from the file rather than from the login
# keychain. sign_update reads the keychain by default and macOS answers that with a
# dialog no script can click, which stalls the release halfway through notarization.
SPARKLE_KEY="${SPARKLE_KEY:-$HOME/private_keys/airstats_sparkle_ed25519.key}"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist)"

# Deliberately unversioned. The README and the site both link
# releases/latest/download/AirStats.dmg, which resolves only against an asset of
# exactly that name, so putting the version in the filename breaks the one URL that
# never has to be updated. The version lives in the git tag and in the bundle.
DMG="$DIST/AirStats.dmg"

if ! security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
  echo "error: no '$IDENTITY' certificate in the keychain." >&2
  echo "  Xcode > Settings > Accounts > Manage Certificates > + > Developer ID Application" >&2
  exit 1
fi

if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  # The App Store Connect key is a file on disk, so the command below can name the real
  # one rather than a placeholder to be worked out under pressure. The issuer cannot be
  # recovered from anything local: it is the UUID on App Store Connect > Users and
  # Access > Integrations > App Store Connect API.
  KEY_FILE="$(ls "$HOME"/private_keys/AuthKey_*.p8 2>/dev/null | head -n 1)"
  if [ -n "$KEY_FILE" ]; then
    KEY_ID="$(basename "$KEY_FILE" .p8)"
    KEY_ID="${KEY_ID#AuthKey_}"
  else
    KEY_FILE="~/private_keys/AuthKey_XXXXXXXXXX.p8"
    KEY_ID="XXXXXXXXXX"
  fi
  echo "error: no notarytool credential profile named '$PROFILE'." >&2
  echo "  Store it once, then run this script again:" >&2
  echo "    xcrun notarytool store-credentials $PROFILE \\" >&2
  echo "      --key $KEY_FILE \\" >&2
  echo "      --key-id $KEY_ID \\" >&2
  echo "      --issuer <uuid from App Store Connect > Integrations > App Store Connect API>" >&2
  exit 1
fi

if [ ! -x "$SPARKLE_BIN/sign_update" ]; then
  echo "error: no sign_update in '$SPARKLE_BIN'." >&2
  echo "  Run swift build once to fetch Sparkle, or set SPARKLE_BIN to the bin/" >&2
  echo "  directory of an unpacked Sparkle-<version>.tar.xz." >&2
  exit 1
fi

if [ ! -f "$SPARKLE_KEY" ]; then
  echo "error: no Sparkle private key at '$SPARKLE_KEY'." >&2
  echo "  It is the file $SPARKLE_BIN/generate_keys -x wrote. Without it no copy" >&2
  echo "  of AirStats in the field will accept this build as an update." >&2
  exit 1
fi

APP="$(Scripts/build.sh release | tail -n 1)"

# Extended attributes picked up from the filesystem (quarantine flags, Finder info)
# make codesign fail with a bare "resource fork, Finder information, or similar
# detritus not allowed" that names no file.
xattr -cr "$APP"

# Sparkle's framework holds two XPC services, the Autoupdate tool and Updater.app, and
# notarization checks every one of them, so each is signed before the thing containing
# it. Innermost first: signing a container records the hashes of what it holds.
#
# --deep is deliberately not used on any of it, which is Sparkle's own instruction. The
# Downloader service carries an entitlement that belongs to it alone, and a deep
# signature would overwrite it with this app's.
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --options runtime --timestamp \
  --sign "$IDENTITY" "$FRAMEWORK/Versions/B/XPCServices/Installer.xpc"
codesign --force --options runtime --timestamp --preserve-metadata=entitlements \
  --sign "$IDENTITY" "$FRAMEWORK/Versions/B/XPCServices/Downloader.xpc"
codesign --force --options runtime --timestamp \
  --sign "$IDENTITY" "$FRAMEWORK/Versions/B/Autoupdate"
codesign --force --options runtime --timestamp \
  --sign "$IDENTITY" "$FRAMEWORK/Versions/B/Updater.app"
codesign --force --options runtime --timestamp \
  --sign "$IDENTITY" "$FRAMEWORK"

# --options runtime is the hardened runtime, which notarization refuses to accept
# without. --timestamp pins the signature to a trusted clock so it stays valid after
# the certificate itself expires.
codesign --force --options runtime --timestamp \
  --sign "$IDENTITY" "$APP"

codesign --verify --strict --deep "$APP"

# Notarize the app itself before packaging so the ticket can be stapled into the
# bundle. Stapling only the .dmg leaves the copy the user drags to /Applications
# without a ticket, and its first launch then needs a working network to verify.
ZIP="$DIST/AirStats-app.zip"
mkdir -p "$DIST"
rm -f "$ZIP" "$DMG"
ditto -c -k --keepParent "$APP" "$ZIP"

xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
rm -f "$ZIP"

# A .dmg opens as a window holding the app next to a shortcut to /Applications, so
# installing is one drag. `hdiutil create -srcfolder` makes that image but records no
# window settings, so Finder opens it as a plain list of two names and nothing tells
# the user to drag. dmgbuild writes the layout in Scripts/dmg.py into the image's
# .DS_Store itself, rather than by scripting Finder, so this needs no Automation grant
# and no window on screen. Icon positions there line up with the arrow drawn by
# Scripts/dmg-background.py.
uv run --with dmgbuild dmgbuild \
  -s "$ROOT/Scripts/dmg.py" \
  -D app="$APP" \
  -D root="$ROOT" \
  "AirStats" "$DMG" >/dev/null

codesign --force --timestamp --sign "$IDENTITY" "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"

# What Gatekeeper will decide on the user's machine. Anything but "accepted" here is
# what they would see instead of the app opening.
spctl --assess --type open --context context:primary-signature -v "$DMG"

# A second copy under the version, because the unversioned name is about to be
# overwritten by the next run and a dmg is minutes of notarization to reproduce.
cp "$DMG" "$DIST/AirStats-$VERSION.dmg"

# Sparkle installs a dmg only if its EdDSA signature matches the SUPublicEDKey in the
# copy already running, so this is what makes the file installable rather than merely
# downloadable.
SIGNATURE="$("$SPARKLE_BIN/sign_update" --ed-key-file "$SPARKLE_KEY" "$DMG")"

# Writes into the site checkout beside this one by default. APPCAST points it somewhere
# else, which is how a dry run stays out of a repo it is not ready to commit to.
uv run Scripts/appcast.py \
  --version "$VERSION" --build "$BUILD" --dmg "$DMG" --signature "$SIGNATURE" \
  ${APPCAST:+--appcast "$APPCAST"}

# The homebrew/cask entry pins a version and a checksum of this exact file, and nothing
# above updates it. Homebrew's autobump bot usually opens that PR within a day of the
# GitHub release, but a release that ships without it leaves everyone who installed with
# Homebrew on the previous version, so the sha256 is printed here for the manual bump.
SHA="$(shasum -a 256 "$DMG" | cut -d ' ' -f 1)"

echo
echo "$DMG (version $VERSION, build $BUILD)"
echo "  sha256 $SHA"
echo "  $SIGNATURE"
echo
echo "Next, in this order (docs/RELEASING.md has the reasons):"
echo "  1. git tag v$VERSION && git push origin v$VERSION"
echo "  2. gh release create v$VERSION $DMG --title \"AirStats $VERSION\""
echo "     The asset must be named AirStats.dmg. The appcast item already points at it."
echo "  3. brew bump-cask-pr airstats --version $VERSION"
echo "     Skip it if Homebrew's autobump bot already opened one. The sha256 must be $SHA."
echo "  4. Commit and push public/appcast.xml in airstat-site. Do this last: it is what"
echo "     tells every installed copy to go and download the file from step 2."
