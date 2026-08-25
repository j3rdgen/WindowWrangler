#!/usr/bin/env bash
#
# release.sh — Window Wrangler Developer ID release pipeline (offline half)
#
# What this does, in order, exiting nonzero on any failure:
#   1. Sanity-check both Developer ID certificates are installed.
#   2. Verify the working tree is clean (no accidental mid-build edits).
#   3. `xcodebuild archive` → produce a .xcarchive with real Developer ID
#      Application signing and Hardened Runtime.
#   4. `xcodebuild -exportArchive` → export the notarization-ready .app.
#      Xcode's export flow strips get-task-allow automatically.
#   5. Re-verify the exported .app with codesign: signature valid,
#      Developer ID authority, Team ID, Hardened Runtime, secure
#      timestamp, apple-events entitlement, no app-sandbox, no
#      get-task-allow, no unauthorized Hardened Runtime exceptions.
#   6. Build a DMG containing the .app + Applications symlink, sign it
#      with Developer ID Application (NOT Installer), verify.
#   7. Build a component PKG installing the .app to /Applications, sign
#      it with Developer ID Installer, verify via pkgutil.
#   8. Emit dist/checksums.txt and dist/release-verification.txt.
#
# Notarization + stapling live in the sibling notarize.sh — this
# script produces artifacts that ARE READY for notarization but does
# not submit them.
#
# Repeatability: same inputs (git commit, cert install state) produce
# the same signed artifacts. Downstream consumers care about the
# artifact bytes; SHA-256 makes that verifiable.
#
# NEVER embeds credentials. notarytool auth is a Keychain profile set
# up separately by the user.
#

set -euo pipefail

# ------------------------------------------------------------
# Configuration
# ------------------------------------------------------------

# Values baked in for THIS project. If the enrolled Apple Developer
# organization ever changes, the Team ID / name below must be updated
# together — codesign / notarytool / PPPC all key off these.
readonly TEAM_ID="7V4AJFNJKM"
readonly ORG_NAME="Northstar-Purpose Enterprises LLC"
readonly APPLICATION_IDENTITY="Developer ID Application: ${ORG_NAME} (${TEAM_ID})"
readonly INSTALLER_IDENTITY="Developer ID Installer: ${ORG_NAME} (${TEAM_ID})"

readonly BUNDLE_ID="com.jmw3.WindowWrangler"
readonly APP_NAME="Window Wrangler"

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly XCODEPROJ="${REPO_ROOT}/WindowFanWrangler/WindowFanWrangler.xcodeproj"
readonly SCHEME="WindowFanWrangler"

readonly DIST_DIR="${REPO_ROOT}/dist"
readonly BUILD_DIR="${DIST_DIR}/.build"
readonly ARCHIVE_PATH="${BUILD_DIR}/${APP_NAME}.xcarchive"
readonly EXPORT_DIR="${BUILD_DIR}/export"
readonly EXPORTED_APP="${EXPORT_DIR}/${APP_NAME}.app"
readonly EXPORT_OPTIONS_PLIST="${BUILD_DIR}/ExportOptions.plist"

# Version pulled from the .app's Info.plist at packaging time (after
# archive builds so this reflects whatever Xcode wrote).
VERSION=""
BUILD_NUMBER=""
DMG_PATH=""
PKG_PATH=""

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------

log() { printf "\033[1;34m[release]\033[0m %s\n" "$*"; }
fail() { printf "\033[1;31m[release ERROR]\033[0m %s\n" "$*" >&2; exit 1; }

require_cert() {
    local expected="$1"
    if ! security find-identity -v | grep -q "\"${expected}\""; then
        fail "Missing signing identity: ${expected}
Install via Xcode → Settings → Accounts → Manage Certificates,
or download from developer.apple.com/account/resources/certificates."
    fi
}

# ------------------------------------------------------------
# Steps
# ------------------------------------------------------------

check_certs() {
    log "Verifying Developer ID certificates…"
    require_cert "${APPLICATION_IDENTITY}"
    require_cert "${INSTALLER_IDENTITY}"
    log "Both certs found (Team ID ${TEAM_ID})."
}

check_clean_tree() {
    log "Verifying git tree is clean (no uncommitted TRACKED changes)…"
    # `git diff-index HEAD --` catches modifications to tracked files
    # (staged or unstaged) but ignores untracked files. That's the
    # distinction that matters for a release: mid-edit changes to code
    # would ship an unknown snapshot, whereas untracked scratch or
    # scripts-in-development are normal working-tree noise.
    if ! git -C "${REPO_ROOT}" diff-index --quiet HEAD --; then
        fail "Working tree has uncommitted TRACKED changes. Commit or stash before releasing.
$(git -C "${REPO_ROOT}" status --short)"
    fi
    local commit
    commit="$(git -C "${REPO_ROOT}" rev-parse --short HEAD)"
    log "On commit ${commit}."
}

