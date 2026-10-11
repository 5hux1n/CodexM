#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
probe_dir="$PWD/build/LaunchServicesVerification"
mkdir -p "$probe_dir/LaunchServicesProbe.app/Contents/MacOS"
swiftc -swift-version 6 -parse-as-library tests/LaunchServicesProbe.swift -o "$probe_dir/LaunchServicesProbe.app/Contents/MacOS/LaunchServicesProbe"
cat > "$probe_dir/LaunchServicesProbe.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.codexm.launch-services-probe</string>
<key>CFBundleExecutable</key><string>LaunchServicesProbe</string>
<key>CFBundleName</key><string>LaunchServicesProbe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$probe_dir/LaunchServicesProbe.app"
swiftc -swift-version 6 -parse-as-library CodexM/Models/Models.swift CodexM/Runtime/ProcessProbe.swift CodexM/Runtime/CodexRuntime.swift tests/DesktopLaunch.swift -o "$probe_dir/desktop-launch-tests"
"$probe_dir/desktop-launch-tests" "$probe_dir/LaunchServicesProbe.app"
