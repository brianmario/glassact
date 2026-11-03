#!/bin/zsh
# The iPad Viewer to TestFlight without an Xcode account (RELEASING.md):
# what the TestFlight workflow runs, and what you can run locally to check
# it.
#
#   Archive the iPad scheme with manual Apple Distribution signing and an
#   explicit App Store profile → export for App Store Connect → upload with
#   an App Store Connect API key, symbols included (crash reports in App
#   Store Connect and Xcode's Organizer come symbolicated). TestFlight then
#   processes the build and emails when it's ready for testers.
#
# Needs: the "Apple Distribution" certificate in a keychain on the search
# list, the iPad Viewer's App Store profile installed, and these variables:
#
#   TEAM              team ID
#   IPAD_PROFILE      the iPad Viewer's App Store profile (name or UUID)
#   ASC_KEY_PATH, ASC_KEY_ID, ASC_ISSUER_ID
#                     App Store Connect API key, for the upload (UPLOAD=0
#                     stops after the export: a local check). ASC_ISSUER_ID
#                     only for a team key; an individual key has none.
#   BUILD_NUMBER      optional; default: UTC YYYYMMDDHHMM (TestFlight needs
#                     each upload's to be higher than the last)
#   OUT               optional; default: build/ci-testflight (under Apps/)
set -euo pipefail
cd "${0:A:h}"

: ${TEAM:?} ${IPAD_PROFILE:?}
UPLOAD=${UPLOAD:-1}
if (( UPLOAD )); then : ${ASC_KEY_PATH:?} ${ASC_KEY_ID:?}; fi
BUILD_NUMBER=${BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}
COMMIT=$(git rev-parse --short=7 HEAD)
OUT=${OUT:-build/ci-testflight}
VERSION=$(sed -n 's/^GLASSACT_VERSION *= *\([0-9.]*\).*/\1/p' Version.xcconfig)
IDENTITY="Apple Distribution"
PREFIX=$(sed -n 's/^ *GLASSACT_BUNDLE_PREFIX *= *\([^ ]*\).*/\1/p' Signing.xcconfig | tail -1)
ARCHIVE=$OUT/iPad.xcarchive

rm -rf $OUT
mkdir -p $OUT
echo "▸ Glass Act for iPad $VERSION ($BUILD_NUMBER, $COMMIT), team $TEAM"

echo "▸ archiving"
xcodebuild archive -quiet -project GlassActApps.xcodeproj -scheme iPad -configuration Release \
	-destination 'generic/platform=iOS' -archivePath $ARCHIVE -clonedSourcePackagesDirPath $OUT/packages \
	DEVELOPMENT_TEAM=$TEAM CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" \
	GLASSACT_PROFILE_iPad="$IPAD_PROFILE" \
	GLASSACT_VERSION=$VERSION CURRENT_PROJECT_VERSION=$BUILD_NUMBER GLASSACT_COMMIT=$COMMIT

DESTINATION=export
AUTH=()
if (( UPLOAD )); then
	DESTINATION=upload
	AUTH=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID")
	[[ -n ${ASC_ISSUER_ID:-} ]] && AUTH+=(-authenticationKeyIssuerID "$ASC_ISSUER_ID") # team keys only
fi
cat > $OUT/export.plist <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>app-store-connect</string>
	<key>destination</key><string>$DESTINATION</string>
	<key>teamID</key><string>$TEAM</string>
	<key>signingStyle</key><string>manual</string>
	<key>signingCertificate</key><string>$IDENTITY</string>
	<key>provisioningProfiles</key>
	<dict><key>$PREFIX.viewer</key><string>$IPAD_PROFILE</string></dict>
	<key>uploadSymbols</key><true/>
	<key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
PL

echo "▸ exporting for App Store Connect$( (( UPLOAD )) && echo ' and uploading')"
xcodebuild -exportArchive -quiet -archivePath $ARCHIVE -exportOptionsPlist $OUT/export.plist \
	-exportPath $OUT/export $AUTH

echo "▸ verifying"
APP=$(echo $ARCHIVE/Products/Applications/*.app)
codesign --verify --deep --strict "$APP"
codesign -dvv "$APP" 2>&1 | grep -E "^Authority=Apple Distribution|^TeamIdentifier"
[[ -f $APP/PrivacyInfo.xcprivacy ]] || { echo "error: no privacy manifest in the app" >&2; exit 1; }
if (( UPLOAD )); then
	echo "✓ uploaded $VERSION ($BUILD_NUMBER); TestFlight emails when it's processed"
else
	echo "✓ exported to $OUT/export (not uploaded)"
fi
