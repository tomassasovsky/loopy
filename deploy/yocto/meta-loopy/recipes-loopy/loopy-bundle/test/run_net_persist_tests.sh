#!/usr/bin/env bash
# Tests for loopy-net-persist (#432).
#
# The bind mount itself needs root and a real /data, so what is proven here is
# the DECISION logic around it: that it degrades instead of failing the boot
# when /data is absent, that it locks the credential directory down, that it
# adopts profiles already on the image instead of orphaning them, and that it
# is idempotent. Those are the parts that silently lose someone's Wi-Fi
# password if they are wrong.
#
# `mount` and /proc/mounts are stubbed, so this runs unprivileged in CI.
set -uo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SCRIPT="$here/../files/loopy-net-persist"

pass=0
fail=0

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

setup() {
    work=$(mktemp -d "${TMPDIR:-/tmp}/net-persist-test.XXXXXX")
    mkdir -p "$work/bin" "$work/data" "$work/etc"

    # Stub `mount`: records the bind instead of performing it, and appends to
    # the fake /proc/mounts so a second run sees it as already bound.
    cat > "$work/bin/mount" <<STUB
#!/bin/sh
echo "\$@" >> "$work/mount-calls"
echo "none $work/etc none rw 0 0" >> "$work/proc-mounts"
exit 0
STUB
    chmod +x "$work/bin/mount"
    : > "$work/mount-calls"
    printf 'none %s/data none rw 0 0\n' "$work" > "$work/proc-mounts"
}

teardown() { rm -rf "$work"; }

# /proc/mounts is read via a literal path in the script, so the fixture is
# spliced in with a temporary copy of the script pointing at the fake.
run_persist() {
    sed "s#/proc/mounts#$work/proc-mounts#g; s# /data # $work/data #g" \
        "$SCRIPT" > "$work/bin/loopy-net-persist"
    chmod +x "$work/bin/loopy-net-persist"
    LOOPY_NET_STORE="$work/data/loopy/NetworkManager/system-connections" \
    LOOPY_NET_DST="$work/etc" \
    PATH="$work/bin:$PATH" \
        sh "$work/bin/loopy-net-persist" 2>"$work/stderr"
}

bound() { [ -s "$work/mount-calls" ] && echo yes || echo no; }

# GNU form first: on Linux `stat -f` reports FILESYSTEM status and succeeds, so
# probing BSD-style first silently returns the wrong thing instead of falling
# through. BSD `stat -c` is simply invalid, so it fails cleanly.
mode_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }

echo "/data mounted, nothing pre-existing"
setup
run_persist; rc=$?
check "exits 0" 0 "$rc"
check "creates the durable store" yes \
    "$([ -d "$work/data/loopy/NetworkManager/system-connections" ] && echo yes || echo no)"
check "locks the store to 0700 (these are credentials)" 700 \
    "$(mode_of "$work/data/loopy/NetworkManager/system-connections")"
check "performs the bind" yes "$(bound)"
teardown

echo "/data NOT mounted"
setup
: > "$work/proc-mounts"      # nothing mounted at all
run_persist; rc=$?
# Failing the boot over this would be worse than having no persistence.
check "exits 0 rather than failing the boot" 0 "$rc"
check "does not bind" no "$(bound)"
check "says so" yes "$(grep -q 'not mounted' "$work/stderr" && echo yes || echo no)"
teardown

echo "a profile already exists on the image"
setup
printf '[connection]\nid=studio\n' > "$work/etc/studio.nmconnection"
run_persist; rc=$?
check "exits 0" 0 "$rc"
# Binding over the directory would hide it forever; the network the user is
# currently on would vanish on the very reboot that enabled persistence.
check "adopts it into the durable store" yes \
    "$([ -f "$work/data/loopy/NetworkManager/system-connections/studio.nmconnection" ] && echo yes || echo no)"
check "preserves its contents" "id=studio" \
    "$(grep -h '^id=' "$work/data/loopy/NetworkManager/system-connections/studio.nmconnection")"
teardown

echo "already bound (second boot)"
setup
printf 'none %s/data none rw 0 0\nnone %s/etc none rw 0 0\n' "$work" "$work" > "$work/proc-mounts"
run_persist; rc=$?
check "exits 0" 0 "$rc"
check "does not bind twice" no "$(bound)"
teardown

echo "runs twice in a row (idempotent)"
setup
run_persist >/dev/null 2>&1
first=$(wc -l < "$work/mount-calls" | tr -d ' ')
run_persist; rc=$?
check "second run exits 0" 0 "$rc"
check "still only one bind" "$first" "$(wc -l < "$work/mount-calls" | tr -d ' ')"
teardown

echo
echo "net-persist: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
echo "ALL PASSED"
