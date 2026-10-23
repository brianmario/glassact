#!/bin/zsh
# A release without an Xcode account (RELEASING.md): what the release
# workflow runs, and what you can run locally to check it.
#
#   Archive both apps with manual Developer ID signing and explicit
#   provisioning profiles → export → notarize with an App Store Connect API
#   key → staple → verify → zip. Also a universal, Developer ID–signed
#   `glassact` CLI, the archives' dSYMs, each app's Sparkle appcast, and
#   SHA256SUMS. File names have no spaces: GitHub renames those in release
#   assets, and the appcasts point at the assets by name.
#
# Needs: the "Developer ID Application" certificate in a keychain on the
# search list, both profiles installed, and these variables:
#
#   TEAM              team ID
#   HOST_PROFILE      the Host's Developer ID profile (name or UUID)
#   VIEWER_PROFILE    the Viewer's
#   ASC_KEY_PATH, ASC_KEY_ID, ASC_ISSUER_ID
#                     App Store Connect API key, for notarization
#                     (NOTARIZE=0 skips it: a local check, not a release).
#                     ASC_ISSUER_ID only for a team key; an individual key
#                     has none.
#   SPARKLE_KEY_FILE  the EdDSA private key updates are signed with
#                     (optional locally: without it, no appcasts)
#   TAG               optional; default: v<version> (the appcasts' URLs)
#   REPO              optional; default: brianmario/glassact
#   BUILD_NUMBER      optional; default: UTC YYYYMMDDHHMM
#   OUT               optional; default: build/ci-release (under Apps/)
set -euo pipefail
cd "${0:A:h}"

: ${TEAM:?} ${HOST_PROFILE:?} ${VIEWER_PROFILE:?}
NOTARIZE=${NOTARIZE:-1}
if (( NOTARIZE )); then : ${ASC_KEY_PATH:?} ${ASC_KEY_ID:?}; fi
BUILD_NUMBER=${BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}
COMMIT=$(git rev-parse --short=7 HEAD)
OUT=${OUT:-build/ci-release}
VERSION=$(sed -n 's/^GLASSACT_VERSION *= *\([0-9.]*\).*/\1/p' Version.xcconfig)
TAG=${TAG:-v$VERSION}
REPO=${REPO:-brianmario/glassact}
IDENTITY="Developer ID Application"
PREFIX=$(sed -n 's/^ *GLASSACT_BUNDLE_PREFIX *= *\([^ ]*\).*/\1/p' Signing.xcconfig | tail -1)

rm -rf $OUT
mkdir -p $OUT/dist
echo "▸ Glass Act $VERSION ($BUILD_NUMBER, $COMMIT), team $TEAM"

notarize() { # <zip>
	(( NOTARIZE )) || { echo "  (notarization skipped)"; return; }
	local issuer=()
	[[ -n ${ASC_ISSUER_ID:-} ]] && issuer=(--issuer "$ASC_ISSUER_ID") # team keys only
	xcrun notarytool submit "$1" --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" $issuer --wait --timeout 30m
}

for SCHEME in Host Viewer; do
	if [[ $SCHEME == Host ]]; then PROFILE=$HOST_PROFILE; else PROFILE=$VIEWER_PROFILE; fi
	ARCHIVE=$OUT/$SCHEME.xcarchive
	echo "▸ $SCHEME: archiving"
	xcodebuild archive -quiet -project GlassActApps.xcodeproj -scheme $SCHEME -configuration Release \
		-destination 'generic/platform=macOS' -archivePath $ARCHIVE -clonedSourcePackagesDirPath $OUT/packages \
		DEVELOPMENT_TEAM=$TEAM CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" \
		GLASSACT_PROFILE_$SCHEME="$PROFILE" \
		GLASSACT_VERSION=$VERSION CURRENT_PROJECT_VERSION=$BUILD_NUMBER GLASSACT_COMMIT=$COMMIT

	echo "▸ $SCHEME: exporting with Developer ID"
	BUNDLE_ID=$PREFIX.${(L)SCHEME}
	cat > $OUT/$SCHEME-export.plist <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>developer-id</string>
	<key>teamID</key><string>$TEAM</string>
	<key>signingStyle</key><string>manual</string>
	<key>signingCertificate</key><string>$IDENTITY</string>
	<key>provisioningProfiles</key>
	<dict><key>$BUNDLE_ID</key><string>$PROFILE</string></dict>
