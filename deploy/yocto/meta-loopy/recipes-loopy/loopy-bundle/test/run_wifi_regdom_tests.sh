#!/usr/bin/env bash
# Tests for `loopy-wifi-regdom` (#459).
#
# Whether the kernel actually honours a country code needs a radio, so `iw` is
# stubbed and every path is injected. What that leaves is the part that decides
# whether a 5 GHz network works at all: which country is chosen, and whether a
# bad answer is loud or silent.
#
# The bug this exists to prevent was silent in the worst way. `[device]
# wifi.country=AR` sat in NetworkManager's config looking correct for months
# and did nothing, because that is not a NetworkManager property. Nothing
# logged, nothing failed — 5 GHz just associated and then timed out, and
# NetworkManager blamed the password. So the rule here is that this script
# never fails quietly: it either sets a domain and says so, or says why not.
set -uo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SCRIPT="$here/../files/loopy-wifi-regdom"

pass=0
fail=0

setup() {
    work=$(mktemp -d "${TMPDIR:-/tmp}/wifi-regdom-test.XXXXXX")
    mkdir -p "$work/data" "$work/etc" "$work/bin"
    : > "$work/regulatory.db"

    cat > "$work/bin/iw" <<STUB
#!/bin/sh
echo "\$@" > "$work/iw-args"
exit 0
STUB
    chmod +x "$work/bin/iw"
}

teardown() { rm -rf "$work"; }

run_regdom() {
    LOOPY_WIFI_COUNTRY_FILE="$work/data/wifi-country" \
    LOOPY_WIFI_COUNTRY_DEFAULT_FILE="$work/etc/wifi-country" \
    LOOPY_IW="$work/bin/iw" \
    LOOPY_REGDB="$work/regulatory.db" \
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

set_to() { [ -f "$work/iw-args" ] && cat "$work/iw-args" || echo "(not called)"; }
said() { grep -qi "$1" "$work/stderr" && echo yes || echo no; }

# --- which country wins ----------------------------------------------------

echo "image default only"
setup
printf 'AR\n' > "$work/etc/wifi-country"
run_regdom; rc=$?
check "exits 0" 0 "$rc"
check "sets the baked default" "reg set AR" "$(set_to)"
teardown

echo "/data override"
setup
printf 'AR\n' > "$work/etc/wifi-country"
printf 'GB\n' > "$work/data/wifi-country"
run_regdom
# Travelling with the console must not mean reflashing it, so the writable
# copy outranks the one baked into the slot.
check "the override wins" "reg set GB" "$(set_to)"
teardown

echo "lowercase and whitespace"
setup
printf '  gb \n' > "$work/data/wifi-country"
run_regdom
check "normalized" "reg set GB" "$(set_to)"
teardown

# --- refusing rather than guessing -----------------------------------------

echo "nothing configured"
setup
run_regdom; rc=$?
check "exits 0" 0 "$rc"
check "does not call iw" "(not called)" "$(set_to)"
check "says the domain was left alone" yes "$(said 'leaving the regulatory')"
teardown

echo "junk in the country file"
setup
printf 'Argentina\n' > "$work/data/wifi-country"
run_regdom; rc=$?
check "exits 0 rather than blocking the network" 0 "$rc"
check "does not hand junk to iw" "(not called)" "$(set_to)"
check "names the bad value" yes "$(said "invalid country 'ARGENTINA'")"
teardown

echo "empty override falls through to the default"
setup
printf 'AR\n' > "$work/etc/wifi-country"
: > "$work/data/wifi-country"
run_regdom
check "uses the default" "reg set AR" "$(set_to)"
teardown

# --- failure is visible ----------------------------------------------------

echo "regulatory.db missing"
setup
printf 'AR\n' > "$work/etc/wifi-country"
rm -f "$work/regulatory.db"
run_regdom; rc=$?
# Kernels that require a signed regdb reject the hint without it, and the
# result looks exactly like this script never running.
check "still tries" "reg set AR" "$(set_to)"
check "warns that the kernel may refuse it" yes "$(said 'may refuse')"
check "exits 0" 0 "$rc"
teardown

echo "iw fails"
setup
printf 'AR\n' > "$work/etc/wifi-country"
cat > "$work/bin/iw" <<STUB
#!/bin/sh
exit 1
STUB
chmod +x "$work/bin/iw"
run_regdom; rc=$?
check "reports the failure" 1 "$rc"
check "names the country" yes "$(said 'failed to set the regulatory domain to AR')"
teardown

echo
echo "wifi-regdom: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
echo "ALL PASSED"
