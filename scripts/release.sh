#!/bin/bash
# Signed, notarized release build: build, sign (hardened runtime), zip, notarize, staple, verify.
#
#   SM_SIGN_IDENTITY   the "Developer ID Application: Name (TEAMID)" certificate to sign with
#   SM_NOTARY_PROFILE  a notarytool keychain profile (xcrun notarytool store-credentials <profile> ...)
#
# Output: dist/SessionMover-<version>.zip (stapled app inside). See docs/RELEASE.md.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(tr -d '[:space:]' < VERSION)"
APP="build/SessionMover.app"
ZIP="dist/SessionMover-${VERSION}.zip"
ENTITLEMENTS="scripts/SessionMover.entitlements"

die() { printf '\nrelease.sh: %s\n' "$*" >&2; exit 1; }

# 1. Everything the release needs, checked before anything is built.
if [ -z "${SM_SIGN_IDENTITY:-}" ]; then
    die "SM_SIGN_IDENTITY is not set.
Set it to the name of your Developer ID Application certificate, for example:
  export SM_SIGN_IDENTITY=\"Developer ID Application: Your Name (TEAMID)\"
That certificate must be in your login keychain. Create it in Xcode (Settings > Accounts > Manage Certificates >
+ > Developer ID Application) or at developer.apple.com/account/resources/certificates. See docs/RELEASE.md."
fi
IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
if ! printf '%s\n' "$IDENTITIES" | grep -q "Developer ID Application"; then
    die "No \"Developer ID Application\" certificate is in your keychain (found only: $(printf '%s\n' "$IDENTITIES" | grep -o '"[^"]*"' | tr '\n' ' ')).
Apple Development certificates can't be notarized. Create a Developer ID Application certificate
(Xcode > Settings > Accounts > Manage Certificates > + > Developer ID Application), then run this again. See docs/RELEASE.md."
fi
if ! printf '%s\n' "$IDENTITIES" | grep -qF "$SM_SIGN_IDENTITY"; then
    die "SM_SIGN_IDENTITY=\"$SM_SIGN_IDENTITY\" doesn't match a signing identity in your keychain. Run:
  security find-identity -v -p codesigning"
fi
if [ -z "${SM_NOTARY_PROFILE:-}" ]; then
    die "SM_NOTARY_PROFILE is not set.
Store notarization credentials once, then name the profile:
  xcrun notarytool store-credentials \"<profile>\" --apple-id <you@example.com> --team-id <TEAMID>   (it asks for an app-specific password)
  export SM_NOTARY_PROFILE=\"<profile>\"
See docs/RELEASE.md."
fi

# 2. Build the .app without signing, then sign it for distribution.
SM_NO_SIGN=1 scripts/build-app.sh
echo "Signing with: $SM_SIGN_IDENTITY"
codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" -s "$SM_SIGN_IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

# 3. Zip with ditto (keeps the signature and resource forks), notarize, staple.
mkdir -p dist
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Submitting $ZIP to Apple. This waits for the result (usually a few minutes)."
xcrun notarytool submit "$ZIP" --keychain-profile "$SM_NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

# 4. Zip again, now with the ticket stapled in, and check what Gatekeeper says.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
spctl -a -vv "$APP"
echo
echo "Release $VERSION ready: $ZIP"
