# cmux fork: build → sign → notarize → release runbook

Personal (non-Manaflow) signed + notarized cmux builds published to `danielraffel/cmux`.
This produced `v0.64.12-issue5329` and `v0.64.12-issue5329-r2`. Repeat it for any new build.
It is designed so **no step needs reinvention** — follow it top to bottom.

## Credentials & identities (already on this machine)

- **Signing identity:** `Developer ID Application: Daniel Raffel (95CX6P84C4)`
  - SHA1 hash: `D10A184D5A207EAA926955447DC27E2AD965DFB8`
  - Verify present: `security find-identity -v -p codesigning | grep "Developer ID"`
  - (The cert SHA1 and Team ID are public — they appear in every notarized artifact. Not secrets.)
- **Notarization:** use a **keychain notary profile** named `cmux-fork-notary` (set up once, below).
  This keeps the app-specific password out of the process command line (`--password` on argv is
  visible to every local process via `ps`/`pgrep`).
- We sign with **Daniel's own** Developer ID, NOT Manaflow's. Do not use the Manaflow signing hash
  (`A050CC7E193C...`) or Manaflow's provisioning profile.

### One-time: store notary credentials in the keychain

The app-specific password lives in a local env file (e.g. `~/Desktop/untitled folder 2/.env`,
keys `APPLE_ID`, `TEAM_ID=95CX6P84C4`, `APP_SPECIFIC_PASSWORD`). Store it once into a keychain
profile so later builds never pass it on argv:

```bash
ENVF="$HOME/Desktop/untitled folder 2/.env"   # wherever the creds live; never commit this file
APPLE_ID="$(grep -E '^APPLE_ID=' "$ENVF" | cut -d= -f2- | tr -d '"')"
TEAM_ID="$(grep -E '^TEAM_ID='  "$ENVF" | cut -d= -f2- | tr -d '"')"
APP_PW="$(grep -E '^APP_SPECIFIC_PASSWORD=' "$ENVF" | cut -d= -f2- | tr -d '"')"
xcrun notarytool store-credentials cmux-fork-notary \
  --apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APP_PW"
# verify: xcrun notarytool history --keychain-profile cmux-fork-notary
```

If the app-specific password is ever exposed (e.g. printed by `ps`/`pgrep` while a build ran),
rotate it at appleid.apple.com → Sign-In & Security → App-Specific Passwords, then re-run
`store-credentials`.

## Why this isn't just `./scripts/build-sign-upload.sh`

The repo's release script signs with Manaflow's cert, uploads to `manaflow-ai/cmux`, needs
`~/.secrets/cmuxterm.env` + `SPARKLE_PRIVATE_KEY`, and asserts the
`web-browser.public-key-credential` entitlement is present. None of that applies to a personal
fork build, so we run the equivalent steps by hand with adjustments.

Two macOS-26 realities to design around:
1. **Zig 0.15.2 can't link the standalone ghostty CLI helper on macOS 26** (it can't link libSystem
   against the Xcode 26 SDK — even its own build runner fails). So we never build it locally — we
   stub it during the Xcode build, then swap in the real universal helper harvested from an
   installed cmux.
2. **GhosttyKit.xcframework** is fetched as a pinned prebuilt (no local zig link).

## One-time machine setup (skip if already done)

```bash
cd /Users/danielraffel/Code/cmux
git submodule update --init --recursive          # ghostty, bonsplit, homebrew-cmux
brew install zig create-dmg                        # zig only satisfies presence checks
git remote add fork https://github.com/danielraffel/cmux.git   # if missing
```

## Per-build steps

Run from the repo root with the branch you want to ship checked out. A ready-to-run script
implementing steps 2–8 lives at the bottom (`scripts/fork-build.sh`-style); the official repo
build script is `scripts/build-sign-upload.sh` (Manaflow path, do not use for the fork).

### 1. Fetch prebuilt GhosttyKit (pinned by ghostty submodule SHA)

