#!/bin/bash
# Builds AirStats for Intel and Apple silicon and assembles a launchable .app bundle.
#
# SwiftPM cannot produce an app bundle, and a menu bar app needs one: LSUIElement,
# a bundle identifier for UserDefaults and notifications, and a code signature so
# macOS will grant it a status item. So we build both architectures and wrap them here.
#
#   Scripts/build.sh            → debug universal build
#   Scripts/build.sh release    → optimised universal build
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
CONFIG="${1:-debug}"
if [ "$#" -gt 0 ]; then shift; fi

HOST_ARCH="$(uname -m)"
case "$HOST_ARCH" in
  arm64) OTHER_ARCH="x86_64" ;;
  x86_64) OTHER_ARCH="arm64" ;;
  *)
    echo "error: unsupported build host architecture '$HOST_ARCH'" >&2
    exit 1
    ;;
esac

# The regular .build directory keeps the native build products where the README and
# contributor instructions expect them. The other slice gets its own SwiftPM scratch
# directory so the two architectures never overwrite each other's modules or framework.
swift build -c "$CONFIG" "$@"
HOST_BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path "$@")"

OTHER_SCRATCH="$ROOT/.build-$OTHER_ARCH"
OTHER_TRIPLE="$OTHER_ARCH-apple-macosx14.0"
swift build -c "$CONFIG" --scratch-path "$OTHER_SCRATCH" --triple "$OTHER_TRIPLE" "$@"
OTHER_BIN_DIR="$(swift build -c "$CONFIG" --scratch-path "$OTHER_SCRATCH" \
  --triple "$OTHER_TRIPLE" --show-bin-path "$@")"

HOST_BINARY="$HOST_BIN_DIR/AirStats"
OTHER_BINARY="$OTHER_BIN_DIR/AirStats"
HOST_SPARKLE="$HOST_BIN_DIR/Sparkle.framework"
OTHER_SPARKLE="$OTHER_BIN_DIR/Sparkle.framework"
for required in "$HOST_BINARY" "$OTHER_BINARY" "$HOST_SPARKLE" "$OTHER_SPARKLE"; do
  if [ ! -e "$required" ]; then
    echo "error: expected build product is missing: $required" >&2
    exit 1
  fi
done

MERGE_TMP="$(mktemp -d "$ROOT/.build-universal-merge.XXXXXX")"
trap 'rm -rf "$MERGE_TMP"' EXIT

# SwiftPM's swiftbuild backend can write the deployment target into the SDK-version
# slot as well. AppKit uses the latter to select the system appearance, so restore it
# in each thin executable before combining the two architectures.
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
prepare_executable() {
  local source="$1"
  local destination="$2"
  local minimum

  minimum="$(vtool -show-build "$source" | awk '/minos/ { print $2; exit }')"
  if [ -z "$minimum" ]; then
    echo "error: could not read the minimum macOS version from $source" >&2
    return 1
  fi
  vtool -set-build-version macos "$minimum" "$SDK_VERSION" -replace \
    -output "$destination" "$source"
}

prepare_executable "$HOST_BINARY" "$MERGE_TMP/AirStats-$HOST_ARCH"
prepare_executable "$OTHER_BINARY" "$MERGE_TMP/AirStats-$OTHER_ARCH"
lipo -create "$MERGE_TMP/AirStats-$HOST_ARCH" "$MERGE_TMP/AirStats-$OTHER_ARCH" \
  -output "$MERGE_TMP/AirStats"
chmod +x "$MERGE_TMP/AirStats"

BIN_DIR="$HOST_BIN_DIR"
APP="$BIN_DIR/AirStats.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$MERGE_TMP/AirStats" "$APP/Contents/MacOS/AirStats"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# SwiftPM emits the UI target's resources as a bundle beside the binary. A signed app
# may hold resources only under Contents/Resources: putting this beside Contents leaves
# an unsealed object at the bundle root. Logo resolves this packaged location before it
# falls back to SwiftPM's development accessor.
#
# Named exactly rather than globbed: a tree built under an earlier package name leaves
# that name's bundle in the bin directory forever, and a glob ships both.
BUNDLE="$HOST_BIN_DIR/AirStats_AirStatUI.bundle"
if [ -d "$BUNDLE" ]; then
  cp -R "$BUNDLE" "$APP/Contents/Resources/"
