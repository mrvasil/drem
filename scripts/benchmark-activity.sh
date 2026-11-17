#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
BENCHMARK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/drem-benchmark.XXXXXX")"
trap 'rm -rf "$BENCHMARK_DIR"' EXIT
swiftc -O -parse-as-library Sources/DremCore/*.swift scripts/benchmark-activity.swift -o "$BENCHMARK_DIR/benchmark"
"$BENCHMARK_DIR/benchmark"