prepare_dirs() {
    log "Preparing build + dist directories…"
    rm -rf "${BUILD_DIR}"
    mkdir -p "${BUILD_DIR}" "${EXPORT_DIR}" "${DIST_DIR}"
}

write_export_options() {
    # Standard Developer ID export configuration. `signingStyle=manual`
    # + `signingCertificate` guarantees Xcode uses the exact Developer
    # ID Application identity — no accidental fall-through to Apple
    # Development / ad-hoc.
    cat > "${EXPORT_OPTIONS_PLIST}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>${TEAM_ID}</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>${APPLICATION_IDENTITY}</string>
    <key>destination</key>
    <string>export</string>
</dict>
</plist>
PLIST
}

archive_app() {
    log "Building xcarchive (Release, Developer ID)…"
    xcodebuild \
        -project "${XCODEPROJ}" \
        -scheme "${SCHEME}" \
        -configuration Release \
        -destination "generic/platform=macOS" \
        -archivePath "${ARCHIVE_PATH}" \
        CODE_SIGN_STYLE=Manual \
        DEVELOPMENT_TEAM="${TEAM_ID}" \
        CODE_SIGN_IDENTITY="${APPLICATION_IDENTITY}" \
        archive \
        2>&1 | tail -30
    [[ -d "${ARCHIVE_PATH}" ]] || fail "Archive not produced at ${ARCHIVE_PATH}"
    log "Archive complete."
}

export_archive() {
    log "Exporting archive to signed .app…"
    xcodebuild \
        -exportArchive \
        -archivePath "${ARCHIVE_PATH}" \
        -exportPath "${EXPORT_DIR}" \
        -exportOptionsPlist "${EXPORT_OPTIONS_PLIST}" \
        2>&1 | tail -20
    [[ -d "${EXPORTED_APP}" ]] || fail "Exported .app not found at ${EXPORTED_APP}"
    log "Export complete."

    # Pull marketing version + build number from the exported Info.plist.
    # These drive artifact filenames + the verification report.
    VERSION="$(defaults read "${EXPORTED_APP}/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "0.0")"
    BUILD_NUMBER="$(defaults read "${EXPORTED_APP}/Contents/Info" CFBundleVersion 2>/dev/null || echo "0")"
    log "Version ${VERSION} (build ${BUILD_NUMBER})."
}

verify_app() {
    log "Verifying signed .app…"
    codesign --verify --deep --strict --verbose=4 "${EXPORTED_APP}" \
        || fail "codesign --verify failed on ${EXPORTED_APP}"

    local sig_info
    sig_info="$(codesign -dv --verbose=4 "${EXPORTED_APP}" 2>&1)"
    echo "${sig_info}" | grep -q "TeamIdentifier=${TEAM_ID}" \
        || fail "Team ID mismatch. Expected ${TEAM_ID}. Got:
${sig_info}"
    # Developer ID signing = Authority chain includes the DevID cert AND
    # signature is not adhoc. codesign's `-dv` prints Authority lines
    # for each cert in the trust chain; ad-hoc omits Authority entirely
    # and prints `Signature=adhoc`.
    if echo "${sig_info}" | grep -q "Signature=adhoc"; then
        fail "Signature is ad-hoc, not Developer ID:
${sig_info}"
    fi
    echo "${sig_info}" | grep -q "Authority=Developer ID Application:" \
        || fail "Missing Developer ID Application authority in chain:
${sig_info}"
    # Hardened Runtime shows as either `flags=0x10000(runtime)` alone or
    # `flags=0x...NNNN(...,runtime)` combined with other bits.
    echo "${sig_info}" | grep -qE "flags=0x[0-9a-f]+\([^)]*runtime[^)]*\)" \
        || fail "Hardened Runtime not enabled:
${sig_info}"
    echo "${sig_info}" | grep -q "Timestamp=" \
        || fail "Secure timestamp missing (need internet during archive):
${sig_info}"

    local ent
    ent="$(codesign -d --entitlements :- "${EXPORTED_APP}" 2>/dev/null)"
    echo "${ent}" | grep -q "com.apple.security.automation.apple-events" \
        || fail "apple-events entitlement missing from signed .app"
    if echo "${ent}" | grep -q "com.apple.security.app-sandbox"; then
        fail "app-sandbox entitlement present — must NOT ship."
    fi
    if echo "${ent}" | grep -qE "com.apple.security.get-task-allow.*true"; then
        fail "get-task-allow present — Xcode export should have stripped this."
    fi
    # Runtime-exception entitlements we do NOT want in production.
    for danger in "cs.disable-library-validation" "cs.allow-jit" \
                  "cs.allow-unsigned-executable-memory" \
                  "cs.allow-dyld-environment-variables" \
                  "cs.disable-executable-page-protection"; do
        if echo "${ent}" | grep -q "com.apple.security.${danger}"; then
            fail "Unauthorized Hardened Runtime exception: ${danger}"
        fi
    done
    log "Signed .app verified."
}

