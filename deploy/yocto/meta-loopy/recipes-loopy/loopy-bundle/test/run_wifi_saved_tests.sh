#!/usr/bin/env bash
# Tests for saved-network visibility and autoconnect priority (#471, #463).
#
# Both bugs are about a saved profile the user cannot see or outrank. Together
# they trapped a console during #459: a saved network that would not connect
# kept winning autoconnect (every profile got the same priority, so
# NetworkManager broke the tie by timestamp), and it could not be forgotten
# from the UI because the list only showed what the last scan returned — and a
# network that will not connect is rarely the one you are connected to.
set -uo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CTL="$here/../files/loopy-wifi-ctl"

pass=0
fail=0

setup() {
    work=$(mktemp -d "${TMPDIR:-/tmp}/wifi-saved-test.XXXXXX")
    mkdir -p "$work/bin"
    : > "$work/nmcli-args"
    cat > "$work/bin/nmcli" <<STUB
#!/bin/sh
echo "\$@" >> "$work/nmcli-args"
case "\$*" in
    *"GENERAL.STATE device show"*) printf 'GENERAL.STATE:100 (connected)\n' ;;
    *"connection.autoconnect-priority connection show"*)
        name=\$(printf '%s' "\$*" | awk '{print \$NF}')
        for pair in \${PRIORITIES:-}; do
            case "\$pair" in "\$name="*) printf '%s\n' "\${pair#*=}"; exit 0 ;; esac
        done
        printf '0\n'
        ;;
    *"connection show"*)
        for n in \${SAVED:-}; do printf '%s:802-11-wireless\n' "\$n"; done
        ;;
    *"device wifi list"*) printf 'Studio:70:WPA2\n' ;;
    *"connection up"*)
        echo "Error: Connection activation failed" >&2; exit 4 ;;
    *) : ;;
esac
exit 0
STUB
    chmod +x "$work/bin/nmcli"
    cat > "$work/bin/journalctl" <<'STUB'
#!/bin/sh
exit 0
STUB
    chmod +x "$work/bin/journalctl"
}

teardown() { rm -rf "$work"; }

run() { PATH="$work/bin:$PATH" LOOPY_JOURNALCTL="$work/bin/journalctl" \
    SAVED="${SAVED:-}" PRIORITIES="${PRIORITIES:-}" \
    sh "$CTL" "$@" >"$work/stdout" 2>"$work/stderr"; }

check() {
    local label=$1 expected=$2 actual=$3
    if [ "$expected" = "$actual" ]; then
        echo "  ok   $label"; pass=$((pass + 1))
    else
        echo "  FAIL $label (expected '$expected', got '$actual')"
        [ -s "$work/stdout" ] && sed 's/^/       > /' "$work/stdout"
        fail=$((fail + 1))
    fi
}

echo "a saved network that is out of range is still listed"
setup
SAVED="Cafe" run scan
check "listed" yes "$(grep -q '"ssid":"Cafe"' "$work/stdout" && echo yes || echo no)"
check "flagged saved, signal -1" yes \
    "$(grep -q '"ssid":"Cafe","signal":-1,"secured":true,"saved":true' "$work/stdout" && echo yes || echo no)"
teardown

echo "an in-range network that is saved is marked, not duplicated"
setup
SAVED="Studio" run scan
check "exactly one entry" 1 \
    "$(grep -o '"ssid":"Studio"' "$work/stdout" | wc -l | tr -d ' ')"
check "marked saved" yes \
    "$(grep -q '"ssid":"Studio","signal":70,"secured":true,"saved":true' "$work/stdout" && echo yes || echo no)"
teardown

echo "an unsaved network is marked unsaved"
setup
SAVED="" run scan
check "saved:false" yes \
    "$(grep -q '"ssid":"Studio","signal":70,"secured":true,"saved":false' "$work/stdout" && echo yes || echo no)"
teardown

echo "the network the user just picked outranks the saved ones"
setup
SAVED="Cafe Studio" PRIORITIES="Cafe=100 Studio=101" run connect Cafe pw
check "one above the highest saved" yes \
    "$(grep -q 'autoconnect-priority 102' "$work/nmcli-args" && echo yes || echo no)"
teardown

echo "the first network ever saved uses the floor"
setup
SAVED="" PRIORITIES="" run connect Cafe pw
check "uses the floor, still beating the wired -999" yes \
    "$(grep -q 'autoconnect-priority 100' "$work/nmcli-args" && echo yes || echo no)"
teardown

echo
echo "wifi-saved: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
echo "ALL PASSED"
