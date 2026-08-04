#!/usr/bin/env bash
# Tests that segno-wifi-ctl owns the radio through NetworkManager and nothing
# else (#468).
#
# The bug these exist to prevent was not a crash, it was a takeover. The helper
# used to fall back to its own wpa_supplicant when an NM join failed, which
# meant setting wlan0 `managed no` — and because the backend was then chosen by
# reading that same state, every later call picked the fallback again. A
# console ended up running our supplicant and NetworkManager's dbus-owned one
# at the same time, on one interface, forever. The access point saw it
# reconnect every few seconds and nothing in any log said why.
#
# So these assert absence as much as behaviour: no second supplicant, no
# `managed no`, and — because a shipped console is already in the broken state
# — that the first run after an update repairs it.
set -uo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CTL="$here/../files/segno-wifi-ctl"

pass=0
fail=0

setup() {
    work=$(mktemp -d "${TMPDIR:-/tmp}/wifi-backend-test.XXXXXX")
    mkdir -p "$work/bin"
    : > "$work/nmcli-args"

    # nmcli stub: records every invocation and answers the two reads the
    # helper makes. NM_STATE drives what `device show` reports.
    cat > "$work/bin/nmcli" <<STUB
#!/bin/sh
echo "\$@" >> "$work/nmcli-args"
case "\$*" in
    *"GENERAL.STATE device show"*)
        printf 'GENERAL.STATE:%s\n' "\${NM_STATE:-100 (connected)}"
        ;;
    *"-f WIFI radio"*) printf 'enabled\n' ;;
    *"GENERAL.CONNECTION device show"*) printf 'GENERAL.CONNECTION:Studio\n' ;;
    *"IP4.ADDRESS device show"*) printf 'IP4.ADDRESS[1]:10.0.0.5/24\n' ;;
    *) : ;;
esac
exit 0
STUB
    chmod +x "$work/bin/nmcli"
}

teardown() { rm -rf "$work"; }

run_ctl() {
    PATH="$work/bin:$PATH" \
    SEGNO_WIFI_IFACE=wlan0 \
    NM_STATE="${NM_STATE:-100 (connected)}" \
        sh "$CTL" "$@" >"$work/stdout" 2>"$work/stderr"
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

called_with() { grep -qF "$1" "$work/nmcli-args" && echo yes || echo no; }

# --- the radio is never handed away ----------------------------------------

echo "no verb ever unmanages the interface"
setup
for verb in status scan disconnect; do run_ctl "$verb"; done
run_ctl forget Studio
run_ctl radio on
check "never sets managed no" no "$(called_with 'device set wlan0 managed no')"
teardown

echo "read-only verbs never drop the link"
setup
# Disconnecting is correct for `disconnect` and wrong for everything else: a
# status poll that bounced the radio is how a UI ends up fighting its own user.
run_ctl status
run_ctl scan
run_ctl radio on
check "status/scan/radio leave the connection up" no \
    "$(called_with 'device disconnect wlan0')"
run_ctl disconnect
check "disconnect still disconnects" yes \
    "$(called_with 'device disconnect wlan0')"
teardown

echo "the helper spawns no supplicant of its own"
setup
# A wpa_supplicant on PATH would be used if any code path still wanted one.
cat > "$work/bin/wpa_supplicant" <<STUB
#!/bin/sh
echo "spawned" > "$work/supplicant-spawned"
exit 0
STUB
cat > "$work/bin/wpa_cli" <<'STUB'
#!/bin/sh
echo "OK"
exit 0
STUB
chmod +x "$work/bin/wpa_supplicant" "$work/bin/wpa_cli"
for verb in status scan disconnect; do run_ctl "$verb"; done
check "never starts wpa_supplicant" no \
    "$([ -f "$work/supplicant-spawned" ] && echo yes || echo no)"
teardown

# --- repairing a console that already shipped with the bug ------------------

echo "an interface left unmanaged is reclaimed"
setup
NM_STATE="10 (unmanaged)" run_ctl status
check "hands wlan0 back to NetworkManager" yes \
    "$(called_with 'device set wlan0 managed yes')"
check "says so" yes \
    "$(grep -q 'reclaiming' "$work/stderr" && echo yes || echo no)"
teardown

echo "a managed interface is left alone"
setup
run_ctl status
check "does not churn the managed state" no \
    "$(called_with 'device set wlan0 managed yes')"
teardown

# --- no nmcli is honest, not a fallback ------------------------------------

echo "NetworkManager absent"
setup
rm -f "$work/bin/nmcli"
PATH="$work/bin:/usr/bin:/bin" sh "$CTL" status >"$work/stdout" 2>"$work/stderr"
check "status reports unsupported rather than improvising" yes \
    "$(grep -q '"supported":false' "$work/stdout" && echo yes || echo no)"
PATH="$work/bin:/usr/bin:/bin" sh "$CTL" connect Studio pw \
    >"$work/stdout" 2>"$work/stderr"; rc=$?
check "connect fails loudly" 1 "$rc"
check "names the missing piece" yes \
    "$(grep -q 'nmcli' "$work/stderr" && echo yes || echo no)"
teardown

echo
echo "wifi-backend: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
echo "ALL PASSED"
