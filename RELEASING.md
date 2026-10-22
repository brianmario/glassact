# Releasing Glass Act

A release is a git tag. Pushing `vYY.M.N` runs the Release workflow
(`.github/workflows/release.yml`). It builds both apps and the `glassact`
CLI, signs them with Developer ID, notarizes them, and attaches them to a
**draft** GitHub release for you to review and publish.

The workflow needs no Xcode account: it signs manually with your Developer
ID certificate and two provisioning profiles, and notarizes with an App
Store Connect API key. `just release` (local, through the Xcode account) still
works for builds you hand out yourself.

## Versions

- Versions are `YY.M.N`: the year and month of the release, then N counting
  releases within that month from 0. October 2026's first release is
  `26.10.0`, a fix the same day `26.10.1`, and November's first `26.11.0`.
  The version promises nothing about compatibility: until the wire protocol
  settles, both ends must run the same build (AGENTS.md), whatever the
  numbers say.
- The version lives in `Apps/Version.xcconfig` (`GLASSACT_VERSION`) and in the
  CLI (`let version` in `Sources/glassact/main.swift`). `scripts/check-version`
  checks they agree and are `YY.M.N`, and the workflow checks the tag names
  that version.
- The build number is a UTC timestamp (`YYYYMMDDHHMM`), set at build time. It
  only increases, which update checks rely on. Finder's Get Info shows it
  after the version: `26.10.0 (202610222020)`.
- Release builds also carry the short commit hash they were built from
  (`GLASSACT_COMMIT`). The About panel, the apps' logs and
  `glassact --version` show it, so a bug report names the exact commit:
  `26.10.0 (202610222020, a1b2c3d)`. A build from Xcode or `swift build` has
  none.

## Cutting a release

1. Set the version in both places in a pull request: this month's `YY.M`,
   and N one past this month's last release tag, or 0 if there's none yet
   (`git tag -l 'v26.11.*'`). Update the changelog, once there is one.
   Merge it.
2. Tag the merge commit and push the tag:
   ```sh
   git tag v26.11.0 && git push origin v26.11.0
   ```
3. Wait for the Release workflow (about 5–30 minutes; notarization is most
   of it).
4. Open the draft release, edit the notes, and publish it.

Each release attaches:

| file | what |
|---|---|
| `Glass-Act-Host-YY.M.N.zip`, `Glass-Act-Viewer-YY.M.N.zip` | the notarized, stapled apps (universal) |
| `host-appcast.xml`, `viewer-appcast.xml` | each app's Sparkle update feed, pointing at the zips above |
| `glassact-YY.M.N-macos.zip` | the CLI, universal, Developer ID–signed and notarized |
| `Glass-Act-Host-YY.M.N-dSYMs.zip`, `Glass-Act-Viewer-YY.M.N-dSYMs.zip` | symbols, to turn crash reports into function names |
| `SHA256SUMS` | checksums of the zips |

File names have no spaces: GitHub renames those in release assets, and the
appcasts link to the zips by name.

**Updates go out when you publish.** The apps read
`releases/latest/download/<app>-appcast.xml`, and "latest" means the newest
*published* release. A draft changes nothing until you publish it.

## One-time setup

Everything below goes into the repository's **Settings › Secrets and
variables › Actions**. Values marked *secret* go under Secrets; the rest
under Variables.

1. **Team ID** (variable `APPLE_TEAM_ID`): your Apple developer team ID, for
   example `VJ4FHSCMNE`.

2. **Developer ID certificate** (secrets `DEVELOPER_ID_P12_BASE64` and
   `DEVELOPER_ID_P12_PASSWORD`):
   - In Keychain Access, find "Developer ID Application: …" under My
     Certificates, and export it with its private key as a `.p12`, choosing
     a password.
   - Store it base64-encoded, and the password:
     ```sh
     base64 -i DeveloperID.p12 | gh secret set DEVELOPER_ID_P12_BASE64
     gh secret set DEVELOPER_ID_P12_PASSWORD
     ```
   - Then delete the `.p12` file.

