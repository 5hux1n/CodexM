#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p build/Verification
swiftc -swift-version 6 -parse-as-library CodexM/Models/Models.swift CodexM/Storage/ProfileStore.swift CodexM/Handoff/HandoffModels.swift CodexM/Handoff/TranscriptParser.swift CodexM/Migration/NativeMigrationModels.swift CodexM/Migration/NativeMigrationFiles.swift CodexM/Migration/NativeRoundTrip.swift CodexM/Migration/NativeHistoryLoader.swift CodexM/Migration/NativeMigrationCoordinator.swift tests/NativeRoundTripTests.swift -o build/native-round-trip-tests -lsqlite3
build/native-round-trip-tests "${1:-/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex}"