```bash
export PATH="/opt/homebrew/bin:$PATH"
./scripts/ensure-ghosttykit.sh
# Confirms ghostty/macos/GhosttyKit.xcframework present (universal). If the current ghostty SHA
# isn't pinned in scripts/ghosttykit-checksums.txt it falls back to a local zig build, which fails
# on macOS 26 — in that case bump to a ghostty SHA that IS pinned.
```

### 2. Build the app, Release, unsigned, with the helper stubbed

```bash
rm -rf build-release
CMUX_SKIP_ZIG_BUILD=1 xcodebuild \
  -scheme cmux -configuration Release \
  -derivedDataPath build-release \
  -destination 'generic/platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  build
```

- `CMUX_SKIP_ZIG_BUILD=1` emits a *stub* ghostty helper instead of zig-linking one.
- `ARCHS=arm64` = Apple Silicon only. For universal use `ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO`
  (slower; must cross-compile the Rust nucleo FFI for x86_64).
- Do **not** use a `/tmp` derivedDataPath — it breaks xcframework resolution.
- Output: `build-release/Build/Products/Release/cmux.app`

### 3. Post-build prep

```bash
APP="build-release/Build/Products/Release/cmux.app"
# 3a. real universal helper (from an installed cmux); ~12 MB universal Mach-O
cp "/Applications/cmux.app/Contents/Resources/bin/ghostty" "$APP/Contents/Resources/bin/ghostty"
file "$APP/Contents/Resources/bin/ghostty"
# 3b. disable Sparkle auto-update so the upstream feed can't replace this build
/usr/libexec/PlistBuddy -c "Set :SUEnableAutomaticChecks false" "$APP/Contents/Info.plist"
# 3c. strip Sparkle's sandbox-only XPC services (non-sandboxed app)
./scripts/remove-sparkle-sandbox-xpc-services.sh "$APP"
```

### 4. Trimmed entitlements (drop the restricted passkey entitlement)

`cmux.entitlements` includes `com.apple.developer.web-browser.public-key-credential`, which needs a
provisioning profile authorized for Manaflow's team. We sign with a copy that omits only that key:

```bash
cat > /tmp/cmux.danielraffel.entitlements <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.cs.disable-library-validation</key><true/>
	<key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>
	<key>com.apple.security.cs.allow-jit</key><true/>
	<key>com.apple.security.device.camera</key><true/>
	<key>com.apple.security.device.audio-input</key><true/>
	<key>com.apple.security.automation.apple-events</key><true/>
</dict>
</plist>
PLIST
```

### 5. Inside-out codesign (Apple's required order)

`scripts/sign-cmux-bundle.sh` hard-asserts the web-browser entitlement and would fail — run manually:

```bash
APP="build-release/Build/Products/Release/cmux.app"
ID="D10A184D5A207EAA926955447DC27E2AD965DFB8"
APP_ENT="/tmp/cmux.danielraffel.entitlements"
HELP_ENT="cmux-helper.entitlements"
COMMON=(--force --options runtime --timestamp --sign "$ID")

# 1) CLI helpers: minimal hardened-runtime entitlements, no app-id
for h in "$APP/Contents/Resources/bin"/*; do
  [ -f "$h" ] && [ -x "$h" ] && /usr/bin/codesign "${COMMON[@]}" --entitlements "$HELP_ENT" "$h"
done
# 2) Plugins, deep
find "$APP/Contents/PlugIns" -mindepth 1 -maxdepth 1 -print0 2>/dev/null | \
  while IFS= read -r -d '' p; do /usr/bin/codesign "${COMMON[@]}" --deep "$p"; done
# 3) Frameworks, deep (covers Sparkle XPC/Updater.app + the nucleo dylib)
find "$APP/Contents/Frameworks" -mindepth 1 -maxdepth 1 -print0 | \
  while IFS= read -r -d '' f; do /usr/bin/codesign "${COMMON[@]}" --deep "$f"; done
# 4) Main bundle LAST, with app entitlements, NO --deep
/usr/bin/codesign "${COMMON[@]}" --entitlements "$APP_ENT" "$APP"

codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dvv "$APP" 2>&1 | grep -iE "Authority=Developer|TeamIdentifier|Runtime"
```

