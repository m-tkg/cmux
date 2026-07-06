#!/usr/bin/env bash
# Personal Developer ID release build for a cmux fork (no Manaflow secrets).
#
# Builds a universal Release cmux.app, signs it inside-out with a personal
# Developer ID via scripts/sign-cmux-bundle.sh, optionally notarizes and
# staples it, and emits a distributable zip under dist/.
#
# Usage:
#   scripts/build-personal-release.sh
#
# Env:
#   CMUX_PERSONAL_SIGNING_IDENTITY   codesign identity (default: the single
#                                    "Developer ID Application" in the keychain)
#   CMUX_PERSONAL_NOTARY_PROFILE     notarytool keychain profile name
#                                    (default: cmux-personal; skipped with a
#                                    warning when the profile does not exist)
#   CMUX_PERSONAL_ARCHS              default "arm64 x86_64"
#   CMUX_SOURCE_PACKAGES_DIR         forwarded to -clonedSourcePackagesDirPath
#   CMUX_DISABLE_AUTOMATIC_PACKAGE_RESOLUTION=1
#                                    forwarded to -disableAutomaticPackageResolution
#   CMUX_PERSONAL_KEEP_SPARKLE=1     keep the Sparkle feed (default: the feed is
#                                    stripped so official updates cannot replace
#                                    this personal build)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
cd "$ROOT"

DERIVED_DATA="$ROOT/build-personal"
DIST_DIR="$ROOT/dist"
APP_PATH="$DERIVED_DATA/Build/Products/Release/cmux.app"
ARCHS="${CMUX_PERSONAL_ARCHS:-arm64 x86_64}"
NOTARY_PROFILE="${CMUX_PERSONAL_NOTARY_PROFILE:-cmux-personal}"
GHOSTTY_ZIG_VERSION="$(python3 - <<'PY'
import re, pathlib
text = pathlib.Path("ghostty/build.zig.zon").read_text()
match = re.search(r'\.minimum_zig_version\s*=\s*"([^"]+)"', text)
print(match.group(1) if match else "")
PY
)"

log() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }

# --- Resolve signing identity -------------------------------------------------
IDENTITY="${CMUX_PERSONAL_SIGNING_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning \
    | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
fi
if [[ -z "$IDENTITY" ]]; then
  echo "error: no 'Developer ID Application' identity found." >&2
  echo "       Set CMUX_PERSONAL_SIGNING_IDENTITY or install the certificate." >&2
  exit 1
fi
log "Signing identity: $IDENTITY"

# --- Preflight ----------------------------------------------------------------
./scripts/ensure-ghosttykit.sh

if command -v rustup >/dev/null 2>&1 && ! rustup which rustc >/dev/null 2>&1; then
  warn "rustup has no default toolchain; the optional Nucleo FFI build phase will fail."
  warn "Fix with 'rustup default stable', or remove cargo/rustup from PATH to skip the optional phase."
fi

# --- Build the universal Ghostty CLI helper (optional, needs pinned zig) -------
# The zig build needs a macOS SDK the pinned zig's clang understands; on hosts
# whose only Xcode ships a newer SDK, point CMUX_PERSONAL_HELPER_DEVELOPER_DIR
# at an older Xcode (mirrors nightly's HELPER_DEVELOPER_DIR). Failures fall
# back to the in-Xcode stub so the app still builds.
HELPER_BIN=""
if command -v zig >/dev/null 2>&1 && [[ "$(zig version)" == "$GHOSTTY_ZIG_VERSION" ]]; then
  log "Building universal Ghostty CLI helper (zig $GHOSTTY_ZIG_VERSION)"
  HELPER_BIN="$DERIVED_DATA/ghostty-cli-helper-universal"
  mkdir -p "$DERIVED_DATA"
  if ! ( \
    if [[ -n "${CMUX_PERSONAL_HELPER_DEVELOPER_DIR:-}" ]]; then \
      export DEVELOPER_DIR="$CMUX_PERSONAL_HELPER_DEVELOPER_DIR"; \
    fi; \
    ./scripts/build-ghostty-cli-helper.sh --universal --output "$HELPER_BIN" \
  ); then
    warn "Ghostty CLI helper build failed; shipping the stub instead."
    warn "(theme picker CLI degrades; the terminal itself is unaffected)"
    HELPER_BIN=""
  fi
else
  warn "zig $GHOSTTY_ZIG_VERSION not available ($(command -v zig >/dev/null 2>&1 && zig version || echo 'zig not installed')); skipping the bundled Ghostty CLI helper."
fi

