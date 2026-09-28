#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
xcrun swiftc -swift-version 5 -D RENDER_HARNESS -parse-as-library -module-cache-path "$(pwd)/build/module-cache" \
  Sources/Core.swift Sources/License.swift Sources/Theme.swift Sources/Progress3D.swift Sources/UnifiedCompose.swift \
  Sources/TodayTimeline.swift Sources/ImageAttachment.swift Sources/ImageDropTarget.swift Sources/TextTemplateRow.swift \
  Sources/QQDriver.swift Sources/WeChatDriver.swift Sources/RelationshipInbox.swift Sources/AuthUI.swift Sources/App.swift \
  Tests/RelationshipInboxTests.swift -o build/relationship-inbox-tests \
  -framework SwiftUI -framework AppKit -framework ApplicationServices -framework Security -lsqlite3
build/relationship-inbox-tests
