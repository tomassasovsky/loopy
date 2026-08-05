#!/usr/bin/env bash
# Tests for `segno-bt-ctl`'s device verbs and the detail its scan reports
# (#498, the console's Network domain).
#
# `bluetoothctl` is stubbed: these assert the ORDER and SHAPE of the commands
# the helper issues, which is the part the console depends on and the part
# that cannot be checked from Dart. What they deliberately do not assert is
# whether bluez then does the right thing — that needs a radio and a device,
# and is verified on the appliance.
#
# Why the order matters: `forget` has to disconnect before removing (bluez
# leaves a live link behind otherwise), and `pair` has to trust before
# connecting, or the device cannot reconnect on its own after a reboot.
set -uo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SCRIPT="$here/../files/segno-bt-ctl"

pass=0
fail=0

setup() {
    work=$(mktemp -d "${TMPDIR:-/tmp}/bt-ctl-test.XXXXXX")
    mkdir -p "$work/bin"
    : > "$work/calls"
    cat > "$work/bin/bluetoothctl" <<STUB
#!/bin/sh
echo "\$@" >> "$work/calls"
case "\$*" in
    *"devices"*)
        echo "Device AA:BB:CC:DD:EE:FF Studio Cans"
        ;;
    *"info AA:BB:CC:DD:EE:FF"*)
        echo "Paired: yes"
        echo "Connected: yes"
        echo "Icon: audio-headset"
        ;;
esac
exit \${SEGNO_STUB_EXIT:-0}
STUB
    chmod +x "$work/bin/bluetoothctl"
}

teardown() { rm -rf "$work"; }

run_ctl() {
    SEGNO_BLUETOOTHCTL="$work/bin/bluetoothctl" \
    SEGNO_BT_SCAN_SECONDS=1 \
        sh "$SCRIPT" "$@" 2>"$work/stderr"
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

# Position of the first call matching $1, or empty when it was never made.
call_index() {
    grep -n -- "$1" "$work/calls" 2>/dev/null | head -n1 | cut -d: -f1
}

echo "scan reports pairing, connection and device kind"
setup
out=$(run_ctl scan)
case "$out" in
    *'"paired":true'*) check "paired flag" yes yes ;;
    *) check "paired flag" yes no ;;
esac
case "$out" in
    *'"connected":true'*) check "connected flag" yes yes ;;
    *) check "connected flag" yes no ;;
esac
case "$out" in
    *'"kind":"headphones"'*) check "icon maps to a kind" yes yes ;;
    *) check "icon maps to a kind" yes no ;;
esac
teardown

echo "pair trusts before it connects"
setup
run_ctl pair AA:BB:CC:DD:EE:FF >/dev/null
pair_at=$(call_index "^pair ")
trust_at=$(call_index "^trust ")
connect_at=$(call_index "^connect ")
check "pair issued" yes "$([ -n "$pair_at" ] && echo yes || echo no)"
check "trust after pair" yes \
    "$([ -n "$trust_at" ] && [ "$trust_at" -gt "$pair_at" ] && echo yes || echo no)"
check "connect after trust" yes \
    "$([ -n "$connect_at" ] && [ "$connect_at" -gt "$trust_at" ] && echo yes || echo no)"
teardown

echo "forget disconnects before removing"
setup
run_ctl forget AA:BB:CC:DD:EE:FF >/dev/null
disconnect_at=$(call_index "^disconnect ")
remove_at=$(call_index "^remove ")
check "disconnect issued" yes "$([ -n "$disconnect_at" ] && echo yes || echo no)"
check "remove after disconnect" yes \
    "$([ -n "$remove_at" ] && [ "$remove_at" -gt "$disconnect_at" ] && echo yes || echo no)"
teardown

echo "disconnect keeps the pairing"
setup
run_ctl disconnect AA:BB:CC:DD:EE:FF >/dev/null
check "no remove" yes "$([ -z "$(call_index '^remove ')" ] && echo yes || echo no)"
check "no untrust" yes "$([ -z "$(call_index '^untrust ')" ] && echo yes || echo no)"
teardown

echo "a device verb without an address is a usage error"
setup
run_ctl pair >/dev/null 2>&1
check "exit code" 2 "$?"
teardown

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
