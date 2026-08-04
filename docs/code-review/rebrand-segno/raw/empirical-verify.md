# Empirical verify — Segno rebrand

Date: 2026-08-04

## Summary

| Check | Result | Exit |
|-------|--------|------|
| `dart analyze` | PASS | 0 |
| `flutter test` | PASS | 0 |
| `run_native_tests.sh` | PASS | 0 |
| `firmware/test/run_tests.sh` | PASS | 0 |
| `git grep -i loopy` (leftovers) | PASS (no matches) | 1 (empty = clean) |
| Key files exist | PASS | — |

**Critical**: 0 | **Important**: 0 | **Suggestion**: 0

---

## 1. `dart analyze`

**Exit status**: `0`

**Last relevant lines**:
```
Analyzing loopy...
No issues found!
EXIT:0
```

---

## 2. `/Users/Tomas/development/flutter/bin/flutter test`

**Exit status**: `0`

**Last relevant lines**:
```
01:02 +1405 ~37: All tests passed!
EXIT:0
```

---

## 3. `bash packages/segno_engine/src/test/run_native_tests.sh`

**Exit status**: `0`

**Last relevant lines**:
```
== building plugin slot tests ==
...
ALL PASSED
EXIT:0
```

(Prior suites also ended `ALL PASSED`: segno_engine_core, midi, plugin scan, plugin slot.)

---

## 4. `bash firmware/test/run_tests.sh`

**Exit status**: `0`

**Last relevant lines**:
```
== contract test against firmware/segno_pedal ==
...
ALL PASSED
== contract test against hardware/firmware/segno_pedal_32u4 ==
...
ALL PASSED
run_tests.sh: both protocol copies pass
EXIT:0
```

---

## 5. `git grep -i loopy` (exclusions as specified)

**Command**:
```
git grep -i loopy -- ':!docs/plan/2026-08-04-rebrand-segno-plan.md' ':!*.png' ':!*.ico' ':!*.glb' ':!*.zip' ':!*.gbl' ':!*.gtl' ':!*.gbs' ':!*.gts' ':!*.gto' ':!*.gbo' ':!*.gtp' ':!*.gm1' ':!*.drl' ':!*.gbrjob' || true
```

**Exit status**: `git grep` → `1` (no matches); `|| true` keeps shell exit `0`.

**Last relevant lines**:
```
(no output — zero matching lines)
GREP_EXIT:1
0 lines
```

Interpretation: no leftover `loopy` in tracked source under the given pathspecs → PASS for rebrand cleanliness.

---

## 6. Key files exist

| Path | Status |
|------|--------|
| `packages/segno_engine/lib/segno_engine.dart` | EXISTS |
| `lib/app/run_segno.dart` | EXISTS |
| `deploy/rpi/build/segno-build.sh` | EXISTS |
| `android/app/src/main/kotlin/dev/aquiles/segno/MainActivity.kt` | EXISTS |

---

## Verdict

Full verify suite **PASS**. No failed commands; no leftover `loopy` matches; all listed key files present.