else
  echo "error: $BUNDLE is missing; the app would launch with no logo" >&2
  exit 1
fi

# Sparkle ships as a framework. Copy the host framework and add the other architecture
# to any thin Mach-O files it contains. Some Sparkle package releases already ship a
# universal framework; those files are kept as-is, then checked alongside merged files.
ditto "$HOST_SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"

has_arch() {
  [[ " $1 " == *" $2 "* ]]
}

merge_framework_architectures() {
  local framework="$1"
  local other_framework="$2"
  local host_file other_file relative host_arches other_arches
  local index=0

  mkdir -p "$MERGE_TMP/framework-universal"

  while IFS= read -r -d '' host_file; do
    host_arches="$(lipo -archs "$host_file" 2>/dev/null)" || continue
    has_arch "$host_arches" "$HOST_ARCH" || continue
    if has_arch "$host_arches" "$OTHER_ARCH"; then continue; fi

    relative="${host_file#"$framework"/}"
    other_file="$other_framework/$relative"
    if [ ! -f "$other_file" ]; then
      echo "error: Sparkle is missing the $OTHER_ARCH build of $relative" >&2
      return 1
    fi
    other_arches="$(lipo -archs "$other_file" 2>/dev/null)" || {
      echo "error: Sparkle's $OTHER_ARCH build of $relative is not a Mach-O binary" >&2
      return 1
    }
    if ! has_arch "$other_arches" "$OTHER_ARCH"; then
      echo "error: Sparkle's $relative does not contain $OTHER_ARCH" >&2
      return 1
    fi

    lipo -create "$host_file" "$other_file" \
      -output "$MERGE_TMP/framework-universal/$index"
    chmod +x "$MERGE_TMP/framework-universal/$index"
    mv "$MERGE_TMP/framework-universal/$index" "$host_file"
    index=$((index + 1))
  done < <(find "$framework" -type f -print0)

  # Sparkle also bundles helper apps and XPC services. A partial merge would make the
  # main app launch but fail later when one of those helpers runs on the other CPU.
  while IFS= read -r -d '' host_file; do
    host_arches="$(lipo -archs "$host_file" 2>/dev/null)" || continue
    if ! has_arch "$host_arches" "$HOST_ARCH" || ! has_arch "$host_arches" "$OTHER_ARCH"; then
      echo "error: Sparkle binary is not universal: ${host_file#"$framework"/}" >&2
      return 1
    fi
  done < <(find "$framework" -type f -print0)
}

merge_framework_architectures \
  "$APP/Contents/Frameworks/Sparkle.framework" "$OTHER_SPARKLE"

# Sparkle writes "1.2 is now available—you have 1.1", and nothing else this app puts on
# screen uses an em dash. Only the English values are rewritten: the keys are what the
# framework looks strings up by, so changing one loses the translation entirely, and the
# other languages are somebody else's prose. Patched here rather than upstream because
# Scripts/release.sh signs the framework after this runs, so the signature covers it.
python3 - "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Resources/Base.lproj/Sparkle.strings" <<'PY'
import plistlib, sys

path = sys.argv[1]
with open(path, 'rb') as handle:
    strings = plistlib.load(handle)

patched = {key: value.replace('available—you have', 'available, you have')
           for key, value in strings.items()}
if patched != strings:
    with open(path, 'wb') as handle:
        plistlib.dump(patched, handle, fmt=plistlib.FMT_BINARY)
PY

# Ad-hoc signature. Without any signature macOS refuses some window-server
# privileges a status item needs.
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 || {
  echo "warning: codesign failed; the app may still run" >&2
}

echo "$APP"
