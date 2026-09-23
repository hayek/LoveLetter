#!/usr/bin/env bash
set -euo pipefail

# Love Letter — direct-download (website) Mac release, with in-app auto-update.
# Same flow as Zcode's scripts/release.sh (XcodeNeo repo).
#
#   Scripts/release.sh <version> [--no-notarize] [--no-release]
#   Scripts/release.sh 1.1.0
#
# Builds the `direct` distribution flavor (DISTRIBUTION_FLAVOR=direct — the only build that
# self-updates), exports it Developer-ID-signed, notarizes + staples, and produces:
#   dist/LoveLetter-<version>.zip   the auto-updater asset (AppUpdater matches this exact name)
#   dist/LoveLetter-<version>.dmg   the website download
# then publishes a bare-semver GitHub release on hayek/LoveLetter-releases.
#
# App Store builds are NOT made here: archive normally from Xcode — the default flavor is
# `appstore`, which never self-updates.
#
# ── One-time setup ────────────────────────────────────────────────────────────
#   1. "Developer ID Application" certificate in the login keychain.
#   2. The "Love Letter Developer ID" provisioning profile (MAC_APP_DIRECT, needed for the
#      iCloud entitlement) installed — override with EXPORT_PROFILE=….
#   3. A PUBLIC repo hayek/LoveLetter-releases (AppUpdater reads it unauthenticated):
#        gh repo create hayek/LoveLetter-releases --public
#      and `gh auth login` with push access to it.
#   4. Notarization: an App Store Connect API key — read from the active account in
#      ~/.asc/credentials.json + ~/.asc/AuthKey_<keyID>.p8 — or a notarytool keychain profile via NOTARY_PROFILE=….
#
# ── Overrides ─────────────────────────────────────────────────────────────────
#   RELEASES_REPO, EXPORT_PROFILE, TEAM_ID, RELEASE_NOTES
#   ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH   (API-key notarization, the default)
#   NOTARY_PROFILE                              (keychain-profile notarization instead)

die() { echo "error: $*" >&2; exit 1; }
warn() { echo "warn: $*" >&2; }

# ── args ──────────────────────────────────────────────────────────────────────
VERSION="${1:-}"
[[ -n "$VERSION" ]] || die "usage: $0 <version> [--no-notarize] [--no-release]"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version must be bare semver like 1.1.0 (no 'v' prefix)"
shift
NO_NOTARIZE=""; NO_RELEASE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-notarize) NO_NOTARIZE=1; shift ;;
    --no-release)  NO_RELEASE=1;  shift ;;
    *) die "unknown flag: $1" ;;
  esac
done
[[ -n "$NO_NOTARIZE" && -z "$NO_RELEASE" ]] && die "--no-notarize requires --no-release (never publish an un-notarized build)"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

PROJECT="LoveLetter.xcodeproj"
SCHEME="LoveLetter_macOS"
PRODUCT_NAME="LoveLetter"            # the .app / executable name
RELEASE_PREFIX="LoveLetter"          # must match AppUpdateController.releasePrefix
DISPLAY_NAME="Love Letter"
BUNDLE_ID="com.amirhayek.AppFeedback"
TEAM_ID="${TEAM_ID:-Q7U5734Q3T}"
RELEASES_REPO="${RELEASES_REPO:-hayek/LoveLetter-releases}"   # must match AppUpdateController
EXPORT_PROFILE="${EXPORT_PROFILE:-Love Letter Developer ID}"
# API-key notarization defaults come from the active account in the asc CLI's local
# ~/.asc/credentials.json — never from this (public) repo.
asc_cred() {
  local f="$HOME/.asc/credentials.json"
  [[ -f "$f" ]] && command -v jq >/dev/null || return 0
  jq -r --arg k "$1" '.active as $a | .accounts[$a][$k] // empty' "$f" 2>/dev/null || true
}
ASC_KEY_ID="${ASC_KEY_ID:-$(asc_cred keyID)}"
ASC_ISSUER_ID="${ASC_ISSUER_ID:-$(asc_cred issuerID)}"
ASC_KEY_PATH="${ASC_KEY_PATH:-$HOME/.asc/AuthKey_$ASC_KEY_ID.p8}"

