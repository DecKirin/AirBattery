#!/usr/bin/env bash
#
# Build AirBattery.app and package it as a drag-to-Applications DMG.
#
# Local counterpart to .github/workflows/build-dmg.yml. Same build settings, same verification
# steps, plus the Developer ID + notarization path that CI cannot take (no certificate there).
#
#   ./scripts/build-dmg.sh                       # auto: Developer ID if you have one, else ad-hoc
#   ./scripts/build-dmg.sh --adhoc               # force ad-hoc (unsigned, for local testing)
#   ./scripts/build-dmg.sh --notarize AirBattery # Developer ID + notarize + staple (shippable)
#   ./scripts/build-dmg.sh --help
#
# An AD-HOC signed DMG opens only on the machine that built it; anyone else has to run
# `xattr -dr com.apple.quarantine /Applications/AirBattery.app` first. Ad-hoc builds also pass
# ENABLE_HARDENED_RUNTIME=NO — see resolve_signing() for why that is required, not preferred.

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO_ROOT"

# ---------------------------------------------------------------------------- defaults

PROJECT="AirBattery.xcodeproj"
SCHEME="AirBattery"
CONFIGURATION="Release"
DERIVED_DATA="$REPO_ROOT/build"
OUTPUT_DIR="$REPO_ROOT/dist"
VOLNAME="AirBattery"

IDENTITY="auto"        # "auto" | "-" (ad-hoc) | a codesign identity name
TEAM_ID=""             # DEVELOPMENT_TEAM; derived from the identity when not given
NOTARY_PROFILE=""      # notarytool keychain profile name; empty = don't notarize
DO_BUILD=1
DO_SMOKE=0             # opt-in: actually launches the app for 10s

# ---------------------------------------------------------------------------- output helpers

if [[ -t 1 ]]; then
    BOLD=$'\033[1m'; RED=$'\033[31m'; YELLOW=$'\033[33m'; GREEN=$'\033[32m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else
    BOLD=""; RED=""; YELLOW=""; GREEN=""; DIM=""; RESET=""
fi

step() { printf '\n%s==>%s %s%s%s\n' "$GREEN" "$RESET" "$BOLD" "$*" "$RESET"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '%swarning:%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

usage() {
    sed -n '3,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    cat <<'USAGE'

Options:
  --adhoc                  Force ad-hoc signing even if a Developer ID is installed.
  --identity <name>        Codesign identity to use (e.g. "Developer ID Application: Acme (ABCDE12345)").
  --team <id>              DEVELOPMENT_TEAM. Defaults to the Team ID parsed out of the identity.
  --notarize <profile>     Submit the DMG to notarytool using this keychain profile, then staple.
                           Create one once with:
                             xcrun notarytool store-credentials <profile> \
                               --apple-id <id> --team-id <team> --password <app-specific-password>
  --smoke                  Launch the built app for 10s to prove dyld can map embedded frameworks.
                           Off by default locally: it starts a real second AirBattery instance,
                           which writes to the same App Group container as one already running.
  --skip-build             Package the app already in the derived-data path; don't rebuild.
  --configuration <name>   Xcode configuration. Default: Release.
  --derived-data <path>    Default: ./build
  --output <dir>           Where to write the DMG. Default: ./dist
  -h, --help               This text.
USAGE
}

# ---------------------------------------------------------------------------- arguments

while [[ $# -gt 0 ]]; do
    case "$1" in
        --adhoc)          IDENTITY="-"; shift ;;
        --identity)       IDENTITY="${2:?--identity needs a value}"; shift 2 ;;
        --team)           TEAM_ID="${2:?--team needs a value}"; shift 2 ;;
        --notarize)       NOTARY_PROFILE="${2:?--notarize needs a keychain profile name}"; shift 2 ;;
        --smoke)          DO_SMOKE=1; shift ;;
        --no-smoke)       DO_SMOKE=0; shift ;;
        --skip-build)     DO_BUILD=0; shift ;;
        --configuration)  CONFIGURATION="${2:?--configuration needs a value}"; shift 2 ;;
        --derived-data)   DERIVED_DATA="${2:?--derived-data needs a value}"; shift 2 ;;
        --output)         OUTPUT_DIR="${2:?--output needs a value}"; shift 2 ;;
        -h|--help)        usage; exit 0 ;;
        *)                die "unknown option: $1 (try --help)" ;;
    esac
