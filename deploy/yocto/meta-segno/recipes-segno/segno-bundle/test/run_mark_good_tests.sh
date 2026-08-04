#!/usr/bin/env bash
# Tests for `segno-mark-good` (#307).
#
# This script decides whether an OS update is kept or thrown away. Both
# mistakes are silent and expensive: refuse to mark a healthy slot and the user
# loses an update they watched install (observed live — updated, set up Wi-Fi,
# rebooted, came back on the old version); mark a broken one and A/B rollback,
# the entire reason the appliance has two slots, stops protecting anything.
#
# `systemctl` and `rauc` are stubbed and the health window is compressed to
# keep the suite fast, so what is actually asserted is the decision, which is
# the part with consequences.
set -uo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SCRIPT="$here/../files/segno-mark-good"

pass=0
fail=0

# Stub systemctl. $work/active holds the is-active answer for each successive
# call (one line per call, reused once exhausted); $work/restarts does the same
# for NRestarts, which is how a crash loop is spotted.
setup() {
    work=$(mktemp -d "${TMPDIR:-/tmp}/mark-good-test.XXXXXX")
    mkdir -p "$work/bin"
    printf 'yes\n' > "$work/active"
    printf '0\n' > "$work/restarts"

    cat > "$work/bin/systemctl" <<STUB
#!/bin/sh
next() {
    file=\$1
    line=\$(head -n1 "\$file")
    remaining=\$(tail -n +2 "\$file")
    [ -n "\$remaining" ] && printf '%s\n' "\$remaining" > "\$file"
    printf '%s' "\$line"
}
case "\$1" in
    is-active) [ "\$(next "$work/active")" = yes ] ;;
    show)      next "$work/restarts"; echo ;;
esac
STUB
    chmod +x "$work/bin/systemctl"

    cat > "$work/bin/rauc" <<STUB
#!/bin/sh
echo "\$@" > "$work/rauc-args"
exit \${RAUC_EXIT:-0}
STUB
    chmod +x "$work/bin/rauc"
}

teardown() { rm -rf "$work"; }

run_mark_good() {
    SEGNO_SYSTEMCTL="$work/bin/systemctl" \
    SEGNO_RAUC="$work/bin/rauc" \
    SEGNO_MARK_GOOD_WAIT_SECS="${WAIT_OVERRIDE:-4}" \
    SEGNO_MARK_GOOD_STABLE_SECS="${STABLE_OVERRIDE:-1}" \
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

marked() { [ -f "$work/rauc-args" ] && echo yes || echo no; }

echo "app up and stable"
setup
run_mark_good; rc=$?
check "exits 0" 0 "$rc"
check "commits the booted slot" yes "$(marked)"
check "uses mark-good booted" "status mark-good booted" \
    "$(cat "$work/rauc-args" 2>/dev/null)"
teardown

echo "app takes a moment to come up"
setup
# Not up for the first two polls, then up: a slow first boot is normal, not a
# reason to throw the update away.
printf 'no\nno\nyes\n' > "$work/active"
run_mark_good; rc=$?
check "waits rather than refusing" 0 "$rc"
check "commits" yes "$(marked)"
teardown

echo "app never comes up"
setup
printf 'no\n' > "$work/active"
run_mark_good; rc=$?
check "refuses" 1 "$rc"
check "does NOT commit — the next reboot must roll back" no "$(marked)"
check "says why" yes \
    "$(grep -q 'never came up' "$work/stderr" && echo yes || echo no)"
teardown

echo "app dies during the health window"
setup
printf 'yes\nno\n' > "$work/active"
run_mark_good; rc=$?
check "refuses" 1 "$rc"
check "does NOT commit" no "$(marked)"
teardown

echo "app crash-loops through the health window"
setup
# The trap this gate exists for: Restart=always means a crash-looping app reads
# as active every time you look. Only the restart count gives it away.
printf 'yes\nyes\n' > "$work/active"
printf '0\n3\n' > "$work/restarts"
run_mark_good; rc=$?
check "refuses" 1 "$rc"
check "does NOT commit a crash loop" no "$(marked)"
check "names the restarts" yes \
    "$(grep -q 'restarted during' "$work/stderr" && echo yes || echo no)"
teardown

echo "rauc itself refuses"
setup
cat > "$work/bin/rauc" <<STUB
#!/bin/sh
echo "\$@" > "$work/rauc-args"
exit 1
STUB
chmod +x "$work/bin/rauc"
run_mark_good; rc=$?
check "surfaces the failure" 1 "$rc"
check "says so" yes \
    "$(grep -q 'refused to mark' "$work/stderr" && echo yes || echo no)"
teardown

echo
echo "mark-good: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
echo "ALL PASSED"
