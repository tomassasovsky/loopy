#!/usr/bin/env bash
# run_tests.sh - builds and runs the pedal-protocol host contract test
# (test_pedal_protocol.c) against BOTH in-repo protocol copies:
#
#   * firmware/segno_pedal/pedal_protocol.{h,c}            (primary)
#   * hardware/firmware/segno_pedal_32u4/pedal_protocol.{h,c}  (32u4 mirror)
#
# The two copies must stay byte-for-byte identical (each sketch #includes its
# own local copy) -- this script is the drift gate [R9][R10]: it first diffs
# the copies for a clear failure message, then compiles and runs the contract
# test against each, so CI and the local verify loop run the identical check.
#
# Run from anywhere; the script cd's to the repo root so the default golden
# fixtures path (packages/pedal_repository/test/fixtures) resolves.
set -euo pipefail

cd "$(dirname "$0")/../.."

PRIMARY=firmware/segno_pedal
MIRROR=hardware/firmware/segno_pedal_32u4

for f in pedal_protocol.h pedal_protocol.c; do
  if ! diff -u "$PRIMARY/$f" "$MIRROR/$f"; then
    echo "FAIL: $PRIMARY/$f and $MIRROR/$f have drifted." >&2
    echo "The two protocol copies must be byte-for-byte identical;" >&2
    echo "edit the primary copy and re-copy it into the mirror." >&2
    exit 1
  fi
done

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

for tree in "$PRIMARY" "$MIRROR"; do
  echo "== contract test against $tree =="
  gcc -std=c11 -Wall -I "$tree" \
    firmware/test/test_pedal_protocol.c "$tree/pedal_protocol.c" \
    -o "$BUILD_DIR/pedal_protocol_tests"
  "$BUILD_DIR/pedal_protocol_tests"
done

echo "run_tests.sh: both protocol copies pass"
