#!/bin/zsh
set -eu
cd "${0:A:h:h}"
mkdir -p build
.venv/bin/python -m unittest discover -s tests -p 'test_*.py' -v
for check in ChatInputChecks FocusReadinessChecks LocalizationChecks NativeChecks WorkerCancelChecks SettingsChecks VoiceOverlayChecks DownloadProcessChecks ResourceChecks; do
    sources=(Sources/*.swift)
    sources=(${sources:#Sources/main.swift})
    xcrun swiftc -swift-version 5 "${sources[@]}" "tests/${check}.swift" -o "build/${check}"
    "build/${check}"
done
