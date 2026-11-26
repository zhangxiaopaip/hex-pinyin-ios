#!/bin/sh
set -eu

# Builds Hex's app, keyboard and widgets into an .ipa away from Xcode Cloud, on any Mac with
# Xcode and XcodeGen. An unsigned archive needs no Apple account at all: a sideloading tool
# (Sideloadly, AltStore) signs it again with your own account when it installs.
#
# Environment:
#   PERSONAL_PREFIX  rewrite the bundle identifiers to this prefix and drop the App Group,
#                    for a free Apple ID, which cannot claim a group and cannot claim an
#                    identifier the App Store already holds. The keyboard then keeps its
#                    words in its own container (see KeyboardLiveDictation's note on it).
#   BUILD_DIR        where the .ipa lands. Default: ios/build/ipa.
#   IPA_NAME         the file's name without .ipa. Default: Hex-unsigned.
#   UNSIGNED=0       export a signed .ipa through ExportOptions.plist instead, which needs a
#                    Mac holding the certificate and profiles Xcode Cloud has.

ios=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ios"

build="${BUILD_DIR:-$ios/build/ipa}"
rm -rf "$build"
mkdir -p "$build"

command -v xcodegen >/dev/null 2>&1 || {
  echo "xcodegen is missing: brew install xcodegen" >&2
  exit 1
}
command -v xcodebuild >/dev/null 2>&1 || {
  echo "xcodebuild is missing: install Xcode and run xcode-select" >&2
  exit 1
}

# The cleanup tagger's Core ML model is kept out of git; the generated project needs it.
sh scripts/fetch-cleanup-model.sh

# A personal build lives outside the App Store's identifiers and gives up the group, which
# the keyboard survives: every reader of the group's defaults and container takes nil.
if [ -n "${PERSONAL_PREFIX:-}" ]; then
  sed -i.bak \
    -e "s/anomaly\.hex\.mobile/$PERSONAL_PREFIX.hex/g" \
    -e '/CODE_SIGN_ENTITLEMENTS:/d' \
    project.yml
  rm -f project.yml.bak
  echo "Personal build: bundle identifiers $PERSONAL_PREFIX.hex, no App Group"
fi

xcodegen generate

# The dependency graph is checked in; the generated project starts without it.
pins=HEXMobile.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
mkdir -p "$pins"
cp Package.resolved "$pins/Package.resolved"

# Swift 6.2's IRGen dies emitting a reabstraction thunk inside FluidAudio 0.15.5 (a
# @Sendable conversion of an actor-isolated closure). The package and Hex both compile in
# Swift 5's language mode, which emits no such thunk, and the binary is the same either way.
SWIFT_LANGUAGE_MODE=${SWIFT_LANGUAGE_MODE:-5}

# Resolving first keeps a mistyped pin out of a twenty-minute archive.
xcodebuild -resolvePackageDependencies -project HEXMobile.xcodeproj -scheme HEXMobile \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -skipPackagePluginValidation -skipMacroValidation

archive="$build/Hex.xcarchive"

if [ "${UNSIGNED:-1}" = 1 ]; then
  xcodebuild archive -project HEXMobile.xcodeproj -scheme HEXMobile \
    -configuration Release -destination 'generic/platform=iOS' \
    -archivePath "$archive" \
    -skipPackagePluginValidation -skipMacroValidation \
    SWIFT_VERSION="$SWIFT_LANGUAGE_MODE" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""

  app="$archive/Products/Applications/HEX.app"
  [ -d "$app" ] || {
    echo "The archive holds no HEX.app" >&2
    exit 1
  }
  # An .ipa is a zip of Payload/, the app extensions riding inside the app as built.
  mkdir -p "$build/Payload"
  cp -R "$app" "$build/Payload/HEX.app"
  name="${IPA_NAME:-Hex-unsigned}"
  (cd "$build" && zip -qry "$name.ipa" Payload)
  rm -rf "$build/Payload"
else
  xcodebuild archive -project HEXMobile.xcodeproj -scheme HEXMobile \
    -configuration Release -destination 'generic/platform=iOS' \
    -archivePath "$archive" \
    -skipPackagePluginValidation -skipMacroValidation \
    SWIFT_VERSION="$SWIFT_LANGUAGE_MODE" \
    -allowProvisioningUpdates

  xcodebuild -exportArchive -archivePath "$archive" \
    -exportOptionsPlist ExportOptions.plist \
    -exportPath "$build/export" -allowProvisioningUpdates
fi

ls -l "$build"/*.ipa
