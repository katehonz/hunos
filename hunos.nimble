version     = "1.3.4"
author      = "Hunos Project"
description = "High-performance multi-threaded HTTP 1.1 and WebSocket server for Nim"
license     = "MIT"

srcDir = "src"

requires "nim >= 2.0.0"
requires "zippy >= 0.10.0"
requires "checksums >= 0.1.0"

# Explicit test task so CI and local runs share one entry point.
# Excludes benches (bench_*) and wrk helpers.
task test, "Run the Hunos unit/integration test suite":
  exec """bash -c 'set -euo pipefail
    shopt -s nullglob
    files=(tests/test_*.nim)
    if [ ${#files[@]} -eq 0 ]; then
      echo "No tests/test_*.nim files found" >&2
      exit 1
    fi
    for f in "${files[@]}"; do
      echo "=== $f ==="
      nim c -r --threads:on --mm:orc --path:src "$f"
    done
    echo "All tests passed"
  '"""