**`--deep` on the main bundle is WRONG here.** It re-signs helpers/plugins with the app-id and
amfi rejects it at launch on notarized macOS 26 (errno 163) — the app passes `spctl` but then says
"The application can't be opened." Sign children individually, parent last, no `--deep` on the parent.

### 6. Notarize the app, then staple

```bash
APP="build-release/Build/Products/Release/cmux.app"
ditto -c -k --sequesterRsrc --keepParent "$APP" cmux-notary.zip
xcrun notarytool submit cmux-notary.zip --keychain-profile cmux-fork-notary --wait   # status: Accepted
xcrun stapler staple "$APP" && xcrun stapler validate "$APP"
rm -f cmux-notary.zip
spctl -a -vvv -t exec "$APP"        # expect: accepted / Notarized Developer ID
```

### 7. Build, sign, notarize, staple the DMG

```bash
ID="D10A184D5A207EAA926955447DC27E2AD965DFB8"
rm -rf /tmp/cmux-dmg-stage cmux-macos.dmg
mkdir -p /tmp/cmux-dmg-stage
ditto "$APP" "/tmp/cmux-dmg-stage/cmux.app"
ln -s /Applications "/tmp/cmux-dmg-stage/Applications"
hdiutil create -volname "cmux" -srcfolder /tmp/cmux-dmg-stage -ov -format UDZO cmux-macos.dmg
codesign --force --timestamp --sign "$ID" cmux-macos.dmg
xcrun notarytool submit cmux-macos.dmg --keychain-profile cmux-fork-notary --wait
xcrun stapler staple cmux-macos.dmg && xcrun stapler validate cmux-macos.dmg
spctl -a -vvv -t open --context context:primary-signature cmux-macos.dmg   # expect: accepted
rm -rf /tmp/cmux-dmg-stage
```

### 8. Prove the binary contains your fix (no GUI launch needed)

```bash
"$APP/Contents/Resources/bin/cmux" --version    # -> cmux 0.64.x (NN) [<short-sha>]
```

The Release build shares bundle id `com.cmuxterm.app` with an installed cmux, so *launching* it
makes the installed instance hand off and exit. `--version` reads the embedded SHA without
launching the GUI — match it to the branch's `git rev-parse --short HEAD`.

### 9. Publish on the fork

```bash
TAG="v0.64.12-issue5329-r2"        # fork-specific; never collide with upstream tags. bump -r2/-r3 per rebuild.
BRANCH="issue-5329-settings-observer-leak"
git push fork "$BRANCH"            # ensure the branch is on the fork (the release --target)
git tag -f "$TAG" "$BRANCH"
git push -f fork "$TAG"
gh release create "$TAG" \
  --repo danielraffel/cmux \
  --target "$BRANCH" \
  --title "cmux 0.64.x — <what changed>" \
  --notes-file /tmp/release-notes.md \
  cmux-macos.dmg
```

Then move `cmux-macos.dmg` out of the repo root (it's a build artifact) and `rm -rf build-release`.

## Properties of the resulting build

- Signed `Developer ID Application: Daniel Raffel (95CX6P84C4)`, hardened runtime, timestamped.
- App + DMG notarized and stapled → Gatekeeper opens it with no warnings, offline.
- Apple Silicon only (unless built universal in step 2).
- Sparkle auto-update OFF; in-browser passkeys OFF (dropped entitlement).
- `cmux --version` embeds the git short SHA, so you can prove the binary contains the fix.

## Known pitfalls (learned the hard way)

- **`--deep` on the main bundle** → amfi errno 163 at launch on macOS 26 (passes `spctl`, won't
  open). Inside-out only (step 5).
- **Opening the DMG before `stapler staple` finishes** → "can't be opened." Wait for notarization
  + staple, then verify with `spctl ... -t open`.
- **`--password` on argv** → leaks the app-specific password to local `ps`/`pgrep`. Use the keychain
  profile (this runbook). Rotate if ever exposed.
- **Don't add this runbook to a PR branch** — it lives on the fork's `fork-build-notes` branch so it
  never shows up in an upstream pull request diff.
