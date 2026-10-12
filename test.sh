#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
python3 Tests/OldVersionCleanupTests.py
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$(pwd)/build/module-cache" Sources/Core.swift Tests/CoreTests.swift -o build/core-tests -lsqlite3
build/core-tests
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$(pwd)/build/module-cache" Sources/Core.swift Sources/ImageAttachment.swift Sources/ImageDropTarget.swift Tests/ImageTests.swift -o build/image-tests -framework AppKit -framework SwiftUI -lsqlite3
build/image-tests
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$(pwd)/build/module-cache" Sources/Core.swift Tests/QQTransitionTests.swift -o build/qq-transition-tests -lsqlite3
build/qq-transition-tests
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$(pwd)/build/module-cache" Sources/Core.swift Tests/WindowPlacementTests.swift -o build/window-placement-tests -lsqlite3
build/window-placement-tests
xcrun swiftc -swift-version 5 -D RENDER_HARNESS -parse-as-library -module-cache-path "$(pwd)/build/module-cache" \
  Sources/Core.swift Sources/MultiQueue.swift Sources/HistoryArchive.swift Sources/QueueSchedule.swift Sources/License.swift Sources/Theme.swift Sources/Progress3D.swift Sources/UnifiedCompose.swift \
  Sources/TodayTimeline.swift Sources/ImageAttachment.swift Sources/ImageDropTarget.swift Sources/TextTemplateRow.swift \
  Sources/QQDriver.swift Sources/WeChatDriver.swift Sources/RelationshipInbox.swift Sources/Notifications.swift \
  Sources/AuthUI.swift Sources/App.swift Tests/SchedulerStoreTests.swift -o build/scheduler-store-tests \
  -framework SwiftUI -framework AppKit -framework ApplicationServices -framework Security -framework UserNotifications -lsqlite3
QQ_DISPATCH_NO_SEND=1 build/scheduler-store-tests
xcrun swiftc -swift-version 5 -D RENDER_HARNESS -parse-as-library -module-cache-path "$(pwd)/build/module-cache" \
  Sources/Core.swift Sources/MultiQueue.swift Sources/HistoryArchive.swift Sources/QueueSchedule.swift Sources/License.swift Sources/Theme.swift Sources/Progress3D.swift Sources/UnifiedCompose.swift \
  Sources/TodayTimeline.swift Sources/ImageAttachment.swift Sources/ImageDropTarget.swift Sources/TextTemplateRow.swift \
  Sources/QQDriver.swift Sources/WeChatDriver.swift Sources/RelationshipInbox.swift Sources/Notifications.swift \
  Sources/AuthUI.swift Sources/App.swift Tests/VerificationStoreTests.swift -o build/verification-store-tests \
  -framework SwiftUI -framework AppKit -framework ApplicationServices -framework Security -framework UserNotifications -lsqlite3
QQ_DISPATCH_NO_SEND=1 build/verification-store-tests

xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$(pwd)/build/module-cache" Sources/Core.swift Sources/MultiQueue.swift Tests/MultiQueueTests.swift -o build/multi-queue-tests -lsqlite3
build/multi-queue-tests
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$(pwd)/build/module-cache" Sources/Core.swift Sources/HistoryArchive.swift Tests/HistoryArchiveTests.swift -o build/history-archive-tests -lsqlite3
build/history-archive-tests

xcrun swiftc -swift-version 5 -D RENDER_HARNESS -parse-as-library -module-cache-path "$(pwd)/build/module-cache" \
 Sources/Core.swift Sources/MultiQueue.swift Sources/HistoryArchive.swift Sources/QueueSchedule.swift Sources/License.swift Sources/Theme.swift Sources/Progress3D.swift Sources/UnifiedCompose.swift \
 Sources/TodayTimeline.swift Sources/ImageAttachment.swift Sources/ImageDropTarget.swift Sources/TextTemplateRow.swift Sources/QQDriver.swift Sources/WeChatDriver.swift \
 Sources/RelationshipInbox.swift Sources/Notifications.swift Sources/AuthUI.swift Sources/App.swift Tests/MultiQueueStoreTests.swift \
 -o build/multi-queue-store-tests -framework SwiftUI -framework AppKit -framework ApplicationServices -framework Security -framework UserNotifications -lsqlite3
QQ_DISPATCH_NO_SEND=1 build/multi-queue-store-tests

