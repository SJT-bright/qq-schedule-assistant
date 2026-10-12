#!/bin/bash
# 把每个页面离屏渲染成 PNG，便于在没有屏幕录制权限时检查 UI。
# 用法：bash render.sh [输出目录]
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
OUT="${1:-/tmp/qqsched-renders}"
xcrun swiftc -swift-version 5 -D RENDER_HARNESS -parse-as-library -module-cache-path "$(pwd)/build/module-cache" \
  Sources/Core.swift Sources/MultiQueue.swift Sources/HistoryArchive.swift Sources/QueueSchedule.swift Sources/License.swift Sources/Theme.swift Sources/Progress3D.swift Sources/UnifiedCompose.swift \
  Sources/TodayTimeline.swift Sources/ImageAttachment.swift Sources/ImageDropTarget.swift \
  Sources/TextTemplateRow.swift Sources/QQDriver.swift Sources/WeChatDriver.swift Sources/RelationshipInbox.swift \
  Sources/Notifications.swift Sources/AuthUI.swift Sources/App.swift Tools/RenderHarness.swift \
  -o build/render-harness -framework SwiftUI -framework AppKit -framework ApplicationServices -framework Security -framework UserNotifications -lsqlite3
mkdir -p "$OUT"
build/render-harness "$OUT"
rm -rf "$OUT/data" "$OUT/data-login"