BUILD_DIR="$(pwd)/build/release"
ARCHIVE_PATH="$BUILD_DIR/$PRODUCT_NAME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP_PATH="$EXPORT_DIR/$PRODUCT_NAME.app"
DIST_DIR="$(pwd)/dist"
ZIP_PATH="$DIST_DIR/$RELEASE_PREFIX-$VERSION.zip"
DMG_PATH="$DIST_DIR/$RELEASE_PREFIX-$VERSION.dmg"

command -v xcodebuild >/dev/null || die "xcodebuild not found"
[[ -n "$NO_RELEASE" ]] || command -v gh >/dev/null || die "gh CLI not found (or pass --no-release)"
security find-identity -v -p codesigning | grep -q "Developer ID Application" \
  || die "no 'Developer ID Application' certificate in the keychain"
if [[ -z "$NO_RELEASE" ]]; then
  gh repo view "$RELEASES_REPO" >/dev/null 2>&1 \
    || die "$RELEASES_REPO doesn't exist or isn't reachable. Create it once: gh repo create $RELEASES_REPO --public"
fi
if [[ -n "$(git status --porcelain)" ]]; then
  warn "working tree has uncommitted changes — they WILL be in this build."
fi

echo "▸ Releasing $DISPLAY_NAME $VERSION (direct flavor) → $RELEASES_REPO"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
rm -rf "$BUILD_DIR"; mkdir -p "$BUILD_DIR" "$DIST_DIR"
rm -f "$ZIP_PATH" "$DMG_PATH"

# ── version: bump project.yml (source of truth) and the generated pbxproj in step ─
echo "▸ Setting MARKETING_VERSION = $VERSION"
sed -i '' -E "s/^([[:space:]]*MARKETING_VERSION: ).*/\1\"$VERSION\"/" project.yml
grep -q "MARKETING_VERSION: \"$VERSION\"" project.yml || die "failed to bump MARKETING_VERSION in project.yml"
# A targeted pbxproj edit rather than `xcodegen generate`: regenerating can revert committed
# hand-edits to the pbxproj (signing settings) that aren't in project.yml.
sed -i '' -E "s/(MARKETING_VERSION = )[^;]+;/\1$VERSION;/g" "$PROJECT/project.pbxproj"

# ── archive (direct flavor, hardened runtime — notarization rejects without it) ─
echo "▸ Archiving…"
xcodebuild archive \
  -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$ARCHIVE_PATH" \
  -skipPackagePluginValidation \
  DISTRIBUTION_FLAVOR=direct ENABLE_HARDENED_RUNTIME=YES

# ── export Developer-ID signed, manual profile (automatic export can't use cloud certs) ─
echo "▸ Exporting (Developer ID, profile \"$EXPORT_PROFILE\")…"
cat > "$TMP_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
  <key>provisioningProfiles</key>
  <dict><key>$BUNDLE_ID</key><string>$EXPORT_PROFILE</string></dict>
</dict>
</plist>
PLIST
xcodebuild -exportArchive -archivePath "$ARCHIVE_PATH" \
  -exportOptionsPlist "$TMP_DIR/ExportOptions.plist" -exportPath "$EXPORT_DIR"
[[ -d "$APP_PATH" ]] || die "expected app at $APP_PATH"

# ── verify before spending a notarization round-trip ──────────────────────────
codesign --verify --deep --strict "$APP_PATH"
APP_SIG="$(codesign -dvv "$APP_PATH" 2>&1 || true)"
[[ "$APP_SIG" == *"Authority=Developer ID Application"* ]] || die "app is not Developer ID signed"
[[ "$APP_SIG" == *"flags="*"runtime"* ]] || die "app lacks the hardened runtime — notarization would fail"
[[ -f "$APP_PATH/Contents/embedded.provisionprofile" ]] \
  || die "no embedded provisioning profile — the iCloud entitlement would get the app killed at launch"
