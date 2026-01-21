#!/bin/bash

# =============================================================================
# bundle-app.sh - Create macOS Application Bundle from Swift Package Executable
# =============================================================================
#
# This script builds the CommandTab Swift Package and creates a proper macOS
# application bundle (.app) from the resulting executable.
#
# Swift Package Manager produces raw executables, but macOS GUI applications
# need to be bundled with:
#   - Info.plist (application metadata)
#   - Compiled asset catalogs (icons, colors)
#   - Proper directory structure (Contents/MacOS, Contents/Resources)
#
# Usage:
#   ./Scripts/bundle-app.sh           # Build release and create bundle
#   ./Scripts/bundle-app.sh --debug   # Build debug and create bundle
#
# Output:
#   .build/release/CommandTab.app (or .build/debug/CommandTab.app)
#
# =============================================================================

set -e  # Exit immediately if any command fails

# =============================================================================
# MARK: - Configuration
# =============================================================================

# Application name (must match Package.swift executable name)
readonly APP_NAME="CommandTab"

# Bundle identifier (must match Info.plist)
readonly BUNDLE_ID="wudan.command-tab"

# Paths relative to the project root
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Source locations
readonly INFO_PLIST_SOURCE="$PROJECT_ROOT/Supporting/Info.plist"
readonly ASSETS_SOURCE="$PROJECT_ROOT/Sources/CommandTab/Resources/Assets.xcassets"

# =============================================================================
# MARK: - Parse Arguments
# =============================================================================

# Default to release build
BUILD_CONFIGURATION="release"

if [[ "$1" == "--debug" ]]; then
    BUILD_CONFIGURATION="debug"
    echo "Building in DEBUG configuration..."
else
    echo "Building in RELEASE configuration..."
fi

# Build output directory
readonly BUILD_DIR="$PROJECT_ROOT/.build/$BUILD_CONFIGURATION"
readonly EXECUTABLE_PATH="$BUILD_DIR/$APP_NAME"

# Application bundle paths
readonly APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
readonly CONTENTS_DIR="$APP_BUNDLE/Contents"
readonly MACOS_DIR="$CONTENTS_DIR/MacOS"
readonly RESOURCES_DIR="$CONTENTS_DIR/Resources"

# =============================================================================
# MARK: - Build Swift Package
# =============================================================================

echo ""
echo "=============================================="
echo "Step 1: Building Swift Package"
echo "=============================================="

cd "$PROJECT_ROOT"

if [[ "$BUILD_CONFIGURATION" == "release" ]]; then
    swift build -c release
else
    swift build
fi

# Verify the executable was created
if [[ ! -f "$EXECUTABLE_PATH" ]]; then
    echo "ERROR: Executable not found at $EXECUTABLE_PATH"
    echo "Build may have failed."
    exit 1
fi

echo "Executable built successfully: $EXECUTABLE_PATH"

# =============================================================================
# MARK: - Create Application Bundle Structure
# =============================================================================

echo ""
echo "=============================================="
echo "Step 2: Creating Application Bundle Structure"
echo "=============================================="

# Remove any existing bundle
if [[ -d "$APP_BUNDLE" ]]; then
    echo "Removing existing bundle..."
    rm -rf "$APP_BUNDLE"
fi

# Create bundle directories
echo "Creating directory structure..."
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

echo "Bundle structure created at: $APP_BUNDLE"

# =============================================================================
# MARK: - Copy Executable
# =============================================================================

echo ""
echo "=============================================="
echo "Step 3: Copying Executable"
echo "=============================================="

cp "$EXECUTABLE_PATH" "$MACOS_DIR/"
echo "Copied executable to: $MACOS_DIR/$APP_NAME"

# =============================================================================
# MARK: - Copy Info.plist
# =============================================================================

echo ""
echo "=============================================="
echo "Step 4: Copying Info.plist"
echo "=============================================="

if [[ -f "$INFO_PLIST_SOURCE" ]]; then
    cp "$INFO_PLIST_SOURCE" "$CONTENTS_DIR/"
    echo "Copied Info.plist to: $CONTENTS_DIR/Info.plist"
else
    echo "WARNING: Info.plist not found at $INFO_PLIST_SOURCE"
    echo "The application may not behave correctly without Info.plist"
fi

# =============================================================================
# MARK: - Compile Asset Catalog
# =============================================================================

echo ""
echo "=============================================="
echo "Step 5: Compiling Asset Catalog"
echo "=============================================="

if [[ -d "$ASSETS_SOURCE" ]]; then
    echo "Compiling Assets.xcassets..."

    # Use actool (Asset Catalog Tool) to compile the asset catalog
    # This is part of Xcode Command Line Tools
    xcrun actool "$ASSETS_SOURCE" \
        --compile "$RESOURCES_DIR" \
        --platform macosx \
        --minimum-deployment-target 15.0 \
        --app-icon AppIcon \
        --accent-color AccentColor \
        --output-partial-info-plist /dev/null \
        2>/dev/null || {
            echo "WARNING: actool failed or produced warnings."
            echo "This may happen if the asset catalog is empty or has no valid assets."
            echo "The app will still work, but may lack custom icons."
        }

    echo "Asset catalog compiled to: $RESOURCES_DIR"
else
    echo "No asset catalog found at: $ASSETS_SOURCE"
    echo "Skipping asset compilation."
fi

# =============================================================================
# MARK: - Create PkgInfo File
# =============================================================================

echo ""
echo "=============================================="
echo "Step 6: Creating PkgInfo"
echo "=============================================="

# PkgInfo is a simple file that identifies this as an application bundle
# Format: APPL followed by 4-character creator code (or ????)
echo -n "APPL????" > "$CONTENTS_DIR/PkgInfo"
echo "Created PkgInfo file"

# =============================================================================
# MARK: - Summary
# =============================================================================

echo ""
echo "=============================================="
echo "Build Complete!"
echo "=============================================="
echo ""
echo "Application bundle created at:"
echo "  $APP_BUNDLE"
echo ""
echo "To run the application:"
echo "  open \"$APP_BUNDLE\""
echo ""
echo "To code sign (optional, for distribution):"
echo "  codesign --force --deep --sign - \"$APP_BUNDLE\""
echo ""

# =============================================================================
# MARK: - Verify Bundle Contents
# =============================================================================

echo "Bundle contents:"
find "$APP_BUNDLE" -type f | sed 's|^|  |'
echo ""
