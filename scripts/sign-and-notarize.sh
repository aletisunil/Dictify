#!/usr/bin/env bash
# Sign, notarize, and staple a Dictify .app (and optionally a .dmg).
#
# Required env vars:
#   DEVELOPER_ID_APPLICATION  Full name of the Developer ID Application identity,
#                             e.g. "Developer ID Application: Sunil Aleti (TEAMID)".
#                             If unset, the script runs ad-hoc sign only and skips notarization.
#   NOTARY_PROFILE            Keychain profile name set via:
#                             `xcrun notarytool store-credentials <profile> --apple-id ... --team-id ... --password ...`
#                             Required for notarization.
#
# Optional:
#   ENTITLEMENTS_PATH         Defaults to Dictify/Dictify.entitlements.
#   SKIP_NOTARIZE             If "1", sign only (still uses hardened runtime + timestamp). Useful for local smoke tests.
#
# Usage:
#   sign-and-notarize.sh app <path-to-Dictify.app>
#   sign-and-notarize.sh dmg <path-to-Dictify.dmg>
#
# Exit status is non-zero on any signing/notarization failure.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENTITLEMENTS_PATH="${ENTITLEMENTS_PATH:-$ROOT_DIR/Dictify/Dictify.entitlements}"
SKIP_NOTARIZE="${SKIP_NOTARIZE:-0}"

log() { printf '[sign] %s\n' "$*"; }
warn() { printf '[sign] WARNING: %s\n' "$*" >&2; }
die() { printf '[sign] ERROR: %s\n' "$*" >&2; exit 1; }

identity_or_adhoc() {
  if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
    printf '%s' "$DEVELOPER_ID_APPLICATION"
  else
    printf '%s' "-"
  fi
}

require_notary_creds() {
  [[ -n "${NOTARY_PROFILE:-}" ]] || die "NOTARY_PROFILE is required for notarization. Set up via: xcrun notarytool store-credentials"
}

prepared_entitlements() {
  local source_path="$1"
  local prepared_path="$2"

  cp "$source_path" "$prepared_path"

  printf '%s' "$prepared_path"
}

# Sign one nested item (bundle or Mach-O) with hardened runtime. Entitlements
# the item already carries (e.g. a sandboxed XPC service) are preserved - a
# plain re-sign would strip them. Uses $identity from the calling scope.
sign_item() {
  local item="$1" preserve=""
  if codesign -d --entitlements - "$item" 2>/dev/null | grep -q .; then
    preserve="--preserve-metadata=entitlements"
  fi
  codesign --force --options runtime --timestamp ${preserve:+$preserve} \
    --sign "$identity" "$item"
}

sign_app() {
  local app_path="$1"
  [[ -d "$app_path" ]] || die "App bundle not found: $app_path"
  [[ -f "$ENTITLEMENTS_PATH" ]] || die "Entitlements not found: $ENTITLEMENTS_PATH"

  local identity
  identity="$(identity_or_adhoc)"

  if [[ "$identity" == "-" ]]; then
    warn "DEVELOPER_ID_APPLICATION not set — performing ad-hoc sign (Gatekeeper will reject on other Macs)."
  else
    log "Signing with identity: $identity"
  fi

  local prepared_entitlements_path
  # macOS mktemp only expands the XXXXXX placeholder at the end of the template.
  prepared_entitlements_path="$(mktemp "${TMPDIR:-/tmp}/DictifyEntitlements.XXXXXX")"
  trap 'rm -f "${prepared_entitlements_path:-}"' RETURN
  prepared_entitlements_path="$(prepared_entitlements "$ENTITLEMENTS_PATH" "$prepared_entitlements_path")"

  # Deep sign all nested code inside-out. Sign leaves first (--deep alone is
  # unreliable for nested content), then the app wrapper. `find -d` walks
  # depth-first so nested bundles are signed before the bundle that contains
  # them. Matching bare executables (-type f -perm -111, filtered to Mach-O
  # below) covers helper tools that live loose inside frameworks - e.g.
  # Sparkle's Autoupdate and Updater.app - without hardcoding any framework's
  # internal layout.
  find -d "$app_path/Contents" \
    \( -name "*.dylib" -o -name "*.framework" -o -name "*.bundle" \
       -o -name "*.xpc" -o -name "*.app" -o \( -type f -perm -111 \) \) \
    -print 2>/dev/null | while IFS= read -r item; do
    # The main executable is sealed by the final app-wrapper sign.
    [[ "$item" == "$app_path/Contents/MacOS/"* ]] && continue
    # Plain executable files must be Mach-O; skip scripts and other resources.
    if [[ -f "$item" && "$item" != *.dylib ]]; then
      file -b "$item" | grep -q "Mach-O" || continue
    fi
    log "  sign nested: $(basename "$item")"
    sign_item "$item"
  done

  log "Signing main bundle"
  codesign --force --options runtime --timestamp \
    --entitlements "$prepared_entitlements_path" \
    --sign "$identity" \
    "$app_path"

  log "Verifying signature"
  codesign --verify --deep --strict --verbose=2 "$app_path"

  if [[ "$identity" != "-" ]]; then
    log "Checking hardened runtime flag"
    local signature_details
    signature_details="$(codesign -dv --verbose=4 "$app_path" 2>&1)"
    if ! grep -Eq "Runtime Version|\\(.*runtime.*\\)" <<<"$signature_details"; then
      printf '%s\n' "$signature_details" >&2
      die "Hardened runtime flag missing on signed app"
    fi
  fi

  rm -f "$prepared_entitlements_path"
  trap - RETURN
}