FLAVOR="$(/usr/libexec/PlistBuddy -c 'Print :LLDistributionFlavor' "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)"
[[ "$FLAVOR" == "direct" ]] || die "built app's LLDistributionFlavor is '$FLAVOR', expected 'direct' — it would never self-update"
BUILT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
[[ "$BUILT_VERSION" == "$VERSION" ]] || die "built app reports version $BUILT_VERSION, expected $VERSION"

# ── notarize ──────────────────────────────────────────────────────────────────
notarize() { # $1 = path to submit
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
  else
    [[ -n "$ASC_KEY_ID" && -n "$ASC_ISSUER_ID" && -f "$ASC_KEY_PATH" ]] \
      || die "no App Store Connect API key (ASC_KEY_ID/ASC_ISSUER_ID/ASC_KEY_PATH or ~/.asc/credentials.json) — or set NOTARY_PROFILE"
    xcrun notarytool submit "$1" --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" --wait
  fi
}

if [[ -z "$NO_NOTARIZE" ]]; then
  echo "▸ Notarizing app…"
  ditto -c -k --keepParent "$APP_PATH" "$TMP_DIR/$PRODUCT_NAME.app.zip"
  notarize "$TMP_DIR/$PRODUCT_NAME.app.zip"
  xcrun stapler staple "$APP_PATH"
  xcrun stapler validate "$APP_PATH"
  spctl --assess --type execute -vv "$APP_PATH"
else
  warn "skipping notarization (local build only)."
fi

# ── package: zip (auto-updater) + dmg (website) ───────────────────────────────
echo "▸ Packaging $(basename "$ZIP_PATH") (auto-updater asset)…"
# --norsrc --noextattr is essential: AppUpdater extracts with /usr/bin/unzip, which would
# otherwise materialize AppleDouble (._*) files that break the code signature.
ditto -c -k --keepParent --norsrc --noextattr "$APP_PATH" "$ZIP_PATH"

echo "▸ Packaging $(basename "$DMG_PATH")…"
STAGING="$TMP_DIR/staging"; mkdir -p "$STAGING"
cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "$DISPLAY_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG_PATH"

if [[ -z "$NO_NOTARIZE" ]]; then
  codesign --force --sign "Developer ID Application" --timestamp "$DMG_PATH"
  echo "▸ Notarizing dmg…"
  notarize "$DMG_PATH"
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
fi

echo "✓ Built: $ZIP_PATH"
echo "✓ Built: $DMG_PATH"

# ── publish ───────────────────────────────────────────────────────────────────
if [[ -n "$NO_RELEASE" ]]; then
  echo "▸ --no-release: assets are in $DIST_DIR/ (nothing published)."
  echo "  Remember to commit the MARKETING_VERSION bump to $VERSION."
  exit 0
fi

echo "▸ Publishing release $VERSION on $RELEASES_REPO"
NOTES="${RELEASE_NOTES:-$DISPLAY_NAME $VERSION}"
if gh release view "$VERSION" --repo "$RELEASES_REPO" >/dev/null 2>&1; then
  gh release upload "$VERSION" "$ZIP_PATH" "$DMG_PATH" --repo "$RELEASES_REPO" --clobber
else
  gh release create "$VERSION" --repo "$RELEASES_REPO" \
    --title "$DISPLAY_NAME $VERSION" --notes "$NOTES" "$ZIP_PATH" "$DMG_PATH"
fi

echo "✓ Released $DISPLAY_NAME $VERSION"
echo "  https://github.com/$RELEASES_REPO/releases/tag/$VERSION"
echo "  Website download link: https://github.com/$RELEASES_REPO/releases/download/$VERSION/$RELEASE_PREFIX-$VERSION.dmg"
echo "  Don't forget: commit the MARKETING_VERSION bump to $VERSION and push."
