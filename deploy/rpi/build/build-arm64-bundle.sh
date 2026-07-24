#!/usr/bin/env bash
#
# Build the Loopy aarch64 Linux release bundle from a Mac (or any Docker host).
#
# The dev machine cannot produce a Linux bundle natively, so the build runs in
# the arm64 container defined by deploy/rpi/build/Dockerfile.arm64. The image
# mirrors the CI arm64 recipe and, before the release build, re-runs the exact
# CI debug command as a parity smoke. This is a LOCAL-DEV producer, not a CI
# gate; CI's `build-linux-arm64` job remains the compile guard.
#
# Usage:
#   deploy/rpi/build/build-arm64-bundle.sh [--deploy user@host] [flutter args...]
#
#   (no args)                      Console kiosk release bundle (LOOPY_CONSOLE=true).
#   --deploy pi@raspberrypi.local  After building, rsync the bundle to the Pi.
#   --dart-define=LOOPY_CONSOLE=false
#                                  Non-console desktop bundle (e.g. for first-run
#                                  device setup). Any extra args are forwarded to
#                                  `flutter build` verbatim; if you do not name
#                                  LOOPY_CONSOLE yourself, console mode is added.
#
# Output: build/linux/arm64/release/bundle/ (loopy + libloopy_engine.so + lib/ + data/).
set -euo pipefail

readonly IMAGE="loopy-arm64-build"
readonly BUNDLE_REL="build/linux/arm64/release/bundle"

# Print the leading comment block (everything from line 2 to the first code line).
usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next}{exit}' "$0"; }

# --- Parse args: pull out --deploy, forward the rest to flutter build ---------
deploy_target=""
forward=()
while [ $# -gt 0 ]; do
  case "$1" in
    --deploy)   deploy_target="${2:?--deploy needs a user@host target}"; shift 2 ;;
    -h|--help)  usage; exit 0 ;;
    *)          forward+=("$1"); shift ;;
  esac
done
# Re-seat the forwarded args as "$@" (empty-array-safe under `set -u`).
set -- ${forward[@]+"${forward[@]}"}

# Default to console mode unless the caller set LOOPY_CONSOLE explicitly.
console_set=0
for a in "$@"; do
  case "$a" in --dart-define=LOOPY_CONSOLE=*) console_set=1 ;; esac
done
[ "$console_set" -eq 0 ] && set -- --dart-define=LOOPY_CONSOLE=true "$@"

# --- Locate the repo root so the script works from any CWD --------------------
command -v docker >/dev/null 2>&1 || { echo "error: docker not found on PATH" >&2; exit 1; }
repo_root="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
cd "$repo_root"

# --- Build the image, then run the build inside it ----------------------------
echo "==> Building $IMAGE (arm64)"
DOCKER_BUILDKIT=1 docker build --platform linux/arm64 \
  -f deploy/rpi/build/Dockerfile.arm64 -t "$IMAGE" deploy/rpi/build

echo "==> Building the aarch64 bundle: flutter build linux --release $*"
docker run --rm --platform linux/arm64 \
  -v "$repo_root":/workspace -w /workspace \
  -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
  "$IMAGE" "$@"

# --- Verify the bundle looks like an aarch64 ELF ------------------------------
bin="$BUNDLE_REL/loopy"
[ -x "$bin" ] || { echo "error: expected bundle binary missing: $bin" >&2; exit 1; }
echo "==> Built $bin"
file "$bin" | grep -q 'ARM aarch64' \
  && echo "==> Confirmed aarch64: $(file -b "$bin")" \
  || echo "warning: $bin is not reported as ARM aarch64 -- check the host platform" >&2

# --- Optional deploy to the Pi ------------------------------------------------
if [ -n "$deploy_target" ]; then
  command -v rsync >/dev/null 2>&1 || { echo "error: rsync not found on PATH" >&2; exit 1; }
  echo "==> Deploying to $deploy_target"
  # rsync only creates the final path component, so make the parent tree first —
  # a fresh Pi has no ~/loopy/build/linux/... yet.
  ssh "$deploy_target" "mkdir -p ~/loopy/$BUNDLE_REL"
  rsync -avz "$BUNDLE_REL/" "$deploy_target:~/loopy/$BUNDLE_REL/"
  echo "==> Deployed to $deploy_target:~/loopy/$BUNDLE_REL/"
fi
