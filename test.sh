#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$(pwd)/build/module-cache" Sources/Core.swift Tests/CoreTests.swift -o build/core-tests -lsqlite3
build/core-tests
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$(pwd)/build/module-cache" Sources/Core.swift Sources/ImageAttachment.swift Sources/ImageDropTarget.swift Tests/ImageTests.swift -o build/image-tests -framework AppKit -framework SwiftUI -lsqlite3
build/image-tests
