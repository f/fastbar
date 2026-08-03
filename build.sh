#!/bin/bash
set -euo pipefail

APP_NAME="FastBar"
SCHEME="FastBar"
PROJECT="FastBar/FastBar.xcodeproj"
ENTITLEMENTS="FastBar/FastBar/FastBar.entitlements"
BUILD_DIR="build"
RELEASE_DIR="${BUILD_DIR}/release"
ARM64_DIR="${BUILD_DIR}/arm64"
X86_DIR="${BUILD_DIR}/x86_64"
UNIVERSAL_APP="${RELEASE_DIR}/${APP_NAME}.app"
DMG_STAGE="${BUILD_DIR}/dmg"
DMG_PATH="${RELEASE_DIR}/${APP_NAME}.dmg"

rm -rf "${BUILD_DIR}"
mkdir -p "${RELEASE_DIR}"

build_architecture() {
  local architecture="$1"
  local derived_data="$2"

  xcodebuild \
    -project "${PROJECT}" \
    -scheme "${SCHEME}" \
    -configuration Release \
    -arch "${architecture}" \
    -derivedDataPath "${derived_data}" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    DEVELOPMENT_TEAM="" \
    clean build
}

build_architecture arm64 "${ARM64_DIR}"
build_architecture x86_64 "${X86_DIR}"

ARM64_APP="${ARM64_DIR}/Build/Products/Release/${APP_NAME}.app"
X86_APP="${X86_DIR}/Build/Products/Release/${APP_NAME}.app"

test -d "${ARM64_APP}"
test -d "${X86_APP}"

cp -R "${ARM64_APP}" "${UNIVERSAL_APP}"

lipo -create \
  "${ARM64_APP}/Contents/MacOS/${APP_NAME}" \
  "${X86_APP}/Contents/MacOS/${APP_NAME}" \
  -output "${UNIVERSAL_APP}/Contents/MacOS/${APP_NAME}"

codesign \
  --force \
  --deep \
  --options runtime \
  --sign - \
  --entitlements "${ENTITLEMENTS}" \
  "${UNIVERSAL_APP}"

lipo -info "${UNIVERSAL_APP}/Contents/MacOS/${APP_NAME}"
codesign --verify --deep --strict "${UNIVERSAL_APP}"

mkdir -p "${DMG_STAGE}"
cp -R "${UNIVERSAL_APP}" "${DMG_STAGE}/"
ln -s /Applications "${DMG_STAGE}/Applications"

hdiutil create \
  -volname "${APP_NAME}" \
  -srcfolder "${DMG_STAGE}" \
  -ov \
  -format UDZO \
  "${DMG_PATH}"

shasum -a 256 "${DMG_PATH}"
