#!/bin/sh
# Compiles the pure detent math together with its tests into a standalone
# binary and runs it. No Xcode test target needed.
set -e
cd "$(dirname "$0")"
BIN="$(mktemp -d)/detent-tests"
xcrun swiftc -o "$BIN" haptic-slider/DetentMath.swift Tests/main.swift
exec "$BIN"