done

APP="$DERIVED_DATA/Build/Products/$CONFIGURATION/AirBattery.app"

# ---------------------------------------------------------------------------- preflight

preflight() {
    step "Preflight"

    [[ "$(uname -s)" == "Darwin" ]] || die "this only runs on macOS."
    command -v xcodebuild >/dev/null || die "xcodebuild not found. Install Xcode and run: sudo xcode-select -s /Applications/Xcode.app"
    [[ -d "$PROJECT" ]] || die "$PROJECT not found — run this from anywhere, but the repo must be intact."

    info "$(xcodebuild -version | tr '\n' ' ')"

    # AirBattery calls SwiftUI's glassEffect(), which exists only in the macOS 26 SDK. Catching
    # that here turns a wall of compile errors into one sentence.
    if ! xcodebuild -showsdks 2>/dev/null | grep -q "macosx26"; then
        die "no macOS 26 SDK in the selected Xcode. AirBattery uses glassEffect(), which needs Xcode 26.
       Selected: $(xcode-select -p)
       Switch with: sudo xcode-select -s /Applications/Xcode-26.app"
    fi
}

# ---------------------------------------------------------------------------- signing

# Fills IDENTITY / TEAM_ID / SIGN_ARGS. Ad-hoc and Developer ID are genuinely different builds,
# not just a different -sign flag:
#
# Hardened runtime enables Library Validation, which requires every embedded framework to carry
# the same Team ID as the host process. An ad-hoc signature carries NO Team ID on either side, so
# the match can never succeed and dyld refuses to map Sparkle.framework — the app dies before
# main() with "different Team IDs". Hence ENABLE_HARDENED_RUNTIME=NO on the ad-hoc path only.
# It must stay ON for anything notarized: notarization rejects submissions without it, and a real
# Team ID on both sides satisfies Library Validation anyway.
resolve_signing() {
    step "Signing"

    if [[ "$IDENTITY" == "auto" ]]; then
        local found
        found=$(security find-identity -v -p codesigning 2>/dev/null \
                | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)".*/\1/' || true)
        if [[ -n "$found" ]]; then
            IDENTITY="$found"
        else
            IDENTITY="-"
        fi
    fi

    if [[ "$IDENTITY" == "-" ]]; then
        [[ -z "$NOTARY_PROFILE" ]] || die "--notarize needs a Developer ID Application certificate; none is installed.
       Ad-hoc signatures cannot be notarized. Import the certificate, or drop --notarize."

        SIGNING_MODE="ad-hoc"
        SIGN_ARGS=(
            CODE_SIGN_IDENTITY="-"
            CODE_SIGNING_REQUIRED=NO
            CODE_SIGNING_ALLOWED=YES
            CODE_SIGN_STYLE=Manual
            DEVELOPMENT_TEAM=""
            PROVISIONING_PROFILE_SPECIFIER=""
            ENABLE_HARDENED_RUNTIME=NO
        )
        warn "no Developer ID Application certificate — building AD-HOC."
        info "The DMG will open on this Mac only. Others need: xattr -dr com.apple.quarantine /Applications/AirBattery.app"
    else
        # "Developer ID Application: Name (TEAMID)" -> TEAMID
        if [[ -z "$TEAM_ID" && "$IDENTITY" =~ \(([A-Z0-9]{10})\)$ ]]; then
            TEAM_ID="${BASH_REMATCH[1]}"
        fi
        [[ -n "$TEAM_ID" ]] || die "could not parse a Team ID out of '$IDENTITY'. Pass it with --team <id>."

        SIGNING_MODE="Developer ID ($TEAM_ID)"
        SIGN_ARGS=(
            CODE_SIGN_IDENTITY="$IDENTITY"
            CODE_SIGNING_REQUIRED=YES
            CODE_SIGNING_ALLOWED=YES
            CODE_SIGN_STYLE=Manual
            DEVELOPMENT_TEAM="$TEAM_ID"
        )   # hardened runtime stays at the project's YES — notarization requires it
        info "identity: $IDENTITY"
    fi

    info "mode: $SIGNING_MODE"
}

