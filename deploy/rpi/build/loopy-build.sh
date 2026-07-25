#!/usr/bin/env bash
set -euo pipefail

flutter pub get

# CI-parity debug smoke FIRST: the exact command the CI arm64 job runs. Linux
# --release runs nowhere in CI, so this catches toolchain/dep drift against the
# proven compile guard before the (unproven-by-CI) release build.
echo "==> CI-parity debug smoke: flutter build linux --debug (main_development)"
flutter build linux --debug --target lib/main_development.dart

# The real deliverable: the release bundle. LOOPY_CONSOLE defaults on via the
# wrapper; extra args ("$@") are forwarded verbatim so callers can override.
echo "==> Release bundle: flutter build linux --release (main_production) $*"
flutter build linux --release --target lib/main_production.dart "$@"

# Hand the generated artifacts back to the invoking host user; without this the
# mounted output would be root-owned on the Mac. Non-fatal if a path is absent.
if [ -n "${HOST_UID:-}" ] && [ -n "${HOST_GID:-}" ]; then
  chown -R "$HOST_UID:$HOST_GID" \
    build .dart_tool linux/flutter/ephemeral \
    .flutter-plugins .flutter-plugins-dependencies pubspec.lock 2>/dev/null || true
fi
