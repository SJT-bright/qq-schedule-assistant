#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build docs/manual-wechat-bridge-20260926
xcrun swiftc -swift-version 5 -D RENDER_HARNESS -parse-as-library -module-cache-path "$(pwd)/build/module-cache" \
  Sources/Core.swift Sources/MultiQueue.swift Sources/HistoryArchive.swift Sources/QueueSchedule.swift Sources/License.swift Sources/Theme.swift Sources/Progress3D.swift Sources/UnifiedCompose.swift \
  Sources/TodayTimeline.swift Sources/ImageAttachment.swift Sources/ImageDropTarget.swift Sources/TextTemplateRow.swift \
  Sources/QQDriver.swift Sources/WeChatDriver.swift Sources/RelationshipInbox.swift Sources/AuthUI.swift Sources/App.swift \
  Tests/RelationshipInboxRender.swift -o build/relationship-inbox-render \
  -framework SwiftUI -framework AppKit -framework ApplicationServices -framework Security -lsqlite3
build/relationship-inbox-render "$(pwd)/docs/manual-wechat-bridge-20260926/inbox-isolated.png"
