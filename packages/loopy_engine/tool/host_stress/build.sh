#!/bin/zsh
# Builds a host stress/soak harness against the REAL VST3 host TUs (not copies),
# so it exercises exactly the code the app ships. macOS only (the host backend is
# macOS-only until the Windows/Linux ports).
#
# Usage: ./build.sh <stress|soak|editor_probe> [asan]
#   asan -> compile with AddressSanitizer for memory-safety checking.
#
# Output: ./<target>[ _asan] next to this script.
set -e
HERE="${0:A:h}"
ENG="${HERE:h:h}"            # packages/loopy_engine
SDK="$ENG/third_party/vst3sdk"
HOST="$ENG/src/host"

TARGET="${1:-stress}"
SRC="$HERE/$TARGET.mm"
[[ -f "$SRC" ]] || { echo "no such target: $TARGET (expected $SRC)"; exit 1; }

SAN=(-O2)
OUT="$HERE/$TARGET"
if [[ "$2" == "asan" ]]; then
  SAN=(-O1 -g -fsanitize=address -fno-omit-frame-pointer)
  OUT="$HERE/${TARGET}_asan"
fi

clang++ -std=c++17 -DLOOPY_ENABLE_PLUGINS "${SAN[@]}" \
  -I"$SDK" -I"$HOST" \
  "$SRC" \
  "$HOST/host_vst3.cpp" \
  "$HOST/scan_vst3.cpp" \
  "$HOST/native_window_controller.mm" \
  "$SDK/public.sdk/source/vst/vstinitiids.cpp" \
  "$SDK/pluginterfaces/base/coreiids.cpp" \
  "$SDK/public.sdk/source/common/commoniids.cpp" \
  -framework Cocoa -framework CoreFoundation \
  -o "$OUT"
echo "built $OUT"