</dict>
</plist>
PL
	xcodebuild -exportArchive -quiet -archivePath $ARCHIVE -exportOptionsPlist $OUT/$SCHEME-export.plist \
		-exportPath $OUT/$SCHEME
	APP=$(echo $OUT/$SCHEME/*.app)
	NAME="Glass-Act-$SCHEME-$VERSION"
	ZIP="$OUT/dist/$NAME.zip"

	echo "▸ $SCHEME: notarizing"
	ditto -c -k --keepParent "$APP" "$ZIP"
	notarize "$ZIP"
	if (( NOTARIZE )); then
		xcrun stapler staple -q "$APP"
		rm "$ZIP" && ditto -c -k --keepParent "$APP" "$ZIP" # the stapled copy
	fi

	echo "▸ $SCHEME: verifying"
	codesign --verify --deep --strict "$APP"
	codesign -dvv "$APP" 2>&1 | grep -E "^Authority=Developer ID Application|^TeamIdentifier"
	if (( NOTARIZE )); then
		xcrun stapler validate -q "$APP"
		spctl --assess --type execute "$APP"
	fi
	ditto -c -k --keepParent $ARCHIVE/dSYMs "$OUT/dist/$NAME-dSYMs.zip"

	if [[ -n ${SPARKLE_KEY_FILE:-} ]]; then
		echo "▸ $SCHEME: appcast"
		FEED=$OUT/feed-${(L)SCHEME}
		mkdir -p $FEED && cp "$ZIP" $FEED/
		$OUT/packages/artifacts/sparkle/Sparkle/bin/generate_appcast --ed-key-file "$SPARKLE_KEY_FILE" \
			--download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
			--full-release-notes-url "https://github.com/$REPO/releases/tag/$TAG" \
			--link "https://github.com/$REPO" -o "$OUT/dist/${(L)SCHEME}-appcast.xml" $FEED
	else
		echo "  (no SPARKLE_KEY_FILE: no appcast)"
	fi
	echo "✓ $SCHEME: ${ZIP:t}"
done

echo "▸ glassact CLI: universal build"
# The commit goes in an Info.plist linked into the binary, where
# `glassact --version` reads it (Bundle.main reads a CLI's __info_plist).
CLI_PLIST=${OUT:A}/cli-Info.plist
plutil -create xml1 $CLI_PLIST
plutil -insert CFBundleIdentifier -string $PREFIX.cli $CLI_PLIST
plutil -insert GlassActCommit -string $COMMIT $CLI_PLIST
CLI_BUILD=(-c release --arch arm64 --arch x86_64 --scratch-path Apps/$OUT/cli-build
	-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker $CLI_PLIST)
(cd .. && swift build $CLI_BUILD --product glassact)
CLI=$(cd .. && swift build $CLI_BUILD --show-bin-path)/glassact
mkdir -p $OUT/cli && cp "$CLI" $OUT/cli/glassact
codesign --force --options runtime --timestamp --sign "$IDENTITY" --identifier $PREFIX.cli $OUT/cli/glassact
lipo -archs $OUT/cli/glassact
CLI_ZIP="$OUT/dist/glassact-cli-$VERSION.zip"
ditto -c -k $OUT/cli "$CLI_ZIP"
notarize "$CLI_ZIP" # a bare binary can't be stapled; Gatekeeper checks it online
echo "✓ glassact CLI: ${CLI_ZIP:t}"

(cd $OUT/dist && shasum -a 256 *.zip > SHA256SUMS)
echo "✓ done: $OUT/dist"
ls -la $OUT/dist
