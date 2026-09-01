#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/Private AI/Private AI.xcodeproj"
SCHEME="Private AI"
OUTPUT_DIRECTORY="${OUTPUT_DIRECTORY:-$ROOT/build/direct}"
ARCHIVE_PATH="$OUTPUT_DIRECTORY/PrivateAI.xcarchive"
APP_NAME="Private AI.app"
APP_PATH="$ARCHIVE_PATH/Products/Applications/$APP_NAME"
DMG_PATH="$OUTPUT_DIRECTORY/PrivateAI.dmg"
STAGING_DIRECTORY="$OUTPUT_DIRECTORY/dmg-root"
BUNDLE_ID="${PRODUCT_BUNDLE_IDENTIFIER:-com.jacobjiangwei.privateai}"
PRIVACY_POLICY_URL="${PRIVATEAI_PRIVACY_POLICY_URL:-}"
BUILD_NUMBER="${PRIVATEAI_BUILD_NUMBER:-}"

if [[ -n "$BUILD_NUMBER" && ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "PRIVATEAI_BUILD_NUMBER must contain only decimal digits." >&2
  exit 1
fi

build_number_setting=()
if [[ -n "$BUILD_NUMBER" ]]; then
  build_number_setting+=(CURRENT_PROJECT_VERSION="$BUILD_NUMBER")
fi

required=(APPLE_TEAM_ID NOTARY_KEY_ID NOTARY_ISSUER_ID NOTARY_KEY_PATH)
missing=()
for name in "${required[@]}"; do
  [[ -n "${!name:-}" ]] || missing+=("$name")
done
if (( ${#missing[@]} > 0 )); then
  printf 'Missing required release configuration: %s\n' "${missing[*]}" >&2
  exit 1
fi

[[ -f "$NOTARY_KEY_PATH" ]] || {
  echo "NOTARY_KEY_PATH does not point to a file." >&2
  exit 1
}

rm -rf "$OUTPUT_DIRECTORY"
mkdir -p "$OUTPUT_DIRECTORY"

xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE_PATH" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY='Developer ID Application' \
  DEVELOPMENT_TEAM="$APPLE_TEAM_ID" \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  PRIVATEAI_PRIVACY_POLICY_URL="$PRIVACY_POLICY_URL" \
  OTHER_CODE_SIGN_FLAGS='--timestamp --options runtime' \
  "${build_number_setting[@]}"

[[ -d "$APP_PATH" ]] || {
  echo "Archive did not contain $APP_NAME." >&2
  exit 1
}

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
identity="$(codesign -dv --verbose=4 "$APP_PATH" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
[[ "$identity" == Developer\ ID\ Application:* ]] || {
  echo "Archive is not signed with Developer ID Application." >&2
  exit 1
}

actual_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Contents/Info.plist")"
[[ "$actual_bundle_id" == "$BUNDLE_ID" ]] || {
  echo "Unexpected bundle identifier in signed app." >&2
  exit 1
}

mkdir -p "$STAGING_DIRECTORY"
ditto "$APP_PATH" "$STAGING_DIRECTORY/$APP_NAME"
ln -s /Applications "$STAGING_DIRECTORY/Applications"
hdiutil create \
  -volname 'Private AI' \
  -srcfolder "$STAGING_DIRECTORY" \
  -ov \
  -format UDZO \
  "$DMG_PATH"
codesign --force --timestamp --sign "$identity" "$DMG_PATH"
codesign --verify --strict --verbose=2 "$DMG_PATH"

xcrun notarytool submit "$DMG_PATH" \
  --key "$NOTARY_KEY_PATH" \
  --key-id "$NOTARY_KEY_ID" \
  --issuer "$NOTARY_ISSUER_ID" \
  --wait

xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH"
(
  cd "$OUTPUT_DIRECTORY"
  shasum -a 256 "$(basename "$DMG_PATH")" > "$(basename "$DMG_PATH").sha256"
)

printf 'Created notarized release:\n%s\n%s\n' "$DMG_PATH" "$DMG_PATH.sha256"
