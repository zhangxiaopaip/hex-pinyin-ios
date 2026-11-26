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

# The Chinese keyboard's index is read by offset, so a wrong field there is silent: bare
# letters, no candidates, nothing in the build complaining. Check the shipped file first, the
# index and the words a run spells — a typo's too, which is what the near keys are for.
if command -v swiftc >/dev/null 2>&1; then
  swiftc -swift-version 6 -parse-as-library \
    HEXShared/FullKeyboard/Chinese/PinyinIndex.swift \
    HEXShared/FullKeyboard/Chinese/PinyinCorrection.swift \
    HEXShared/FullKeyboard/Chinese/PinyinDictionary.swift \
    scripts/verify-pinyin-stubs.swift \
    scripts/verify-pinyin-index.swift \
    -o "$build/verify-pinyin-index"
  "$build/verify-pinyin-index"
else
  echo "swiftc is missing: cannot verify Wanxiang.pinyin" >&2
  exit 1
fi

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

# Swift 6.2's IRGen aborts emitting a @Sendable thunk ("report_at_maximum_capacity" in
# SyncCallEmission::setArgs), and the SIL the optimizer hands it decides whether that thunk
# is built at all. Unoptimized SIL sidesteps it; the archive is slower for it.
SWIFT_MODE_FLAGS="SWIFT_COMPILATION_MODE=singlefile SWIFT_ENABLE_BATCH_MODE=NO SWIFT_OPTIMIZATION_LEVEL=-Onone"

# FluidAudio is vendored under Vendor/, so there is no graph to fetch or pin.
xcodebuild -resolvePackageDependencies -project HEXMobile.xcodeproj -scheme HEXMobile \
  -skipPackagePluginValidation -skipMacroValidation

archive="$build/Hex.xcarchive"

if [ "${UNSIGNED:-1}" = 1 ]; then
  xcodebuild archive -project HEXMobile.xcodeproj -scheme HEXMobile \
    -configuration Release -destination 'generic/platform=iOS' \
    -archivePath "$archive" \
    -skipPackagePluginValidation -skipMacroValidation \
    $SWIFT_MODE_FLAGS \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""

  app="$archive/Products/Applications/HEX.app"
  [ -d "$app" ] || {
    echo "The archive holds no HEX.app" >&2
    exit 1
  }
  # A file whose extension XcodeGen doesn't know ships in no bundle at all, silently: the
  # keyboard would type pinyin with nothing to pick, which is exactly how this broke before.
  for needed in "$app/PlugIns/HEXKeyboard.appex/Wanxiang.pinyin"; do
    [ -f "$needed" ] || {
      echo "Missing $(basename "$needed"): the Chinese keyboard would offer no candidates" >&2
      exit 1
    }
  done
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
    $SWIFT_MODE_FLAGS \
    -allowProvisioningUpdates

  xcodebuild -exportArchive -archivePath "$archive" \
    -exportOptionsPlist ExportOptions.plist \
    -exportPath "$build/export" -allowProvisioningUpdates
fi

ls -l "$build"/*.ipa
