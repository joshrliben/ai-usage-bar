#!/bin/zsh
# Builds AIUsageBar.app into ~/Applications and registers it to launch at login.
set -euo pipefail
here=${0:A:h}
app=~/Applications/AIUsageBar.app
agent=~/Library/LaunchAgents/com.local.aiusagebar.plist

mkdir -p "$app/Contents/MacOS" ~/Library/LaunchAgents
swiftc -O -o "$app/Contents/MacOS/AIUsageBar" "$here/AIUsageBar.swift" 2>&1 | grep -v '^$' || true
[[ -x "$app/Contents/MacOS/AIUsageBar" ]] || { echo "build failed"; exit 1; }

cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.local.aiusagebar</string>
  <key>CFBundleName</key><string>AIUsageBar</string>
  <key>CFBundleExecutable</key><string>AIUsageBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
EOF
codesign --force --sign - "$app" >/dev/null 2>&1

cat > "$agent" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.local.aiusagebar</string>
  <key>ProgramArguments</key><array><string>/usr/bin/open</string><string>-a</string><string>$app</string></array>
  <key>RunAtLoad</key><true/>
</dict></plist>
EOF

pkill -x AIUsageBar 2>/dev/null || true
open "$app"
echo "Installed $app (launches at login via $agent)"