3. **Provisioning profiles** (secrets `HOST_PROFILE_BASE64` and
   `VIEWER_PROFILE_BASE64`; variables `HOST_PROFILE_NAME` and
   `VIEWER_PROFILE_NAME`). The apps' keychain entitlement needs a profile, and
   manual signing can't use the ones Xcode manages.
   - At developer.apple.com › Certificates, Identifiers & Profiles ›
     Profiles, add a **Developer ID** profile for the App ID `app.glassact.host`
     with your Developer ID certificate. Name it, for example, `Glass Act Host
     Developer ID`.
   - Do the same for `app.glassact.viewer`.
   - Download both, then:
     ```sh
     base64 -i "Glass_Act_Host_Developer_ID.provisionprofile" | gh secret set HOST_PROFILE_BASE64
     base64 -i "Glass_Act_Viewer_Developer_ID.provisionprofile" | gh secret set VIEWER_PROFILE_BASE64
     gh variable set HOST_PROFILE_NAME --body "Glass Act Host Developer ID"
     gh variable set VIEWER_PROFILE_NAME --body "Glass Act Viewer Developer ID"
     ```

4. **App Store Connect API key** (secrets `ASC_KEY_ID` and `ASC_KEY_P8_BASE64`;
   `ASC_ISSUER_ID` too for a team key), for notarization. It's an App Store
   Connect key only because Apple's notary service lives there; nothing goes
   to the App Store.
   - At App Store Connect › Users and Access › Integrations, generate a key.
     An **individual** developer account has **Individual Keys**: generate
     one there (if you see *Request Access*, do that first). An organization
     has **Team Keys**: generate one with the **Developer** role, and note the
     Issuer ID shown above the list.
   - Note the Key ID, and download the `AuthKey_….p8`; it can be downloaded
     only once.
   - Then:
     ```sh
     gh secret set ASC_KEY_ID -R brianmario/glassact --body "…"
     base64 -i AuthKey_XXXX.p8 | gh secret set ASC_KEY_P8_BASE64 -R brianmario/glassact
     gh secret set ASC_ISSUER_ID -R brianmario/glassact --body "…"   # team keys only
     ```
   - Keep the `.p8` somewhere safe, or delete it; a new key can always be
     made.

5. **Update signing key** (secret `SPARKLE_ED_PRIVATE_KEY`, plus the public
   key in `Apps/Updates.xcconfig`). Sparkle installs only updates signed with
   this key, so it's the most important secret here.
   - Build either app once (Xcode or `xcodebuild`) so Sparkle's tools are
     downloaded, then generate the key. It's stored in your login keychain,
     and the tool prints the public key:
     ```sh
     "$(find ~/Library/Developer/Xcode/DerivedData -path '*artifacts/sparkle/Sparkle/bin/generate_keys' | head -1)"
     ```
   - Put the public key in `Apps/Updates.xcconfig`
     (`GLASSACT_SPARKLE_PUBLIC_KEY = …`) in a pull request.
   - Export the private key, store it as the secret, and keep a copy in your
     password manager:
     ```sh
     "$(find ~/Library/Developer/Xcode/DerivedData -path '*artifacts/sparkle/Sparkle/bin/generate_keys' | head -1)" -x sparkle-private.key
     gh secret set SPARKLE_ED_PRIVATE_KEY -R brianmario/glassact < sparkle-private.key
     rm sparkle-private.key
     ```
   - **Don't lose it.** Without the private key, installed copies can't be
     updated any more; people would have to download a new build by hand.

If anything is missing, the workflow stops at "Secrets present" and names
it.

## Checking the release build locally

`Apps/ci-release.sh` is what the workflow runs. With the certificate in your
keychain and both profiles installed (double-click them), you can run it
without notarizing:

```sh
TEAM=VJ4FHSCMNE HOST_PROFILE="Glass Act Host Developer ID" \
  VIEWER_PROFILE="Glass Act Viewer Developer ID" NOTARIZE=0 Apps/ci-release.sh
```

The output lands in `Apps/build/ci-release/dist`. Add
`SPARKLE_KEY_FILE=<private key file>` to also write the appcasts.

## Trying an update locally

To check an update end to end before a release, without publishing
anything:

1. Generate a throwaway key pair, and put its public half in
   `Apps/Updates.xcconfig` for the test only. Never commit it.
2. Build the current version with `Apps/ci-release.sh` (`NOTARIZE=0`) and copy
   the app somewhere scratch.
3. Raise `GLASSACT_VERSION`, build again, zip that app, and write an appcast
   for it with `generate_appcast --ed-key-file <throwaway key>
   --download-url-prefix http://localhost:8765/`.
4. Serve that folder (`python3 -m http.server 8765 --bind 127.0.0.1`), then
   open the older app with the feed overridden:
   ```sh
   open -n --env GLASSACT_UPDATE_FEED=http://localhost:8765/viewer-appcast.xml "/path/to/Glass Act Viewer.app"
   ```
5. Choose Check for Updates…: it should offer, install and relaunch into
   the newer version. Then restore `Apps/Updates.xcconfig` and the version.
