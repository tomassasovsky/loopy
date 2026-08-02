#!/usr/bin/env bash
# Tests for `loopy-update-ctl flash-pedal` (#331 part D).
#
# The flash itself needs a real Pro Micro and cannot be proven here. What CAN be
# proven — and is the part that matters — is that the script REFUSES in every
# situation where writing would be unsafe, and that it treats "nothing to do" as
# success rather than an error. The pedal has no A/B rollback, so a wrong
# decision here is a trip to a workbench with a sealed enclosure.
#
# Everything the script touches is injected: the manifest is served from a
# file:// URL, the serial directory is a fixture dir, and stubbed `stty` and
# `avrdude` stand in for the hardware. No hardware, no network.
#
# The stubs MODEL THE ENUMERATION CYCLE, which matters more than it sounds: the
# real pedal drops its sketch port on the touch reset, appears as the Caterina
# bootloader under a completely different name, and comes back as the sketch
# after flashing. An earlier harness used a static fixture dir where the port
# never changed, so "wait for the bootloader" trivially succeeded against the
# sketch's own port — and the bug that shipped (avrdude handed a MIDI port,
# hanging the update at 95%) was invisible here while being obvious on device.
set -uo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CTL="$here/../files/loopy-update-ctl"

pass=0
fail=0

setup() {
    work=$(mktemp -d "${TMPDIR:-/tmp}/flash-pedal-test.XXXXXX")
    mkdir -p "$work/channel/production" "$work/serial" "$work/state" "$work/bin"

    printf 'dummy firmware\n' > "$work/channel/production/loopy-pedal-9.9.9.hex"
    hex_sha=$(sha256sum "$work/channel/production/loopy-pedal-9.9.9.hex" | cut -d' ' -f1)

    # Stub `stty`: the 1200bps touch. Swaps the sketch port for the bootloader,
    # which enumerates under Caterina's own name — NOT the product string —
    # exactly as observed on hardware.
    cat > "$work/bin/stty" <<STUB
#!/bin/sh
rm -f "$work/serial"/*VAMP_Loopstation*
touch "$work/serial/usb-Arduino_LLC_Arduino_Leonardo-if00"
exit 0
STUB
    chmod +x "$work/bin/stty"

    # Stub avrdude: records its arguments, then puts the sketch back, standing
    # in for the board re-enumerating once programming finishes.
    cat > "$work/bin/avrdude" <<STUB
#!/bin/sh
echo "\$@" > "$work/avrdude-args"
rm -f "$work/serial"/*Arduino_Leonardo*
touch "$work/serial/usb-Arduino_LLC_VAMP_Loopstation_HIDPC-if00"
exit 0
STUB
    chmod +x "$work/bin/avrdude"
}

teardown() { rm -rf "$work"; }

write_manifest() { cat > "$work/channel/production/manifest.json"; }

attach_pedal() { touch "$work/serial/usb-Arduino_LLC_VAMP_Loopstation_HIDPC-if00"; }
detach_pedal() { rm -f "$work/serial"/*VAMP_Loopstation*; }

run_flash() {
    LOOPY_UPDATE_BASE="file://$work/channel" \
    LOOPY_CHANNEL_FILE="/nonexistent" \
    LOOPY_CHANNEL_OVERRIDE_FILE="/nonexistent" \
    LOOPY_PEDAL_STATE_FILE="$work/state/pedal-firmware-version" \
    LOOPY_PEDAL_FAIL_FILE="$work/state/pedal-firmware-failed" \
    LOOPY_PEDAL_SERIAL_DIR="$work/serial" \
    LOOPY_AVRDUDE="$work/bin/avrdude" \
    LOOPY_PEDAL_PORT_TIMEOUT=3 \
    LOOPY_PEDAL_BOOTLOADER_TRIES=3 \
    LOOPY_AVRDUDE_TIMEOUT="${AVRDUDE_TIMEOUT_OVERRIDE:-120}" \
    PATH="$work/bin:$PATH" \
        sh "$CTL" flash-pedal 2>"$work/stderr"
}

check() {
    local label=$1 expected=$2 actual=$3
    if [ "$expected" = "$actual" ]; then
        echo "  ok   $label"
        pass=$((pass + 1))
    else
        echo "  FAIL $label (expected '$expected', got '$actual')"
        [ -s "$work/stderr" ] && sed 's/^/       | /' "$work/stderr"
        fail=$((fail + 1))
    fi
}

flashed() { [ -f "$work/avrdude-args" ] && echo yes || echo no; }

# --- "nothing to do" is success, not failure -------------------------------

echo "manifest with no pedalFirmware block"
setup
write_manifest <<'JSON'
{ "version": "1.0.0", "bundle": "b.raucb", "sha256": "x", "channel": "production" }
JSON
attach_pedal
run_flash; rc=$?
check "exits 0 (an OS-only release is normal)" 0 "$rc"
check "does not flash" no "$(flashed)"
teardown

echo "pedal already runs the published version"
setup
write_manifest <<JSON
{ "version": "1.0.0", "bundle": "b.raucb", "channel": "production",
  "pedalFirmware": { "version": "9.9.9", "hex": "loopy-pedal-9.9.9.hex",
                     "protocolVersion": 3, "sha256": "$hex_sha" } }
JSON
attach_pedal
echo "9.9.9 3" > "$work/state/pedal-firmware-version"
run_flash; rc=$?
check "exits 0" 0 "$rc"
check "does not reflash the same version" no "$(flashed)"
teardown

# --- refusals ---------------------------------------------------------------

echo "pedal not attached"
setup
write_manifest <<JSON
{ "version": "1.0.0", "bundle": "b.raucb", "channel": "production",
  "pedalFirmware": { "version": "9.9.9", "hex": "loopy-pedal-9.9.9.hex",
                     "protocolVersion": 3, "sha256": "$hex_sha" } }
JSON
detach_pedal
run_flash; rc=$?
check "refuses (exit 1)" 1 "$rc"
check "does not flash" no "$(flashed)"
teardown

echo "manifest publishes no sha256"
setup
write_manifest <<'JSON'
{ "version": "1.0.0", "bundle": "b.raucb", "channel": "production",
  "pedalFirmware": { "version": "9.9.9", "hex": "loopy-pedal-9.9.9.hex",
                     "protocolVersion": 3 } }
JSON
attach_pedal
run_flash; rc=$?
check "refuses unverified firmware" 1 "$rc"
check "does not flash" no "$(flashed)"
teardown

echo "sha256 mismatch (corrupted download)"
setup
write_manifest <<'JSON'
{ "version": "1.0.0", "bundle": "b.raucb", "channel": "production",
  "pedalFirmware": { "version": "9.9.9", "hex": "loopy-pedal-9.9.9.hex",
                     "protocolVersion": 3, "sha256": "0000000000000000000000000000000000000000000000000000000000000000" } }
JSON
attach_pedal
run_flash; rc=$?
check "refuses on checksum mismatch" 1 "$rc"
check "does not flash" no "$(flashed)"
teardown

echo "published .hex missing from the channel"
setup
write_manifest <<JSON
{ "version": "1.0.0", "bundle": "b.raucb", "channel": "production",
  "pedalFirmware": { "version": "9.9.9", "hex": "does-not-exist.hex",
                     "protocolVersion": 3, "sha256": "$hex_sha" } }
JSON
attach_pedal
run_flash; rc=$?
check "refuses when the download fails" 1 "$rc"
check "does not flash" no "$(flashed)"
teardown

# --- the happy path ---------------------------------------------------------

echo "attached pedal, verified firmware"
setup
write_manifest <<JSON
{ "version": "1.0.0", "bundle": "b.raucb", "channel": "production",
  "pedalFirmware": { "version": "9.9.9", "hex": "loopy-pedal-9.9.9.hex",
                     "protocolVersion": 3, "sha256": "$hex_sha" } }
JSON
attach_pedal
run_flash; rc=$?
check "exits 0" 0 "$rc"
check "runs avrdude" yes "$(flashed)"
check "targets the 32U4 over avr109" yes \
    "$(grep -q -- '-p atmega32u4' "$work/avrdude-args" && grep -q -- '-c avr109' "$work/avrdude-args" && echo yes || echo no)"
# -V disables avrdude's readback verification; it must never be passed here.
check "does not disable verification" yes \
    "$(grep -qE '(^| )-V( |$)' "$work/avrdude-args" && echo no || echo yes)"
# THE regression assertion. avrdude must be pointed at the port that appeared
# after the reset, not at the pedal's own MIDI port — targeting the sketch is
# what hung a real update at 95%.
check "targets the BOOTLOADER port, not the sketch" yes \
    "$(grep -q 'Arduino_Leonardo' "$work/avrdude-args" && echo yes || echo no)"
check "never targets the sketch port" yes \
    "$(grep -q 'VAMP_Loopstation' "$work/avrdude-args" && echo no || echo yes)"
check "records the flashed version + protocol" "9.9.9 3" \
    "$(cat "$work/state/pedal-firmware-version" 2>/dev/null)"
check "leaves no failure marker" no \
    "$([ -f "$work/state/pedal-firmware-failed" ] && echo yes || echo no)"
teardown

# --- failure leaves a legible trail -----------------------------------------

echo "avrdude fails mid-write"
setup
write_manifest <<JSON
{ "version": "1.0.0", "bundle": "b.raucb", "channel": "production",
  "pedalFirmware": { "version": "9.9.9", "hex": "loopy-pedal-9.9.9.hex",
                     "protocolVersion": 3, "sha256": "$hex_sha" } }
JSON
attach_pedal
cat > "$work/bin/avrdude" <<'STUB'
#!/bin/sh
echo "avrdude: programmer is not responding" >&2
exit 1
STUB
chmod +x "$work/bin/avrdude"
run_flash; rc=$?
check "reports failure" 1 "$rc"
check "writes the failure marker for the UI" yes \
    "$([ -f "$work/state/pedal-firmware-failed" ] && echo yes || echo no)"
check "does not record a version it did not flash" no \
    "$([ -f "$work/state/pedal-firmware-version" ] && echo yes || echo no)"
teardown

# --- the two failure modes the on-device run actually hit ----------------------

echo "touch reset produces no bootloader"
setup
write_manifest <<JSON
{ "version": "1.0.0", "bundle": "b.raucb", "channel": "production",
  "pedalFirmware": { "version": "9.9.9", "hex": "loopy-pedal-9.9.9.hex",
                     "protocolVersion": 3, "sha256": "$hex_sha" } }
JSON
attach_pedal
# A touch that does nothing: the sketch port stays and no new port appears.
cat > "$work/bin/stty" <<'STUB'
#!/bin/sh
exit 0
STUB
chmod +x "$work/bin/stty"
run_flash; rc=$?
check "refuses rather than flashing the sketch" 1 "$rc"
check "does not run avrdude at all" no "$(flashed)"
teardown

echo "avrdude hangs on an unresponsive port"
setup
write_manifest <<JSON
{ "version": "1.0.0", "bundle": "b.raucb", "channel": "production",
  "pedalFirmware": { "version": "9.9.9", "hex": "loopy-pedal-9.9.9.hex",
                     "protocolVersion": 3, "sha256": "$hex_sha" } }
JSON
attach_pedal
cat > "$work/bin/avrdude" <<STUB
#!/bin/sh
echo "\$@" > "$work/avrdude-args"
sleep 30
STUB
chmod +x "$work/bin/avrdude"
# Without the timeout this blocks forever and takes the update UI with it.
AVRDUDE_TIMEOUT_OVERRIDE=1 run_flash; rc=$?
check "gives up instead of hanging" 1 "$rc"
check "reports the timeout" yes \
    "$(grep -q 'timed out' "$work/stderr" && echo yes || echo no)"
check "writes the failure marker" yes \
    "$([ -f "$work/state/pedal-firmware-failed" ] && echo yes || echo no)"
teardown

echo
echo "flash-pedal: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
echo "ALL PASSED"