notarize_and_staple() {
  local target_path="$1"
  local kind="$2"  # "app" or "dmg"

  if [[ "$SKIP_NOTARIZE" == "1" ]]; then
    warn "SKIP_NOTARIZE=1 — skipping notarization for $target_path"
    return 0
  fi

  if [[ -z "${DEVELOPER_ID_APPLICATION:-}" ]]; then
    warn "Ad-hoc signed — skipping notarization (requires Developer ID)."
    return 0
  fi

  require_notary_creds

  local submit_target="$target_path"
  local cleanup_zip=""

  if [[ "$kind" == "app" ]]; then
    # notarytool accepts .zip/.dmg/.pkg — not raw .app bundles.
    submit_target="$(mktemp -u "/tmp/DictifyNotarize.XXXXXX").zip"
    log "Zipping app for notarization: $submit_target"
    /usr/bin/ditto -c -k --keepParent "$target_path" "$submit_target"
    cleanup_zip="$submit_target"
  fi

  log "Submitting to Apple notarization (this can take several minutes)"
  if ! xcrun notarytool submit "$submit_target" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait; then
    [[ -n "$cleanup_zip" ]] && rm -f "$cleanup_zip"
    die "Notarization submission failed"
  fi

  [[ -n "$cleanup_zip" ]] && rm -f "$cleanup_zip"

  log "Stapling ticket to $target_path"
  xcrun stapler staple "$target_path"

  log "Validating staple"
  xcrun stapler validate "$target_path"
  if [[ "$kind" == "dmg" ]]; then
    spctl --assess --type open --context context:primary-signature --verbose=4 "$target_path" || \
      warn "spctl assessment reported non-zero (this can be non-fatal for DMGs)"
  else
    spctl --assess --type execute --verbose=4 "$target_path" || \
      warn "spctl assessment reported non-zero"
  fi
}

main() {
  local kind="${1:-}"
  local target="${2:-}"

  [[ -n "$kind" && -n "$target" ]] || die "Usage: $0 {app|dmg} <path>"

  case "$kind" in
    app)
      sign_app "$target"
      notarize_and_staple "$target" app
      ;;
    dmg)
      if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
        log "Signing DMG"
        codesign --force --timestamp \
          --sign "$DEVELOPER_ID_APPLICATION" \
          "$target"
      else
        warn "DEVELOPER_ID_APPLICATION not set — DMG will be ad-hoc signed only."
        codesign --force --sign "-" "$target"
      fi
      notarize_and_staple "$target" dmg
      ;;
    *)
      die "Unknown kind: $kind (expected 'app' or 'dmg')"
      ;;
  esac
}

main "$@"
