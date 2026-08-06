#!/usr/bin/env bash
# Tests for `segno-bt-ctl`'s device verbs (#498).
#
# What bluez DOES with these commands needs a radio; what the helper SENDS,
# and in what ORDER, does not — and the ordering is the part with teeth:
#
#   * pair must discover first. bluez cannot pair with a device it has not
#     seen this session, and the "unknown device" failure that follows reads
#     to an operator as the device refusing rather than as the console never
#     having looked.
#   * pair must trust before it connects, or the device has to be re-authorised
#     by hand after every reboot, which is not what "paired" means.
#   * forget must disconnect and untrust before remove, or bluez re-adds the
#     device from the still-live link.
#
# So `bluetoothctl` is stubbed into a transcript and the transcript asserted.
set -uo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SCRIPT="$here/../files/segno-bt-ctl"

pass=0
fail=0

setup() {
    work=$(mktemp -d "${TMPDIR:-/tmp}/bt-ctl-test.XXXXXX")
    mkdir -p "$work/bin"
    : > "$work/calls"
    : > "$work/info"
    : > "$work/devices"
    : > "$work/paired"

    cat > "$work/bin/bluetoothctl" <<STUB
#!/bin/sh
# Record the call, minus the --timeout prefix so the transcript reads as verbs.
args="\$*"
case "\$1" in
  --timeout) shift 2; args="scan-timed \$*" ;;
esac
echo "\$args" >> "$work/calls"
case "\$1" in
  devices)
    if [ "\${2:-}" = Paired ]; then cat "$work/paired"; else cat "$work/devices"; fi
    ;;
  info) cat "$work/info" ;;
esac
exit \${SEGNO_STUB_RC:-0}
STUB
    chmod +x "$work/bin/bluetoothctl"
}

teardown() { rm -rf "$work"; }

run_ctl() {
    PATH="$work/bin:$PATH" SEGNO_BT_SCAN_SECONDS=1 \
        sh "$SCRIPT" "$@" 2>"$work/stderr"
}

check() {
    local label=$1 expected=$2 actual=$3
    if [ "$expected" = "$actual" ]; then
        echo "  ok   $label"
        pass=$((pass + 1))
    else
        echo "  FAIL $label (expected '$expected', got '$actual')"
        fail=$((fail + 1))
    fi
}

# Position of the first call matching $1 in the transcript, or 0 when absent.
at() { grep -n -- "$1" "$work/calls" | head -n1 | cut -d: -f1; }

ordered() {
    local a b
    a=$(at "$1"); b=$(at "$2")
    if [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; then echo yes; else echo no; fi
}

ADDR=AA:BB:CC:DD:EE:FF

# --- pair ------------------------------------------------------------------

echo "pair"
setup
run_ctl pair "$ADDR" >"$work/out"; rc=$?
check "exits 0" 0 "$rc"
check "emits an empty object" '{}' "$(cat "$work/out")"
check "scans before pairing" yes "$(ordered '^scan-timed' "^pair $ADDR")"
check "trusts after pairing" yes "$(ordered "^pair $ADDR" "^trust $ADDR")"
check "connects after trusting" yes "$(ordered "^trust $ADDR" "^connect $ADDR")"
teardown

echo "pair reports a refusal"
setup
# `pair` itself is the only unguarded call in the verb, so a non-zero
# bluetoothctl has to surface — a device that never had its button pressed
# must not read as paired.
SEGNO_STUB_RC=1 run_ctl pair "$ADDR" >"$work/out"; rc=$?
check "exits non-zero" yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
teardown

# --- connect / disconnect --------------------------------------------------

echo "connect"
setup
run_ctl connect "$ADDR" >"$work/out"; rc=$?
check "exits 0" 0 "$rc"
check "connects" yes "$([ -n "$(at "^connect $ADDR")" ] && echo yes || echo no)"
check "does not scan" no "$([ -n "$(at '^scan-timed')" ] && echo yes || echo no)"
teardown

echo "disconnect"
setup
run_ctl disconnect "$ADDR" >"$work/out"; rc=$?
check "exits 0" 0 "$rc"
check "keeps the pairing" no \
    "$([ -n "$(at "^remove $ADDR")" ] && echo yes || echo no)"
teardown

# --- forget ----------------------------------------------------------------

echo "forget"
setup
run_ctl forget "$ADDR" >"$work/out"; rc=$?
check "exits 0" 0 "$rc"
check "disconnects before removing" yes \
    "$(ordered "^disconnect $ADDR" "^remove $ADDR")"
check "untrusts before removing" yes \
    "$(ordered "^untrust $ADDR" "^remove $ADDR")"
teardown

# --- scan detail -----------------------------------------------------------

echo "scan reports per-device detail"
setup
printf 'Device %s Studio Cans\n' "$ADDR" > "$work/devices"
printf '\tPaired: yes\n\tConnected: yes\n\tIcon: audio-headphones\n' > "$work/info"
run_ctl scan >"$work/out"; rc=$?
check "exits 0" 0 "$rc"
check "carries paired" yes \
    "$(grep -q '"paired":true' "$work/out" && echo yes || echo no)"
check "carries connected" yes \
    "$(grep -q '"connected":true' "$work/out" && echo yes || echo no)"
check "carries the bluez icon" yes \
    "$(grep -q '"icon":"audio-headphones"' "$work/out" && echo yes || echo no)"
check "marks a seen device in range" yes \
    "$(grep -q '"inRange":true' "$work/out" && echo yes || echo no)"
teardown

echo "scan lists a paired device it did not see"
setup
: > "$work/devices"
printf 'Device %s Page turner\n' "$ADDR" > "$work/paired"
printf '\tName: Page turner\n\tPaired: yes\n\tIcon: input-keyboard\n' > "$work/info"
run_ctl scan >"$work/out"; rc=$?
check "exits 0" 0 "$rc"
check "lists it anyway" yes \
    "$(grep -q 'Page turner' "$work/out" && echo yes || echo no)"
check "marks it out of range" yes \
    "$(grep -q '"inRange":false' "$work/out" && echo yes || echo no)"
teardown

# --- argument handling -----------------------------------------------------

echo "a device verb needs an address"
setup
run_ctl pair >"$work/out"; rc=$?
check "refuses" 2 "$rc"
teardown

echo
echo "bt-ctl: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
echo "ALL PASSED"