# --- Build the app (unsigned; we codesign inside-out below) --------------------
log "Building cmux.app (Release, ARCHS=$ARCHS)"
XCODEBUILD_ARGS=(
  -project cmux.xcodeproj
  -scheme cmux
  -configuration Release
  -destination 'generic/platform=macOS'
  -derivedDataPath "$DERIVED_DATA"
)
if [[ -n "${CMUX_SOURCE_PACKAGES_DIR:-}" ]]; then
  XCODEBUILD_ARGS+=(-clonedSourcePackagesDirPath "$CMUX_SOURCE_PACKAGES_DIR")
fi
if [[ "${CMUX_DISABLE_AUTOMATIC_PACKAGE_RESOLUTION:-}" == "1" ]]; then
  XCODEBUILD_ARGS+=(-disableAutomaticPackageResolution)
fi
CMUX_SKIP_ZIG_BUILD=1 xcodebuild "${XCODEBUILD_ARGS[@]}" \
  ARCHS="$ARCHS" ONLY_ACTIVE_ARCH=NO \
  CMUX_SKIP_ZIG_BUILD=1 \
  CODE_SIGNING_ALLOWED=NO build

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: built app not found at $APP_PATH" >&2
  exit 1
fi

# --- Inject the Ghostty CLI helper ---------------------------------------------
if [[ -n "$HELPER_BIN" ]]; then
  ./scripts/install-prebuilt-ghostty-cli-helper.sh "$HELPER_BIN" "$APP_PATH"
fi

# --- Ensure the Nucleo FFI dylib is bundled -------------------------------------
# The in-Xcode phase declares outputs, so an earlier cargo-less run can be
# cached as success and never rerun; sign-cmux-bundle.sh requires the dylib.
NUCLEO_DYLIB="$APP_PATH/Contents/Frameworks/libcmux_command_palette_nucleo_ffi.dylib"
if [[ ! -f "$NUCLEO_DYLIB" ]]; then
  if ! command -v cargo >/dev/null 2>&1; then
    echo "error: $NUCLEO_DYLIB is missing and cargo is not on PATH to build it." >&2
    exit 1
  fi
  log "Building Nucleo FFI dylib (missing from the cached build)"
  TARGET_BUILD_DIR="$DERIVED_DATA/Build/Products/Release" \
    FRAMEWORKS_FOLDER_PATH="cmux.app/Contents/Frameworks" \
    CODE_SIGNING_ALLOWED=NO \
    CMUX_NUCLEO_FFI_ARCHS="$ARCHS" \
    ./scripts/build-command-palette-nucleo-ffi.sh
fi

# --- Detach the personal build from the official Sparkle feed ------------------
if [[ "${CMUX_PERSONAL_KEEP_SPARKLE:-0}" != "1" ]]; then
  if /usr/libexec/PlistBuddy -c "Delete :SUFeedURL" "$APP_PATH/Contents/Info.plist" 2>/dev/null; then
    log "Removed SUFeedURL (official auto-updates would replace this personal build)"
  fi
fi

# --- Sign ----------------------------------------------------------------------
log "Signing bundle inside-out"
./scripts/sign-cmux-bundle.sh "$APP_PATH" cmux.personal.entitlements "$IDENTITY"
codesign --verify --strict --verbose=2 "$APP_PATH"

# --- Notarize + staple (optional) ----------------------------------------------
VERSION="$(sed -n 's/.*MARKETING_VERSION = \([0-9.]*\);.*/\1/p' cmux.xcodeproj/project.pbxproj | head -1)"
SHORT_SHA="$(git rev-parse --short HEAD)"
mkdir -p "$DIST_DIR"
ZIP_PATH="$DIST_DIR/cmux-personal-v${VERSION}-${SHORT_SHA}.zip"

if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  log "Notarizing with keychain profile '$NOTARY_PROFILE'"
  NOTARY_ZIP="$DIST_DIR/cmux-personal-notary.zip"
  ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$NOTARY_ZIP"
  xcrun notarytool submit "$NOTARY_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  rm -f "$NOTARY_ZIP"
  xcrun stapler staple "$APP_PATH"
  xcrun stapler validate "$APP_PATH"
  spctl -a -vv --type execute "$APP_PATH"
else
  warn "notarytool profile '$NOTARY_PROFILE' not found; skipping notarization."
  warn "Gatekeeper will warn on quarantined copies. Set it up once with:"
  warn "  xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <apple-id> --team-id <team-id> --password <app-specific-password>"
fi

# --- Package -------------------------------------------------------------------
rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

log "Done"
printf 'App: %s\n' "$APP_PATH"
printf 'Zip: %s\n' "$ZIP_PATH"