# ---------------------------------------------------------------------------- build

build_app() {
    step "Building $SCHEME ($CONFIGURATION)"

    mkdir -p "$OUTPUT_DIR"
    local log="$OUTPUT_DIR/build.log"

    # Sparkle / MultipeerKit / swift-argument-parser are resolved over the network on a cold
    # derived-data path; the first run is slow and needs a connection.
    set +e
    if command -v xcbeautify >/dev/null; then
        xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIGURATION" \
            -derivedDataPath "$DERIVED_DATA" "${SIGN_ARGS[@]}" build 2>&1 | tee "$log" | xcbeautify
    else
        xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIGURATION" \
            -derivedDataPath "$DERIVED_DATA" "${SIGN_ARGS[@]}" build 2>&1 | tee "$log"
    fi
    local status=${PIPESTATUS[0]}
    set -e

    [[ $status -eq 0 ]] || die "build failed (exit $status). Full log: $log"
}

# ---------------------------------------------------------------------------- verify

# The helper, widget extension and CLI tool are embedded through build phases rather than built by
# the shared scheme directly, so check they are actually in the bundle instead of shipping a DMG
# whose login item or widget is silently missing.
verify_bundle() {
    step "Verifying bundle"

    [[ -d "$APP" ]] || die "no app at $APP — run without --skip-build."

    codesign --verify --deep --strict "$APP" || die "codesign verification failed."
    info "signature: ok"
    info "archs: $(lipo -archs "$APP/Contents/MacOS/AirBattery")"

    [[ -d "$APP/Contents/PlugIns/AirBatteryWidgetExtension.appex" ]] || die "widget extension missing from bundle."
    [[ -d "$APP/Contents/Library/LoginItems/AirBatteryHelper.app" ]] || die "AirBatteryHelper login item missing from bundle."
    [[ -x "$APP/Contents/Resources/logReader.sh" ]] || die "logReader.sh missing or not executable in bundle."
    [[ -d "$APP/Contents/Frameworks/Sparkle.framework" ]] || die "Sparkle.framework missing from bundle."
    info "embedded: widget, login item, logReader.sh, Sparkle.framework"

    # `codesign --verify` passes on a bundle that cannot launch: it checks that signatures are
    # well-formed, while Library Validation is a load-time policy dyld applies only at startup.
    # A hardened-runtime + ad-hoc DMG once shipped green through CI for exactly that reason, so
    # check the two conditions that produce it, statically.
    local flags team sparkle_team
    flags=$(codesign -d --verbose=2 "$APP" 2>&1 | sed -n 's/.*flags=\([^ ]*\).*/\1/p')
    team=$(codesign -dvvv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')

    if [[ "$flags" == *runtime* && ( -z "$team" || "$team" == "not set" ) ]]; then
        die "hardened runtime is on but the bundle has no Team ID (ad-hoc signature).
       dyld will refuse to map Sparkle.framework and the app dies before main().
       Build ad-hoc (ENABLE_HARDENED_RUNTIME=NO) or sign with a Developer ID."
    fi

    sparkle_team=$(codesign -dvvv "$APP/Contents/Frameworks/Sparkle.framework" 2>&1 | sed -n 's/^TeamIdentifier=//p')
    if [[ -n "$team" && "$team" != "not set" && "$team" != "$sparkle_team" ]]; then
        die "Team ID mismatch: app=$team, Sparkle.framework=$sparkle_team.
       Library Validation rejects this at launch. Re-sign inside-out: frameworks, then appex and
       login item, then the outer .app."
    fi
    info "team: ${team:-none (ad-hoc)}   hardened runtime: $([[ "$flags" == *runtime* ]] && echo yes || echo no)"
}

# Opt-in, because it starts a real second AirBattery instance. Fails hard only on a dynamic-linking
# failure — a menu bar app can exit early for unrelated reasons, which shouldn't fail the build.
smoke_test() {
    step "Smoke test (10s launch)"

    local log pid
    log=$(mktemp)
    "$APP/Contents/MacOS/AirBattery" >"$log" 2>&1 &
    pid=$!
    sleep 10

    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        info "stayed up for 10s — embedded frameworks loaded."
        rm -f "$log"
        return 0
    fi

    wait "$pid" 2>/dev/null || true
    if grep -q "Library not loaded\|different Team IDs\|code signature.*not valid" "$log"; then
        cat "$log" >&2
        rm -f "$log"
        die "app died at launch: dyld refused an embedded framework (see output above)."
    fi

    warn "app exited early, but not from a dynamic-linking failure. Output:"
    cat "$log" >&2
    rm -f "$log"
}

# ---------------------------------------------------------------------------- package

package_dmg() {
    VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
    DMG="$OUTPUT_DIR/AirBattery-$VERSION.dmg"

    step "Packaging AirBattery-$VERSION.dmg"

    mkdir -p "$OUTPUT_DIR"
    STAGE=$(mktemp -d)
    trap 'rm -rf "$STAGE"' EXIT

    ditto "$APP" "$STAGE/AirBattery.app"        # ditto, not cp: preserves the signature and xattrs
    ln -s /Applications "$STAGE/Applications"

    rm -f "$DMG"
    hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

    rm -rf "$STAGE"
    trap - EXIT

    # Signing the DMG itself is separate from signing the app inside it, and notarytool wants it.
    if [[ "$IDENTITY" != "-" ]]; then
        codesign --force --sign "$IDENTITY" --timestamp "$DMG"
        info "DMG signed with $IDENTITY"
    fi
}

notarize_dmg() {
    step "Notarizing (profile: $NOTARY_PROFILE)"

    # --wait blocks until Apple returns a verdict; typically a minute or two.
    if ! xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait; then
        die "notarization failed. Get the reasons — the summary rarely says enough:
       xcrun notarytool log <submission-id> --keychain-profile $NOTARY_PROFILE"
    fi

    xcrun stapler staple "$DMG"                 # staples the ticket so first launch works offline
    spctl -a -t open --context context:primary-signature -vvv "$DMG"
    info "notarized and stapled."
}

# ---------------------------------------------------------------------------- run

preflight
resolve_signing
if [[ $DO_BUILD -eq 1 ]]; then build_app; fi
verify_bundle
if [[ $DO_SMOKE -eq 1 ]]; then smoke_test; fi
package_dmg
if [[ -n "$NOTARY_PROFILE" ]]; then notarize_dmg; fi

step "Done"
info "${BOLD}$DMG${RESET}"
info "version: $VERSION   size: $(du -h "$DMG" | cut -f1)   signing: $SIGNING_MODE"
info "sha256:  $(shasum -a 256 "$DMG" | cut -d' ' -f1)"

if [[ "$IDENTITY" == "-" ]]; then
    printf '\n%sThis DMG is ad-hoc signed.%s Anyone who did not build it must run, after copying to /Applications:\n' "$YELLOW" "$RESET"
    printf '    %sxattr -dr com.apple.quarantine /Applications/AirBattery.app%s\n' "$DIM" "$RESET"
elif [[ -z "$NOTARY_PROFILE" ]]; then
    printf '\n%sSigned but not notarized.%s Gatekeeper still blocks it on other Macs — add --notarize <profile>.\n' "$YELLOW" "$RESET"
else
    printf '\nSparkle updates are signed with a %sseparate%s EdDSA key: run Sparkle'"'"'s `sign_update %s`\nand paste the result into appcast.xml. Code signing does not cover the update feed.\n' "$BOLD" "$RESET" "$DMG"
fi
