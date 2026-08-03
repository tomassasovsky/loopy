# Drive the radio with iwd instead of wpa_supplicant (#468 step 2).
#
# wpa_supplicant handles one client at a time, has no supported control API and
# makes no releases; iwd was written to replace it and is multi-client by
# design. On this appliance a join reliably associates and then never receives
# EAPOL-Key M1 — with a single supplicant, a correct PSK, a permissive
# regulatory domain and an access point offering plain WPA2-PSK. Swapping the
# supplicant is the next variable to change.
#
# The recipe does the rest itself: PACKAGECONFIG[iwd] installs its own
# `wifi.backend=iwd` drop-in, and get_wifi_deps() swaps networkmanager-wifi's
# runtime dependency from wpa-supplicant to iwd.
PACKAGECONFIG:append = " iwd"
