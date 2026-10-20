# Releasing Glass Act

A release is a git tag. Pushing `vX.Y.Z` runs the Release workflow
(`.github/workflows/release.yml`). It builds both apps and the `glassact`
CLI, signs them with Developer ID, notarizes them, and attaches them to a
**draft** GitHub release for you to review and publish.

The workflow needs no Xcode account: it signs manually with your Developer
ID certificate and two provisioning profiles, and notarizes with an App
Store Connect API key. `just release` (local, through the Xcode account) still
works for builds you hand out yourself.

## Versions

- The version lives in `Apps/Version.xcconfig` (`GLASSACT_VERSION`) and in the
  CLI (`let version` in `Sources/glassact/main.swift`). `scripts/check-version`
  checks they agree, and the workflow checks the tag names that version.
- `0.x.y` while the wire protocol may still change in any release. Both ends
  must run the same build (AGENTS.md).
- The build number is a UTC timestamp (`YYYYMMDDHHMM`), set at build time. It
  only increases, which update checks rely on.

## Cutting a release

1. Bump the version in both places in a pull request (and update the
   changelog, once there is one). Merge it.
2. Tag the merge commit and push the tag:
   ```sh
   git tag v0.2.0 && git push origin v0.2.0
   ```
3. Wait for the Release workflow (about 20–30 minutes; notarization is most
   of it).
4. Open the draft release, edit the notes, and publish it.

Each release attaches:

| file | what |
|---|---|
| `Glass Act Host.zip`, `Glass Act Viewer.zip` | the notarized, stapled apps (universal) |
| `glassact-X.Y.Z-macos.zip` | the CLI, universal, Developer ID–signed and notarized |
| `Glass Act Host dSYMs.zip`, `Glass Act Viewer dSYMs.zip` | symbols, to turn crash reports into function names |
| `SHA256SUMS` | checksums of the above |

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

4. **App Store Connect API key** (secrets `ASC_KEY_ID`, `ASC_ISSUER_ID` and
   `ASC_KEY_P8_BASE64`), for notarization:
   - At App Store Connect › Users and Access › Integrations › Team Keys,
     generate a key with the **Developer** role.
   - Note its Key ID and the Issuer ID shown above the list, and download
     the `AuthKey_….p8`; it can be downloaded only once.
   - Then:
     ```sh
     gh secret set ASC_KEY_ID --body "…"
     gh secret set ASC_ISSUER_ID --body "…"
     base64 -i AuthKey_XXXX.p8 | gh secret set ASC_KEY_P8_BASE64
     ```
   - Keep the `.p8` somewhere safe, or delete it; a new key can always be
     made.

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

The output lands in `Apps/build/ci-release/dist`.
