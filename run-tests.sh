#!/bin/zsh
# Builds and runs the logic tests. Uses disposable folders only; never touches your real log.
set -e
cd "$(dirname "$0")"
mkdir -p build
swiftc -O Sources/Core/*.swift Tests/main.swift -o build/pf-tests
./build/pf-tests fixtures/2026-10-28.md
