#!/bin/zsh
# Builds, signs, notarizes and staples a Framewright release, and zips it for GitHub.
#
#   Scripts/release.sh                 # version from project.yml (MARKETING_VERSION)
#   Scripts/release.sh --skip-notarize # a Distribution build and zip only (for a local check)
#
# Needs, once per machine (see docs/reviews/integration-notes.md, "Notarized releases"):
#   - a Developer ID Application certificate for the team in Config/Signing.local.xcconfig
#     (Xcode > Settings > Accounts > Manage Certificates > + > Developer ID Application);
#   - notarytool credentials stored as the keychain profile "framewright-notary":
#       xcrun notarytool store-credentials framewright-notary --apple-id <apple id> --team-id <team>
#     (the password is an app-specific password from appleid.apple.com).
set -euo pipefail

cd "$(dirname "$0")/.."
PROFILE=${NOTARY_PROFILE:-framewright-notary}
VERSION=$(grep -m1 'MARKETING_VERSION:' project.yml | sed 's/.*: *//')
OUT=${RELEASE_DIR:-build/release}
DD="$OUT/DerivedData"
APP="$DD/Build/Products/Distribution/Framewright.app"
SUBMIT="$OUT/Framewright-$VERSION-submit.zip"
ZIP="$OUT/Framewright-$VERSION-macOS.zip"
SKIP_NOTARIZE=0
[[ "${1:-}" == "--skip-notarize" ]] && SKIP_NOTARIZE=1

if [[ ! -f Config/Signing.local.xcconfig ]]; then
    echo "Config/Signing.local.xcconfig is missing (FRAMEWRIGHT_DEVELOPMENT_TEAM = <team id>)" >&2
    exit 1
fi
if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
    echo "no Developer ID Application certificate in the keychain; create one in Xcode first" >&2
    exit 1
fi

rm -rf "$OUT"
mkdir -p "$OUT"
echo "== version $VERSION: Distribution build"
xcodegen generate >/dev/null
xcodebuild -scheme Framewright -destination 'platform=macOS' -configuration Distribution \
    -derivedDataPath "$DD" build 2>&1 | grep -E "error:|warning:.*$(pwd)|BUILD (SUCCEEDED|FAILED)" | tail -5
[[ -d "$APP" ]] || { echo "no app at $APP" >&2; exit 1; }

echo "== signature"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -2
codesign -dv --entitlements - "$APP" 2>&1 | grep -E "Authority=Developer ID|TeamIdentifier|runtime" | head -3

if (( SKIP_NOTARIZE )); then
    ditto -c -k --keepParent --sequesterRsrc "$APP" "$ZIP"
    echo "== built (not notarized): $ZIP"
    exit 0
fi

echo "== notarize"
ditto -c -k --keepParent "$APP" "$SUBMIT"
xcrun notarytool submit "$SUBMIT" --keychain-profile "$PROFILE" --wait 2>&1 | tee "$OUT/notarize.log" | tail -4
if ! grep -q "status: Accepted" "$OUT/notarize.log"; then
    ID=$(grep -m1 '  id:' "$OUT/notarize.log" | sed 's/.*id: *//')
    [[ -n "$ID" ]] && xcrun notarytool log "$ID" --keychain-profile "$PROFILE" "$OUT/notarize-issues.json" && \
        echo "issues in $OUT/notarize-issues.json" >&2
    exit 1
fi

echo "== staple and check"
xcrun stapler staple "$APP" | tail -1
xcrun stapler validate "$APP" | tail -1
spctl -a -vv -t exec "$APP" 2>&1 | tail -2

ditto -c -k --keepParent --sequesterRsrc "$APP" "$ZIP"
rm -f "$SUBMIT"
echo "== release zip: $ZIP ($(du -h "$ZIP" | cut -f1))"
echo "   gh release create v$VERSION \"$ZIP#Framewright-$VERSION-macOS.zip\" --target main --title \"Framewright $VERSION\" --notes-file <notes> --prerelease"