# 排期修改仅在隔离库和假驱动中验收，不启动正式发送。
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$(pwd)/build/module-cache" Sources/Core.swift Sources/QueueSchedule.swift Tests/QueueScheduleTests.swift -o build/queue-schedule-tests -lsqlite3
build/queue-schedule-tests
xcrun swiftc -swift-version 5 -D RENDER_HARNESS -parse-as-library -module-cache-path "$(pwd)/build/module-cache" \
 Sources/Core.swift Sources/MultiQueue.swift Sources/HistoryArchive.swift Sources/QueueSchedule.swift Sources/License.swift Sources/Theme.swift Sources/Progress3D.swift Sources/UnifiedCompose.swift \
 Sources/TodayTimeline.swift Sources/ImageAttachment.swift Sources/ImageDropTarget.swift Sources/TextTemplateRow.swift Sources/QQDriver.swift Sources/WeChatDriver.swift \
 Sources/RelationshipInbox.swift Sources/Notifications.swift Sources/AuthUI.swift Sources/App.swift Tests/QueueScheduleStoreTests.swift \
 -o build/queue-schedule-store-tests -framework SwiftUI -framework AppKit -framework ApplicationServices -framework Security -framework UserNotifications -lsqlite3
QQ_DISPATCH_NO_SEND=1 build/queue-schedule-store-tests

# 核对后重发只使用临时数据库与假驱动。
xcrun swiftc -swift-version 5 -D RENDER_HARNESS -parse-as-library -module-cache-path "$(pwd)/build/module-cache" \
 Sources/Core.swift Sources/MultiQueue.swift Sources/HistoryArchive.swift Sources/QueueSchedule.swift Sources/License.swift Sources/Theme.swift Sources/Progress3D.swift Sources/UnifiedCompose.swift \
 Sources/TodayTimeline.swift Sources/ImageAttachment.swift Sources/ImageDropTarget.swift Sources/TextTemplateRow.swift Sources/QQDriver.swift Sources/WeChatDriver.swift \
 Sources/RelationshipInbox.swift Sources/Notifications.swift Sources/AuthUI.swift Sources/App.swift Tests/ReviewedResendStoreTests.swift \
 -o build/reviewed-resend-store-tests -framework SwiftUI -framework AppKit -framework ApplicationServices -framework Security -framework UserNotifications -lsqlite3
QQ_DISPATCH_NO_SEND=1 build/reviewed-resend-store-tests

# 成功音与收窗只用假驱动，以及测试进程自己的原生窗口。
xcrun swiftc -swift-version 5 -D RENDER_HARNESS -parse-as-library -module-cache-path "$(pwd)/build/module-cache" \
 Sources/Core.swift Sources/MultiQueue.swift Sources/HistoryArchive.swift Sources/QueueSchedule.swift Sources/License.swift Sources/Theme.swift Sources/Progress3D.swift Sources/UnifiedCompose.swift \
 Sources/TodayTimeline.swift Sources/ImageAttachment.swift Sources/ImageDropTarget.swift Sources/TextTemplateRow.swift Sources/QQDriver.swift Sources/WeChatDriver.swift \
 Sources/RelationshipInbox.swift Sources/Notifications.swift Sources/AuthUI.swift Sources/App.swift Tests/SendPresentationStoreTests.swift \
 -o build/send-presentation-store-tests -framework SwiftUI -framework AppKit -framework ApplicationServices -framework Security -framework UserNotifications -lsqlite3
QQ_DISPATCH_NO_SEND=1 build/send-presentation-store-tests

# 限量、取消整队重开与两种核对决定：隔离资料及假驱动，不打开正式聊天。
xcrun swiftc -swift-version 5 -D RENDER_HARNESS -parse-as-library -module-cache-path "$(pwd)/build/module-cache" \
 Sources/Core.swift Sources/MultiQueue.swift Sources/HistoryArchive.swift Sources/QueueSchedule.swift Sources/License.swift Sources/Theme.swift Sources/Progress3D.swift Sources/UnifiedCompose.swift \
 Sources/TodayTimeline.swift Sources/ImageAttachment.swift Sources/ImageDropTarget.swift Sources/TextTemplateRow.swift Sources/QQDriver.swift Sources/WeChatDriver.swift \
 Sources/RelationshipInbox.swift Sources/Notifications.swift Sources/AuthUI.swift Sources/App.swift Tests/QueueWorkflowStoreTests.swift \
 -o build/queue-workflow-store-tests -framework SwiftUI -framework AppKit -framework ApplicationServices -framework Security -framework UserNotifications -lsqlite3
QQ_DISPATCH_NO_SEND=1 build/queue-workflow-store-tests
