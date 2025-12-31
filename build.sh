#!/bin/bash

export SCHEME_NAME=ViewTheWord
export XCODE_PROJECT_PATH=$(find . -name ${SCHEME_NAME}.xcodeproj)
export ARCHIVE_TMP_DIR=$(mktemp -d)
echo $ARCHIVE_TMP_DIR

# pre-cleanup
find . -maxdepth 1 -name \*.dmg -exec rm -f {} \;2>&1 >/dev/null

function archive () {
    xcodebuild archive \
        -scheme ${SCHEME_NAME} \
        -project $XCODE_PROJECT_PATH \
        -configuration Release \
        -archivePath $ARCHIVE_TMP_DIR \
        -destination "platform=macOS,arch=arm64" \
        -json
}

function exportArchive () {
    export EXPORT_OPTIONS_PLIST=$(mktemp)
    cat << EOF > ${EXPORT_OPTIONS_PLIST}
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
   	<key>method</key>
   	<string>mac-application</string>
</dict>
</plist>
EOF
    xcodebuild -exportArchive \
        -archivePath ${ARCHIVE_TMP_DIR}.xcarchive \
        -exportOptionsPlist ${EXPORT_OPTIONS_PLIST} \
        -exportPath . \
        -json

}

archive && exportArchive
