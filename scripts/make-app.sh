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
    <string>en</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>ja</string>
        <string>en</string>
    </array>
    <key>CFBundleExecutable</key>
    <string>DiskUsage</string>
    <key>CFBundleIdentifier</key>
    <string>io.github.cc-pine.DiskUsage</string>
    <key>CFBundleName</key>
    <string>DiskUsage</string>
    <key>CFBundleDisplayName</key>
    <string>Disk Usage</string>
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
    <!-- Finder と Dock で ja.lproj / en.lproj の CFBundleDisplayName を使う -->
    <key>LSHasLocalizedDisplayName</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

# 対応言語を macOS に知らせ、システム設定の「アプリごとの言語」で選べるようにする。
# 画面の文言はアプリ内の対訳表（DiskUsageCore の L10n）から引くため、ここではアプリ名だけを訳す。
for language in ja en; do
    mkdir -p "$app/Contents/Resources/$language.lproj"
done
cat > "$app/Contents/Resources/ja.lproj/InfoPlist.strings" <<'STRINGS'
"CFBundleDisplayName" = "ディスク使用量";
"CFBundleName" = "ディスク使用量";
STRINGS
cat > "$app/Contents/Resources/en.lproj/InfoPlist.strings" <<'STRINGS'
"CFBundleDisplayName" = "Disk Usage";
"CFBundleName" = "Disk Usage";
STRINGS

# 開発用の ad-hoc 署名。配布用の署名・公証は行わない。
codesign --force --sign - "$app"
echo "Built $app"
