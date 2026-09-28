#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build dist
APP="$(pwd)/dist/QQ排程助手.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc -swift-version 5 -O -parse-as-library -target arm64-apple-macosx14.0 -module-cache-path "$(pwd)/build/module-cache" Sources/Core.swift Sources/License.swift Sources/Theme.swift Sources/Progress3D.swift Sources/UnifiedCompose.swift Sources/TodayTimeline.swift Sources/ImageAttachment.swift Sources/ImageDropTarget.swift Sources/TextTemplateRow.swift Sources/QQDriver.swift Sources/WeChatDriver.swift Sources/RelationshipInbox.swift Sources/AuthUI.swift Sources/App.swift -o "$APP/Contents/MacOS/QQDispatch" -framework SwiftUI -framework AppKit -framework ApplicationServices -framework Security -lsqlite3
cp Info.plist "$APP/Contents/Info.plist"
xcrun swiftc Sources/Icon.swift -o build/draw-icon -framework AppKit
build/draw-icon build/icon.png
mkdir -p build/AppIcon.iconset
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" build/icon.png --out "build/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" build/icon.png --out "build/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
bash Tools/sign-app.sh "$APP"
echo "$APP"
