#!/usr/bin/env bash
#
# Install the Loopy floor-console kiosk for the CURRENT user.
#
# The systemd unit ships with `pi` / `/home/pi` as its documented default, but
# modern Raspberry Pi OS has no `pi` user — you pick your own at flash time. This
# installer substitutes the real user, home, and UID so the kiosk works for
# whoever runs it, rather than requiring a hand-edit. Run it from the repo
# checkout on the Pi (the app bundle is expected under <repo>/build/...):
#
#   ~/loopy/deploy/rpi/install-kiosk.sh
#
# It needs sudo (systemd unit + default target); you'll be prompted.
set -euo pipefail

user="$(id -un)"
uid="$(id -u)"
home="$HOME"
repo="$(cd "$(dirname "$0")/../.." && pwd)"   # repo root = deploy/rpi/../..

echo "==> Installing loopy-kiosk for user '$user' (uid $uid), repo at $repo"

# 1. systemd unit — substitute the shipped pi/`/home/pi`/uid defaults for this
#    user's real values, so User=, the ExecStart* paths, and XDG_RUNTIME_DIR match.
sed -e "s#^User=pi#User=$user#" \
    -e "s#/home/pi/loopy#$repo#g" \
    -e "s#/run/user/1000#/run/user/$uid#g" \
    "$repo/deploy/rpi/loopy-kiosk.service" \
  | sudo tee /etc/systemd/system/loopy-kiosk.service >/dev/null

# 2. labwc compositor config + executable bits on the helper scripts.
mkdir -p "$home/.config/labwc"
cp "$repo"/deploy/rpi/compositor/labwc/* "$home/.config/labwc/"
chmod +x "$repo"/deploy/rpi/*.sh

# 3. Boot to console (multi-user), not the desktop, so the kiosk owns the display
#    (a desktop session on graphical.target would fight it for the DRM master).
sudo systemctl set-default multi-user.target

# 4. Enable (starts on next boot).
sudo systemctl daemon-reload
sudo systemctl enable loopy-kiosk.service

cat <<EOF
==> Installed. Reboot to start the kiosk:
      sudo reboot
    Undo:
      sudo systemctl disable --now loopy-kiosk.service
      sudo systemctl set-default graphical.target && sudo reboot
EOF
