#!/usr/bin/env bash
set -euo pipefail
PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/slavator-checks.XXXXXX")"
trap 'rm -f "$CHECK_DIR/runtime-checks" "$CHECK_DIR/pipeline-checks" "$CHECK_DIR/memory-checks" "$CHECK_DIR/library-checks" "$CHECK_DIR/chat-checks" "$CHECK_DIR/player-checks" "$CHECK_DIR/recovery-checks"; rmdir "$CHECK_DIR"' EXIT
cd "$PROJECT"
CHECK_ARCH="$(uname -m)"
# SDK под свой компилятор — почему, см. build_app.sh.
if [[ -z "${SDKROOT:-}" && -d "$(xcode-select -p)/SDKs/MacOSX.sdk" ]]; then
    export SDKROOT="$(xcode-select -p)/SDKs/MacOSX.sdk"
fi
swiftc -parse-as-library -target "$CHECK_ARCH-apple-macos14.2" app/Configuration.swift app/ProcessOutput.swift \
    app/tests/RuntimeChecks.swift -o "$CHECK_DIR/runtime-checks"
"$CHECK_DIR/runtime-checks"
swiftc -parse-as-library -target "$CHECK_ARCH-apple-macos14.2" app/Configuration.swift app/ProcessOutput.swift \
    app/Pipeline.swift app/tests/PipelineChecks.swift -o "$CHECK_DIR/pipeline-checks"
"$CHECK_DIR/pipeline-checks"
swiftc -parse-as-library -target "$CHECK_ARCH-apple-macos14.2" app/Configuration.swift app/ProcessOutput.swift \
    app/SpeakerMemory.swift app/tests/MemoryChecks.swift -o "$CHECK_DIR/memory-checks"
"$CHECK_DIR/memory-checks"
swiftc -parse-as-library -target "$CHECK_ARCH-apple-macos14.2" -Xlinker -dead_strip_dylibs \
    app/Configuration.swift app/Theme.swift app/Models.swift app/tests/LibraryChecks.swift -o "$CHECK_DIR/library-checks"
"$CHECK_DIR/library-checks"
swiftc -D CHAT_TESTING -parse-as-library -target "$CHECK_ARCH-apple-macos14.2" -Xlinker -dead_strip_dylibs \
    app/Configuration.swift app/ProcessOutput.swift app/SpeakerMemory.swift app/Chat.swift app/tests/ChatChecks.swift -o "$CHECK_DIR/chat-checks"
"$CHECK_DIR/chat-checks"
swiftc -D PLAYER_TESTING -parse-as-library -target "$CHECK_ARCH-apple-macos14.2" -Xlinker -dead_strip_dylibs \
    app/Configuration.swift app/ProcessOutput.swift app/Player.swift app/tests/PlayerChecks.swift -o "$CHECK_DIR/player-checks"
"$CHECK_DIR/player-checks"
swiftc -parse-as-library -target "$CHECK_ARCH-apple-macos14.2" -Xlinker -dead_strip_dylibs \
    app/Configuration.swift app/Mixdown.swift app/Recovery.swift app/tests/RecoveryChecks.swift -o "$CHECK_DIR/recovery-checks"
"$CHECK_DIR/recovery-checks"
