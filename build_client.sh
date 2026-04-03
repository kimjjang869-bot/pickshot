#!/bin/bash
set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/build/Client"
APP_NAME="PickShot Client"
BUNDLE_ID="com.pickshot.client"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/$APP_NAME.app/Contents/MacOS"
mkdir -p "$BUILD_DIR/$APP_NAME.app/Contents/Resources"

# Copy Info.plist
cp "$PROJECT_DIR/PickShotClient/Info.plist" "$BUILD_DIR/$APP_NAME.app/Contents/"

# Collect all Swift source files
SOURCES=(
    "$PROJECT_DIR/PickShotClient/PickShotClientApp.swift"
    "$PROJECT_DIR/PhotoRawManager/Models/PhotoItem.swift"
    "$PROJECT_DIR/PhotoRawManager/Models/PhotoStore.swift"
    "$PROJECT_DIR/PhotoRawManager/Services/ExifService.swift"
    "$PROJECT_DIR/PhotoRawManager/Services/FileMatchingService.swift"
    "$PROJECT_DIR/PhotoRawManager/Services/PickshotFileService.swift"
    "$PROJECT_DIR/PhotoRawManager/Services/Logger.swift"
    "$PROJECT_DIR/PhotoRawManager/Services/KeychainService.swift"
    "$PROJECT_DIR/PhotoRawManager/Services/FileCopyService.swift"
    "$PROJECT_DIR/PhotoRawManager/Services/ImageAnalysisService.swift"
    "$PROJECT_DIR/PhotoRawManager/Services/ImageCorrectionService.swift"
    "$PROJECT_DIR/PhotoRawManager/Services/SubscriptionManager.swift"
    "$PROJECT_DIR/PhotoRawManager/Services/GSelectService.swift"
    "$PROJECT_DIR/PhotoRawManager/Services/GoogleDriveService.swift"
    "$PROJECT_DIR/PhotoRawManager/Services/AIVisionService.swift"
    "$PROJECT_DIR/PhotoRawManager/Services/FaceGroupingService.swift"
    "$PROJECT_DIR/PhotoRawManager/Services/TetherService.swift"
    "$PROJECT_DIR/PhotoRawManager/Views/AppTheme.swift"
    "$PROJECT_DIR/PhotoRawManager/Views/PhotoPreviewView.swift"
    "$PROJECT_DIR/PhotoRawManager/Views/ThumbnailGridView.swift"
    "$PROJECT_DIR/PhotoRawManager/Views/HistogramView.swift"
    "$PROJECT_DIR/PhotoRawManager/Views/StarRatingView.swift"
    "$PROJECT_DIR/PhotoRawManager/Views/FilmstripView.swift"
    "$PROJECT_DIR/PhotoRawManager/Views/ClientView.swift"
    "$PROJECT_DIR/PhotoRawManager/Views/SettingsView.swift"
    "$PROJECT_DIR/PhotoRawManager/Views/ExifInfoView.swift"
    "$PROJECT_DIR/PhotoRawManager/Views/ExportView.swift"
    "$PROJECT_DIR/PhotoRawManager/Views/SlideshowView.swift"
    "$PROJECT_DIR/PhotoRawManager/Views/GoogleDriveUploadView.swift"
    "$PROJECT_DIR/PhotoRawManager/Views/AboutView.swift"
    "$PROJECT_DIR/PhotoRawManager/Views/UpdateView.swift"
    "$PROJECT_DIR/PhotoRawManager/Views/TouchBarProvider.swift"
    "$PROJECT_DIR/PhotoRawManager/Views/TetherView.swift"
)

echo "Compiling PickShot Client..."
swiftc -O \
    -target arm64-apple-macosx13.0 \
    -sdk $(xcrun --show-sdk-path) \
    -framework SwiftUI \
    -framework AppKit \
    -framework Vision \
    -framework CoreImage \
    -framework ImageIO \
    -framework Security \
    -framework UniformTypeIdentifiers \
    -framework StoreKit \
    -o "$BUILD_DIR/$APP_NAME.app/Contents/MacOS/PickShotClient" \
    "${SOURCES[@]}" 2>&1

# Copy icon if exists
if [ -d "$PROJECT_DIR/PhotoRawManager/Assets.xcassets/AppIcon.appiconset" ]; then
    cp "$PROJECT_DIR/PhotoRawManager/Assets.xcassets/AppIcon.appiconset/icon_512x512.png" \
       "$BUILD_DIR/$APP_NAME.app/Contents/Resources/AppIcon.png" 2>/dev/null || true
fi

echo "Build complete: $BUILD_DIR/$APP_NAME.app"
