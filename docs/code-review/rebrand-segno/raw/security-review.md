# Security Review — Loopy → Segno rebrand

**Agent:** security-review  
**Critical:** 0 | **Important:** 0 | **Suggestion:** 4

## Conclusion

No critical or important exploitable issues. OTA defaults, RAUC compatible strings,
and Dart/shell path renames align on `segno.aquiles.dev` and `/etc|/data/segno/*`.
Brand assets contain no credentials.

## Suggestions (hygiene)

1. **Shell OTA channel normalization** — mirror Dart `normalizeUpdateChannel` in
   `segno-ota-check` / `segno-update-ctl` (`experimental` | `production` only).
2. **Manifest artifact basename hardening** — reject `../` in bundle/hex names
   before download (pre-existing pattern).
3. **Data-path migration** — document or script `/data/loopy/*` → `/data/segno/*`
   for appliances that keep `/data` across the image cutover.
4. **Stale Android Kotlin path** — agent reported `dev/loopy/loopy`; verified
   already removed (only `dev/aquiles/segno` remains).

## Positive controls

- RAUC keys gitignored under `meta-segno/.rauc-keys/`
- OTA: curl timeouts, manifest SHA-256, RAUC install gate
- CI validates artifact checksums against published manifest
- No `loopy` update URLs left under `deploy/`
