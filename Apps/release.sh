#!/bin/zsh
# Developer ID release: archive → export signed with Developer ID → notarize
# (through the Apple ID signed in to Xcode; no app-specific password) →
# staple → verify with Gatekeeper → zip. The result opens on any Mac with no
# quarantine workaround, like any notarized download.
#
#   Apps/release.sh Viewer [Host …]     → Apps/build/release/<Scheme>/*.app + .zip
set -euo pipefail

cd "${0:A:h}"
# The team from Signing.local.xcconfig (see Signing.xcconfig), or $GLASSACT_TEAM.
TEAM=${GLASSACT_TEAM:-$(sed -n 's/^ *DEVELOPMENT_TEAM *= *\([A-Z0-9]*\).*/\1/p' Signing.local.xcconfig 2>/dev/null | tail -1)}
[[ -n $TEAM ]] || { echo "✗ no signing team — set DEVELOPMENT_TEAM in Apps/Signing.local.xcconfig (see Apps/Signing.xcconfig)"; exit 1; }
# The bundle ID prefix, read the same way: $GLASSACT_BUNDLE_PREFIX, else
# Signing.local.xcconfig, else Signing.xcconfig's default.
bundle_prefix_in() { sed -n 's/^ *GLASSACT_BUNDLE_PREFIX *= *\([^ ]*\).*/\1/p' $1 2>/dev/null | tail -1; }
PREFIX=${GLASSACT_BUNDLE_PREFIX:-$(bundle_prefix_in Signing.local.xcconfig)}
PREFIX=${PREFIX:-$(bundle_prefix_in Signing.xcconfig)}
[[ -n $PREFIX ]] || { echo "✗ no bundle ID prefix — set GLASSACT_BUNDLE_PREFIX in Apps/Signing.local.xcconfig"; exit 1; }
OUT=build/release
BUILD_NUMBER=$(date -u +%Y%m%d%H%M)
mkdir -p $OUT

cat > $OUT/ExportOptions.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>developer-id</string>
	<key>teamID</key><string>$TEAM</string>
	<key>signingStyle</key><string>automatic</string>
	<key>destination</key><string>upload</string>
</dict>
</plist>
EOF

for SCHEME in "$@"; do
	ARCHIVE=$OUT/$SCHEME.xcarchive
	EXPORT=$OUT/$SCHEME
	rm -rf $ARCHIVE $EXPORT
	echo "▸ $SCHEME: archiving (build $BUILD_NUMBER)"
	xcodebuild archive -quiet -project GlassActApps.xcodeproj -scheme $SCHEME -configuration Release \
		-archivePath $ARCHIVE -allowProvisioningUpdates CURRENT_PROJECT_VERSION=$BUILD_NUMBER

	echo "▸ $SCHEME: signing with Developer ID and submitting for notarization"
	xcodebuild -exportArchive -quiet -archivePath $ARCHIVE -exportOptionsPlist $OUT/ExportOptions.plist \
		-exportPath $OUT/$SCHEME-upload -allowProvisioningUpdates

	echo "▸ $SCHEME: waiting for Apple's notary service"
	for attempt in {1..60}; do
		if xcodebuild -exportNotarizedApp -quiet -archivePath $ARCHIVE -exportPath $EXPORT \
			-allowProvisioningUpdates >/dev/null 2>&1; then
			break
		fi
		(( attempt == 60 )) && { echo "✗ $SCHEME: notarization didn't finish in 20 minutes"; exit 1; }
		sleep 20
	done

	APP=$(echo $EXPORT/*.app)
	echo "▸ $SCHEME: verifying"
	codesign --verify --deep --strict "$APP"
	xcrun stapler validate -q "$APP"
	spctl --assess --type execute "$APP" # Gatekeeper: "accepted, source=Notarized Developer ID"
	codesign -dvv "$APP" 2>&1 | grep -E "^Authority=Developer ID Application|^TeamIdentifier"
	ditto -c -k --keepParent "$APP" "$EXPORT/${APP:t:r}.zip"
	echo "✓ $SCHEME: $APP"
done

# Archiving registers its intermediate (development-signed) copies with
# LaunchServices. Left registered, System Settings' privacy rows can resolve
# to one of them and record Screen Recording / Accessibility against the
# wrong code identity — the installed app then keeps asking. Keep only
# copies in /Applications.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
$LSREGISTER -dump | awk -v prefix="$PREFIX" '/^path:/ { sub(/^path: +/, ""); sub(/ \(0x[0-9a-f]+\)$/, ""); p = $0 }
	$1 == "identifier:" && ($2 == prefix ".host" || $2 == prefix ".viewer") { print p }' | sort -u | while read -r stale; do
	[[ $stale == /Applications/Glass\ Act* ]] || $LSREGISTER -u "$stale"
done
