#!/usr/bin/env bash
#
# notarize.sh — submit release.sh's DMG + PKG to Apple's notary
# service, staple the returned tickets, verify with Gatekeeper.
#
# Requires ONE-TIME setup by the user, out-of-band from this script:
#
#   xcrun notarytool store-credentials "window-wrangler-notary" \
#     --apple-id "your.email@example.com" \
#     --team-id "7V4AJFNJKM" \
#     --password "<app-specific password>"
#
# That stores the app-specific password in the user's login keychain
# under the profile name "window-wrangler-notary". Nothing about the
# password ever reaches this script or the repo.
#
# The profile name is fixed as a constant below; changing it means
# updating the setup command too. Kept fixed on purpose — one canonical
# name across every release.
#

set -euo pipefail

readonly PROFILE_NAME="window-wrangler-notary"
readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly DIST_DIR="${REPO_ROOT}/dist"

log() { printf "\033[1;34m[notarize]\033[0m %s\n" "$*"; }
fail() { printf "\033[1;31m[notarize ERROR]\033[0m %s\n" "$*" >&2; exit 1; }

# Look up latest artifacts in dist/. release.sh always emits the same
# WindowWrangler-<version>.{dmg,pkg} filename shape.
find_artifact() {
    local ext="$1"
    local match
    match="$(find "${DIST_DIR}" -maxdepth 1 -name "WindowWrangler-*.${ext}" | sort | tail -1)"
    [[ -n "${match}" ]] || fail "No WindowWrangler-*.${ext} found in ${DIST_DIR}. Run release.sh first."
    echo "${match}"
}

check_profile() {
    log "Checking notarytool keychain profile '${PROFILE_NAME}'…"
    # `xcrun notarytool history --keychain-profile <name>` returns
    # exit 0 quickly if the profile exists (even with zero prior
    # submissions), fails otherwise. Cheaper than probing with an
    # actual submission.
    if ! xcrun notarytool history --keychain-profile "${PROFILE_NAME}" > /dev/null 2>&1; then
        fail "Keychain profile '${PROFILE_NAME}' not found.
Set it up once with:
  xcrun notarytool store-credentials \"${PROFILE_NAME}\" \\
    --apple-id \"your.email@example.com\" \\
    --team-id \"7V4AJFNJKM\" \\
    --password \"<app-specific password from appleid.apple.com>\""
    fi
    log "Profile OK."
}

notarize_and_staple() {
    local artifact="$1"
    log "Submitting $(basename "${artifact}") to Apple notary…"
    # --wait blocks until Apple returns Accepted / Invalid / other.
    # Prints the returned submission ID + status; if we ever want the
    # submission log, `xcrun notarytool log <id> --keychain-profile
    # <name>` retrieves it separately.
    local output status
    output="$(xcrun notarytool submit "${artifact}" \
        --keychain-profile "${PROFILE_NAME}" \
        --wait 2>&1)"
    echo "${output}"
    status="$(echo "${output}" | grep -E "^\s*status:" | tail -1 | awk '{print $2}')"
    if [[ "${status}" != "Accepted" ]]; then
        local sub_id
        sub_id="$(echo "${output}" | grep -E "^\s*id:" | head -1 | awk '{print $2}')"
        if [[ -n "${sub_id}" ]]; then
            log "Fetching notarization log for failed submission ${sub_id}…"
            xcrun notarytool log "${sub_id}" \
                --keychain-profile "${PROFILE_NAME}" || true
        fi
        fail "Notarization NOT accepted for $(basename "${artifact}") (status: ${status:-unknown})"
    fi

    log "Stapling ticket to $(basename "${artifact}")…"
    xcrun stapler staple "${artifact}" \
        || fail "stapler staple failed on $(basename "${artifact}")"
    xcrun stapler validate "${artifact}" \
        || fail "stapler validate failed on $(basename "${artifact}")"
    log "$(basename "${artifact}") notarized + stapled."
}

verify_gatekeeper() {
    local dmg="$1"
    local pkg="$2"

    log "Gatekeeper verification…"

    # DMG assessment. `--context context:primary-signature` forces
    # spctl to evaluate the DMG's own signature, not just its contents.
    if ! spctl -a -t open -vvv --context context:primary-signature "${dmg}" 2>&1; then
        fail "spctl rejected DMG"
    fi

    # PKG assessment.
    if ! spctl -a -t install -vvv "${pkg}" 2>&1; then
        fail "spctl rejected PKG"
    fi

    # PKG signature identity — belt-and-suspenders since spctl doesn't
    # always report the signing chain in its exit code.
    if ! pkgutil --check-signature "${pkg}" 2>&1 | tee /dev/stderr | grep -q "Developer ID Installer"; then
        fail "pkgutil could not confirm Developer ID Installer signature"
    fi

    log "Gatekeeper OK on DMG + PKG."
}

verify_app_inside_dmg() {
    local dmg="$1"
    log "Mounting DMG to verify contained .app…"
    local mount_output
    mount_output="$(hdiutil attach -readonly -nobrowse -plist "${dmg}")"
    # The mount point comes back inside the plist; parse the first
    # /Volumes/... path.
    local mount_point
    mount_point="$(echo "${mount_output}" | grep -A1 "<key>mount-point</key>" | grep "<string>/Volumes" | head -1 | sed -E 's|.*<string>(.*)</string>.*|\1|')"
    [[ -n "${mount_point}" && -d "${mount_point}" ]] || fail "Could not find DMG mount point"
    local inner_app="${mount_point}/Window Wrangler.app"
    if [[ ! -d "${inner_app}" ]]; then
        hdiutil detach "${mount_point}" > /dev/null || true
        fail "No Window Wrangler.app inside DMG"
    fi
    if ! codesign --verify --deep --strict --verbose=2 "${inner_app}"; then
        hdiutil detach "${mount_point}" > /dev/null || true
        fail "codesign check failed on DMG's inner .app"
    fi
    hdiutil detach "${mount_point}" > /dev/null || true
    log "DMG's inner .app verified."
}

update_release_report() {
    # Append notarization results to release.sh's report so anyone
    # reading dist/release-verification.txt has the full picture.
    local report="${DIST_DIR}/release-verification.txt"
    [[ -f "${report}" ]] || return 0
    log "Appending notarization results to release-verification.txt…"
    {
        printf "\nNotarization (results as of $(date -u +"%Y-%m-%dT%H:%M:%SZ"))\n"
        printf -- "----------------------------------------------\n"
        printf "DMG: notarized + stapled + Gatekeeper OK\n"
        printf "PKG: notarized + stapled + Gatekeeper OK\n"
        printf "Fetch submission logs via:\n"
        printf "  xcrun notarytool history --keychain-profile %s\n" "${PROFILE_NAME}"
    } >> "${report}"
}

main() {
    local dmg pkg
    dmg="$(find_artifact dmg)"
    pkg="$(find_artifact pkg)"

    check_profile
    notarize_and_staple "${dmg}"
    notarize_and_staple "${pkg}"
    verify_gatekeeper "${dmg}" "${pkg}"
    verify_app_inside_dmg "${dmg}"
    update_release_report

    log "DONE. Notarized + stapled + verified:"
    log "  ${dmg}"
    log "  ${pkg}"
}

main "$@"
