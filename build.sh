#!/bin/bash

set -e  # Exit on error

export SCHEME_NAME=ViewTheWord
export XCODE_PROJECT_PATH=$(find . -name ${SCHEME_NAME}.xcodeproj)
export ARCHIVE_TMP_DIR=$(mktemp -d)
export BUILD_DIR="./build"

echo "Archive directory: $ARCHIVE_TMP_DIR"

# pre-cleanup
find . -maxdepth 1 -name \*.dmg -exec rm -f {} \; 2>&1 >/dev/null
rm -rf ${BUILD_DIR} 2>&1 >/dev/null
mkdir -p ${BUILD_DIR}

function archive () {
    echo "Building and archiving..."
    xcodebuild archive \
        -scheme ${SCHEME_NAME} \
        -project $XCODE_PROJECT_PATH \
        -configuration Release \
        -archivePath ${ARCHIVE_TMP_DIR} \
        -destination "platform=macOS,arch=arm64" \
        COPY_PHASE_STRIP=YES \
        STRIP_INSTALLED_PRODUCT=YES \
        DEPLOYMENT_POSTPROCESSING=YES \
        | grep -E "^(Build|Archive|error|warning|note:)" || true

    echo "Archive created at: ${ARCHIVE_TMP_DIR}.xcarchive"
}

function exportArchive () {
    echo "Exporting archive..."
    export EXPORT_OPTIONS_PLIST=$(mktemp)
    cat << EOF > ${EXPORT_OPTIONS_PLIST}
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
   	<key>method</key>
   	<string>mac-application</string>
   	<key>stripSwiftSymbols</key>
   	<true/>
</dict>
</plist>
EOF
    xcodebuild -exportArchive \
        -archivePath ${ARCHIVE_TMP_DIR}.xcarchive \
        -exportOptionsPlist ${EXPORT_OPTIONS_PLIST} \
        -exportPath ${BUILD_DIR} \
        | grep -E "^(Export|error|warning|note:)" || true

    echo "App exported to: ${BUILD_DIR}"

    # Show binary info
    if [ -f "${BUILD_DIR}/${SCHEME_NAME}.app/Contents/MacOS/${SCHEME_NAME}" ]; then
        echo ""
        echo "Binary information:"
        echo "=================="
        ls -lh "${BUILD_DIR}/${SCHEME_NAME}.app/Contents/MacOS/${SCHEME_NAME}"
        file "${BUILD_DIR}/${SCHEME_NAME}.app/Contents/MacOS/${SCHEME_NAME}"

        # Check if symbols are stripped
        if nm "${BUILD_DIR}/${SCHEME_NAME}.app/Contents/MacOS/${SCHEME_NAME}" 2>&1 | grep -q "no symbols"; then
            echo "✓ Symbols are STRIPPED"
        else
            echo "⚠ Warning: Symbols may not be fully stripped"
        fi
    fi

    rm -f ${EXPORT_OPTIONS_PLIST}
}

function createDMG () {
    echo ""
    echo "Creating DMG..."

    DMG_NAME="${SCHEME_NAME}-$(date +%Y%m%d-%H%M%S).dmg"

    # Create DMG
    hdiutil create -volname "${SCHEME_NAME}" \
        -srcfolder "${BUILD_DIR}/${SCHEME_NAME}.app" \
        -ov -format UDZO \
        "${DMG_NAME}"

    echo "✓ DMG created: ${DMG_NAME}"
    ls -lh "${DMG_NAME}"
}

# Run the build process
archive && exportArchive && createDMG

echo ""
echo "Build complete!"
echo "==============="
echo "App bundle: ${BUILD_DIR}/${SCHEME_NAME}.app"
echo "DMG file: ${DMG_NAME}"