build_dmg() {
    DMG_PATH="${DIST_DIR}/WindowWrangler-${VERSION}.dmg"
    local staging="${BUILD_DIR}/dmg-staging"
    log "Building DMG at ${DMG_PATH}…"
    rm -rf "${staging}" "${DMG_PATH}"
    mkdir -p "${staging}"
    # cp -R preserves the codesigned .app bit-for-bit (ditto is
    # equivalent; either works). Do NOT re-touch the .app after this.
    cp -R "${EXPORTED_APP}" "${staging}/"
    ln -s /Applications "${staging}/Applications"
    hdiutil create \
        -volname "${APP_NAME}" \
        -srcfolder "${staging}" \
        -ov \
        -format UDZO \
        "${DMG_PATH}" \
        > /dev/null

    log "Signing DMG with Developer ID Application…"
    codesign --sign "${APPLICATION_IDENTITY}" --timestamp "${DMG_PATH}"
    codesign --verify --verbose=2 "${DMG_PATH}" \
        || fail "DMG signature invalid"
    log "DMG built + signed."
}

build_pkg() {
    PKG_PATH="${DIST_DIR}/WindowWrangler-${VERSION}.pkg"
    log "Building PKG at ${PKG_PATH}…"
    local component_pkg="${BUILD_DIR}/component.pkg"
    rm -f "${component_pkg}" "${PKG_PATH}"

    # Component package: the .app installs to /Applications with its
    # bundle ID + version.
    pkgbuild \
        --component "${EXPORTED_APP}" \
        --install-location /Applications \
        --identifier "${BUNDLE_ID}" \
        --version "${VERSION}" \
        "${component_pkg}" \
        > /dev/null

    # productbuild wraps it into the final signed installer. We do NOT
    # re-sign the embedded .app here — pkgbuild + productbuild preserve
    # the existing Developer ID Application signature untouched.
    productbuild \
        --package "${component_pkg}" \
        --sign "${INSTALLER_IDENTITY}" \
        --timestamp \
        "${PKG_PATH}" \
        > /dev/null

    log "Verifying PKG signature…"
    pkgutil --check-signature "${PKG_PATH}" | grep -q "Developer ID Installer" \
        || fail "PKG signature check failed"
    log "PKG built + signed."
}

write_release_report() {
    local checksums="${DIST_DIR}/checksums.txt"
    local report="${DIST_DIR}/release-verification.txt"
    local git_commit
    git_commit="$(git -C "${REPO_ROOT}" rev-parse HEAD)"
    local git_short
    git_short="$(git -C "${REPO_ROOT}" rev-parse --short HEAD)"

    log "Writing checksums…"
    (
        cd "${DIST_DIR}"
        shasum -a 256 "$(basename "${DMG_PATH}")" "$(basename "${PKG_PATH}")" > "${checksums}"
    )

    log "Writing release-verification report…"
    local app_dr
    app_dr="$(codesign -dr - "${EXPORTED_APP}" 2>&1 | tr '\n' ' ' | sed 's/^.*=> //')"
    {
        printf "Window Wrangler release verification\n"
        printf "=====================================\n\n"
        printf "Version:                %s\n" "${VERSION}"
        printf "Build:                  %s\n" "${BUILD_NUMBER}"
        printf "Bundle ID:              %s\n" "${BUNDLE_ID}"
        printf "Git commit:             %s (%s)\n" "${git_commit}" "${git_short}"
        printf "Team ID:                %s\n" "${TEAM_ID}"
        printf "Organization:           %s\n" "${ORG_NAME}"
        printf "Application identity:   %s\n" "${APPLICATION_IDENTITY}"
        printf "Installer identity:     %s\n" "${INSTALLER_IDENTITY}"
        printf "\nSHA-256\n-------\n"
        cat "${checksums}"
        printf "\nDesignated requirement (for PPPC)\n---------------------------------\n"
        printf "%s\n" "${app_dr}"
        printf "\nNotarization\n------------\n"
        printf "See notarize.sh output. Not run by release.sh.\n"
    } > "${report}"

    log "Report written to ${report}."
}

# ------------------------------------------------------------
# Main
# ------------------------------------------------------------

main() {
    log "Starting Window Wrangler release build."
    check_certs
    check_clean_tree
    prepare_dirs
    write_export_options
    archive_app
    export_archive
    verify_app
    build_dmg
    build_pkg
    write_release_report
    log "DONE. Artifacts in ${DIST_DIR}. Next: run scripts/notarize.sh."
}

main "$@"
