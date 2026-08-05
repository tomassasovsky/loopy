#!/usr/bin/env bash
# Tests for how `segno-wifi-ctl connect` explains a failed join (#466).
#
# This is not cosmetic. The console has no keyboard-and-mouse escape hatch: what
# the Control Center says about a failure is the entire diagnosis a user gets.
# Saying "check the password" about a correct password sends them to re-enter it
# forever while the real fault — an access point that accepts the association
# and never starts the 4-way handshake — stays invisible.
#
# That happened for real (#459) and cost a night at the bench, because
# NetworkManager reports both cases as `Secrets were required`: on a headless
# appliance there is no secret agent, so any association timeout ends up asking
# for secrets, finding nobody, and failing as `no-secrets` — even right after
# logging "secrets exist, no new secrets needed".
#
# So the assertions here are about which of two indistinguishable NM errors we
# report, given what wpa_supplicant said underneath. nmcli and journalctl are
# both stubbed; no radio involved.
set -uo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CTL="$here/../files/segno-wifi-ctl"

pass=0
fail=0

setup() {
    work=$(mktemp -d "${TMPDIR:-/tmp}/wifi-join-test.XXXXXX")
    mkdir -p "$work/bin"

    # nmcli that gets as far as creating the profile and then fails activation
    # with NM's ambiguous wording — the exact string seen on device.
    cat > "$work/bin/nmcli" <<'STUB'
#!/bin/sh
case "$*" in
    *"radio wifi on"*|*"device set"*|*"connection delete"*|*"connection modify"*)
        exit 0 ;;
    *"connection add"*)
        exit 0 ;;
    *"connection up"*)
        echo "Error: Connection activation failed: Secrets were required, but not provided" >&2
        exit 4 ;;
    *"-t -f GENERAL.STATE device show"*)
        echo "GENERAL.STATE:30 (disconnected)"; exit 0 ;;
    *) exit 0 ;;
esac
STUB
    chmod +x "$work/bin/nmcli"
    : > "$work/journal"
    cat > "$work/bin/journalctl" <<STUB
#!/bin/sh
cat "$work/journal"
STUB
    chmod +x "$work/bin/journalctl"
}

teardown() { rm -rf "$work"; }

supplicant_logged() { cat > "$work/journal"; }

run_connect() {
    SEGNO_WIFI_IFACE=wlan0 \
    SEGNO_JOURNALCTL="$work/bin/journalctl" \
    SEGNO_WIFI_NM_CONNECT_TIMEOUT=1 \
    SEGNO_WIFI_CONNECT_TIMEOUT=1 \
    PATH="$work/bin:$PATH" \
        sh "$CTL" connect "SomeNetwork" "hunter2000" 2>"$work/stderr" >/dev/null
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

said() { grep -qi "$1" "$work/stderr" && echo yes || echo no; }

# --- the distinction that matters ------------------------------------------

echo "AP accepted the association and never sent EAPOL"
setup
supplicant_logged <<'LOG'
Aug 03 03:39:26 pi wpa_supplicant[1020]: wlan0: Trying to associate with 58:11:22:34:39:1c (SSID='SomeNetwork' freq=5200 MHz)
Aug 03 03:39:26 pi wpa_supplicant[1020]: wlan0: Associated with 58:11:22:34:39:1c
Aug 03 03:39:36 pi wpa_supplicant[1020]: wlan0: Authentication with 58:11:22:34:39:1c timed out.
LOG
run_connect
# NM said "Secrets were required". It is wrong, and saying so would send the
# user to re-enter a password that was never even tested.
check "does not blame the password" no "$(said 'wrong password')"
check "reports the join as not completing" yes "$(said 'timed out waiting for association')"
teardown

echo "the key really is wrong"
setup
supplicant_logged <<'LOG'
Aug 03 03:39:26 pi wpa_supplicant[1020]: wlan0: Associated with 58:11:22:34:39:1c
Aug 03 03:39:27 pi wpa_supplicant[1020]: wlan0: WPA: 4-Way Handshake failed - pre-shared key may be incorrect
Aug 03 03:39:27 pi wpa_supplicant[1020]: wlan0: CTRL-EVENT-SSID-TEMP-DISABLED reason=WRONG_KEY
LOG
run_connect
# The AP sent M1 and the MIC did not check out. That IS the password.
check "blames the password" yes "$(said 'wrong password')"
check "does not call it a timeout" no "$(said 'timed out waiting')"
teardown

echo "no supplicant evidence at all"
setup
run_connect
# Deliberately NOT NM's reading. On a headless appliance there is no secret
# agent, so `no-secrets` is what EVERY activation failure decays into — it is
# a statement about the missing agent, not about the key. Absent evidence that
# a supplicant actually tested the key, the honest answer is that the join did
# not finish. #459 is what the other choice costs.
check "does not blame the password" no "$(said 'wrong password')"
check "reports the join as not completing" yes "$(said 'timed out waiting')"
teardown

echo "iwd reports a real key failure"
setup
# The evidence grep matched only wpa_supplicant until #470 swapped the
# supplicant out from under it — which silently reclassified every genuine
# wrong password as a timeout. Whatever drives the radio must be readable here.
supplicant_logged <<'LOG'
Aug 03 05:00:00 pi iwd[452]: wlan0: 4-Way Handshake failed - pre-shared key may be incorrect
LOG
run_connect
check "blames the password" yes "$(said 'wrong password')"
teardown

echo "NetworkManager alone says no-secrets"
setup
supplicant_logged <<'LOG'
Aug 03 05:00:00 pi NetworkManager[614]: <warn> device (wlan0): no secrets: No agents were available for this request.
Aug 03 05:00:00 pi NetworkManager[614]: <warn> device (wlan0): Activation: (wifi) association took too long
LOG
run_connect
check "reads the association timeout, not the agent" yes "$(said 'timed out waiting')"
check "does not blame the password" no "$(said 'wrong password')"
teardown

echo "evidence names a handshake failure AND a later timeout"
setup
supplicant_logged <<'LOG'
Aug 03 03:39:27 pi wpa_supplicant[1020]: wlan0: WPA: 4-Way Handshake failed - pre-shared key may be incorrect
Aug 03 03:39:47 pi wpa_supplicant[1020]: wlan0: Authentication with 58:11:22:34:39:1c timed out.
LOG
run_connect
# A wrong key produces a timeout too, once the supplicant gives up retrying.
# The key failure is the more specific fact, so it wins.
check "prefers the specific failure" yes "$(said 'wrong password')"
teardown

echo
echo "wifi-join-errors: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
echo "ALL PASSED"
