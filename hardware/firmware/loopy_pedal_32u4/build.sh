#!/usr/bin/env bash
# Build the Pro Micro (32U4) pedal firmware to a flashable .hex.
#
# The single source of truth for HOW this firmware is compiled. Both CI jobs
# call it — the PR gate (main.yaml) so a firmware break fails the PR that caused
# it, and the release job (appliance-release.yml) so the published .hex is
# byte-for-byte the thing the gate proved buildable. Keeping one recipe is the
# point: two copies would drift, and the drift would only surface at release.
#
# Usage: build.sh <out-dir> [version]
#
# Writes:
#   <out-dir>/loopy-pedal-<version>.hex   the firmware image
#   <out-dir>/protocol-version            the wire protocol it speaks ("3")
#
# Requires arduino-cli on PATH with the arduino:avr core installed.
set -euo pipefail

out_dir=${1:?usage: build.sh <out-dir> [version]}
version=${2:-dev}

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$here/../../.." && pwd)
header="$repo_root/firmware/loopy_pedal/pedal_protocol.h"

mkdir -p "$out_dir"

# The build properties are the firmware's identity, not decoration: the custom
# PID keeps CoreMIDI's name cache stable across reflashes, and the product
# string is what console auto-detect matches on (#421). Compiling without them
# yields a .hex that enumerates as a stock "Arduino Leonardo" and never
# auto-binds on a console that has no picker to fall back on.
arduino-cli compile \
    --fqbn arduino:avr:leonardo \
    --build-property 'build.pid=0x7D00' \
    --build-property 'build.usb_product="VAMP Loopstation"' \
    --output-dir "$out_dir/.arduino-out" \
    "$here"

cp "$out_dir/.arduino-out/loopy_pedal_32u4.ino.hex" \
   "$out_dir/loopy-pedal-${version}.hex"
rm -rf "$out_dir/.arduino-out"

# Read the protocol version out of the header rather than restating it here.
# The two header copies are diff-gated (firmware/test/run_tests.sh), so the
# source of truth stays singular and a version bump cannot silently miss the
# published manifest.
alias=$(sed -n 's/^#define PEDAL_PROTOCOL_VERSION  *\(PEDAL_PROTOCOL_VERSION_V[0-9]*\).*/\1/p' "$header" | tail -1)
if [ -z "$alias" ]; then
    echo "build.sh: could not find PEDAL_PROTOCOL_VERSION in $header" >&2
    exit 1
fi
proto=$(sed -n "s/^#define ${alias}  *0x0*\([0-9]*\).*/\1/p" "$header" | tail -1)
if [ -z "$proto" ]; then
    echo "build.sh: could not resolve $alias to a number in $header" >&2
    exit 1
fi
printf '%s\n' "$proto" > "$out_dir/protocol-version"

echo "build.sh: built loopy-pedal-${version}.hex (pedal protocol v${proto})"
