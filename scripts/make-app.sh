#!/bin/bash
# DiskUsageApp を開発用の .app バンドルに包む（macOS 専用）。
# usage: scripts/make-app.sh [debug|release]
set -euo pipefail

configuration="${1:-release}"
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

swift build -c "$configuration" --product DiskUsageApp
bin_dir="$(swift build -c "$configuration" --show-bin-path)"

app="$root/build/DiskUsage.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/DiskUsageApp" "$app/Contents/MacOS/DiskUsage"

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>ja</string>
    <key>CFBundleExecutable</key>
    <string>DiskUsage</string>
    <key>CFBundleIdentifier</key>
    <string>io.github.cc-pine.DiskUsage</string>
    <key>CFBundleName</key>
    <string>DiskUsage</string>
    <key>CFBundleDisplayName</key>
    <string>ディスク使用量</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

# 開発用の ad-hoc 署名。配布用の署名・公証は行わない。
codesign --force --sign - "$app"
echo "Built $app"
