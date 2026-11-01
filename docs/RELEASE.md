# Releasing Session Mover

One command builds, signs, notarizes, staples and checks the app:

```
export SM_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export SM_NOTARY_PROFILE="session-mover-notary"
scripts/release.sh
```

The result is `dist/SessionMover-<version>.zip` with the stapled `build/SessionMover.app` inside. The version comes from the `VERSION` file (`CFBundleShortVersionString`); the build number is the commit count.

## One-time setup

1. **A Developer ID Application certificate in your login keychain.** An Apple Development certificate can't be notarized. Create one in Xcode (Settings > Accounts > your team > Manage Certificates > + > Developer ID Application), or at developer.apple.com/account/resources/certificates. This needs the Account Holder role on a paid Apple Developer team. Check it with:
   ```
   security find-identity -v -p codesigning
   ```
   Copy the full name in quotes, `Developer ID Application: Name (TEAMID)`, into `SM_SIGN_IDENTITY`.
2. **Notarization credentials stored in the keychain.** Make an app-specific password at account.apple.com (Sign-In and Security > App-Specific Passwords), then:
   ```
   xcrun notarytool store-credentials "session-mover-notary" --apple-id you@example.com --team-id TEAMID
   ```
   It asks for the password and saves it under that profile name. Use the name as `SM_NOTARY_PROFILE`.

`scripts/release.sh` checks both before it builds anything. Without them it stops and says which one is missing.

## What the script does

1. `scripts/build-app.sh` with `SM_NO_SIGN=1`: release build, `.app` bundle, `Info.plist` with the version, `AppIcon.icns`, and `verified-versions.json` in `Contents/Resources`.
2. `codesign --options runtime --timestamp --entitlements scripts/SessionMover.entitlements -s "$SM_SIGN_IDENTITY"`. Hardened runtime, not sandboxed (the app reads and writes other apps' data folders). The only entitlement is `com.apple.security.automation.apple-events`, because asking a Claude copy to quit goes through `osascript`.
3. `ditto -c -k --keepParent` to a zip, then `xcrun notarytool submit --keychain-profile "$SM_NOTARY_PROFILE" --wait`.
4. `xcrun stapler staple` and `stapler validate`, a second zip with the ticket inside, then `spctl -a -vv`, which must say `accepted` and `source=Notarized Developer ID`.

If notarization is rejected, the log says why: `xcrun notarytool log <submission id> --keychain-profile "$SM_NOTARY_PROFILE"`.

## Installing

Unzip, drag `SessionMover.app` to `/Applications`, open it. The first time it quits a Claude copy, macOS asks whether Session Mover may control it. Allow it (System Settings > Privacy & Security > Automation).

## Updating the verified Claude versions

`Sources/SessionMoverKit/Resources/verified-versions.json` lists the Claude desktop versions a full move has been verified against, each with the top-level entry keys it writes. It is data, so a new version is a data change:

1. Run the Phase 0 checks (`docs/phase0-findings.md`) on a throwaway copy of the new version.
2. `smctl formatguard` shows each copy's version and the entry keys the fingerprint doesn't have. Key names only, never values.
3. Add the version and its keys to the JSON, bump `VERSION`, run `scripts/release.sh`.

Local, unsigned builds for development: `scripts/build-app.sh` (ad hoc signature, no notarization).

## App icon

`swift scripts/make-icon.swift` redraws `Resources/AppIcon.icns` (two overlapping rounded squares and an arrow).
