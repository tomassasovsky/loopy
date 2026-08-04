#!/usr/bin/env bash
# Tests for `segno-bt-persist` (#451).
#
# The bind mount itself needs root and a real /data, so `mount` is stubbed and
# /proc/self/mountinfo is injected. What that leaves is exactly the part with
# teeth: WHICH copy of the pairings wins.
#
# Getting that backwards is silent and destructive in both directions — adopt
# too eagerly and a stale slot copy resurrects pairings the user deleted; adopt
# never and the first boot after this ships loses the pairings they have. So
# every adoption branch is asserted, plus the idempotence that stops a restart
# from stacking a second bind over the first and hiding the data underneath.
set -uo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SCRIPT="$here/../files/segno-bt-persist"

pass=0
fail=0

setup() {
    work=$(mktemp -d "${TMPDIR:-/tmp}/bt-persist-test.XXXXXX")
    mkdir -p "$work/data" "$work/state" "$work/bin"
    : > "$work/mountinfo"

    # Stub `mount`: records its arguments instead of touching the namespace.
    cat > "$work/bin/mount" <<STUB
#!/bin/sh
echo "\$@" > "$work/mount-args"
exit 0
STUB
    chmod +x "$work/bin/mount"
}

teardown() { rm -rf "$work"; }

run_persist() {
    SEGNO_BT_DATA_DIR="$work/data/bluetooth" \
    SEGNO_BT_STATE_DIR="$work/state/bluetooth" \
    SEGNO_MOUNT="$work/bin/mount" \
    SEGNO_MOUNTINFO="$work/mountinfo" \
        sh "$SCRIPT" 2>"$work/stderr"
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

bound() { [ -f "$work/mount-args" ] && echo yes || echo no; }

pair() { mkdir -p "$1/AA:BB:CC:DD:EE:FF/cache"; printf 'key\n' > "$1/AA:BB:CC:DD:EE:FF/info"; }

adopted() {
    [ -f "$work/data/bluetooth/AA:BB:CC:DD:EE:FF/info" ] && echo yes || echo no
}

# --- the adoption decision -------------------------------------------------

echo "first run with pairings already on the slot"
setup
mkdir -p "$work/state/bluetooth"
pair "$work/state/bluetooth"
run_persist; rc=$?
check "exits 0" 0 "$rc"
check "adopts the slot's pairings" yes "$(adopted)"
check "binds /data over the state dir" yes "$(bound)"
check "says so" yes "$(grep -q adopting "$work/stderr" && echo yes || echo no)"
teardown

echo "/data already holds pairings"
setup
mkdir -p "$work/state/bluetooth"
pair "$work/data/bluetooth"
# A stale copy left behind on the slot must NOT win: it is what /data looked
# like at the last update, so copying it back would undo everything since.
mkdir -p "$work/state/bluetooth/11:22:33:44:55:66"
printf 'stale\n' > "$work/state/bluetooth/11:22:33:44:55:66/info"
run_persist; rc=$?
check "exits 0" 0 "$rc"
check "keeps /data authoritative" no \
    "$([ -e "$work/data/bluetooth/11:22:33:44:55:66" ] && echo yes || echo no)"
check "binds anyway" yes "$(bound)"
teardown

echo "nothing paired anywhere"
setup
run_persist; rc=$?
check "exits 0" 0 "$rc"
check "creates the /data dir" yes \
    "$([ -d "$work/data/bluetooth" ] && echo yes || echo no)"
check "keeps it root-only" 700 \
    "$(stat -c '%a' "$work/data/bluetooth" 2>/dev/null ||
       stat -f '%Lp' "$work/data/bluetooth")"
check "binds" yes "$(bound)"
teardown

# --- idempotence -----------------------------------------------------------

echo "already bound"
setup
mkdir -p "$work/data/bluetooth"
printf '31 25 0:24 / %s rw,relatime shared:1 - ext4 /dev/x rw\n' \
    "$work/state/bluetooth" > "$work/mountinfo"
run_persist; rc=$?
check "exits 0" 0 "$rc"
check "does not stack a second bind" no "$(bound)"
teardown

echo "a different mount point is not ours"
setup
printf '31 25 0:24 / %s rw,relatime shared:1 - ext4 /dev/x rw\n' \
    "$work/state/bluetooth-other" > "$work/mountinfo"
run_persist; rc=$?
check "exits 0" 0 "$rc"
check "still binds" yes "$(bound)"
teardown

# --- failure is loud, not silent -------------------------------------------

echo "mount fails"
setup
cat > "$work/bin/mount" <<STUB
#!/bin/sh
exit 1
STUB
chmod +x "$work/bin/mount"
run_persist; rc=$?
check "reports the failure" 1 "$rc"
check "explains where the pairings went" yes \
    "$(grep -q 'stay on this slot' "$work/stderr" && echo yes || echo no)"
teardown

echo
echo "bt-persist: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
echo "ALL PASSED"
