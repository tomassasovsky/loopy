#!/usr/bin/env bash
# Build + run the spike D0 time-stretch benchmark (NOT part of the test gate).
# Usage: ./bench.sh [--wav <dir>]
set -euo pipefail
cd "$(dirname "$0")"

CXX=${CXX:-c++}
$CXX -std=c++17 -O2 -DNDEBUG -o bench_stretch bench_stretch.cpp

./bench_stretch "$@"
