/*
 * json_read.h — a minimal, read-only JSON parser purpose-built for this
 * engine's own hand-rolled JSON output (`perf_drain.c`'s sidecar writer,
 * `performance_repository`'s Dart-side finalize additions).
 *
 * Not a general-purpose parser: no Unicode escapes, no exponent notation,
 * no comments — only what this codebase's own JSON writers ever emit
 * (plain ASCII strings, decimal numbers, booleans, null, nested
 * objects/arrays). It exists because `perf_render.c` (part 7) is the first
 * native module that needs to READ `performance.json` back — every other
 * native JSON producer only ever writes.
 *
 * The whole document parses into a fixed-capacity arena of `le_json_value`
 * nodes (no per-node heap allocation): the caller supplies the arena and its
 * capacity, sized generously against the largest manifest this codebase
 * writes (see perf_render.c's own sizing). Parsing fails cleanly (returns
 * NULL) if the arena is exhausted, rather than reallocating or overrunning.
 */
#ifndef LOOPY_JSON_READ_H
#define LOOPY_JSON_READ_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum le_json_type {
  LE_JSON_NULL,
  LE_JSON_BOOL,
  LE_JSON_NUMBER,
  LE_JSON_STRING,
  LE_JSON_ARRAY,
  LE_JSON_OBJECT,
} le_json_type;

/* One parsed value. Objects/arrays hold their children as a singly-linked
 * list (`first_child`/`next_sibling`) rather than a growable vector, so the
 * whole tree lives in one flat, pre-sized arena with no secondary
 * allocation. Object members additionally carry `key`. */
typedef struct le_json_value {
  le_json_type type;
  const char* key; /* non-NULL only for an object member; points into the
                    * caller's own text buffer (this parser never copies
                    * strings — see `string_start`/`string_len`) */
  int key_len;
  union {
    int bool_value;
    double number_value;
    struct {
      const char* string_start; /* points into the caller's text buffer,
                                 * between the opening/closing quotes */
      int string_len;
    };
  };
  struct le_json_value* first_child; /* OBJECT members / ARRAY elements */
  struct le_json_value* next_sibling;
} le_json_value;

/* A pre-sized node arena the parser carves `le_json_value`s out of. */
typedef struct le_json_arena {
  le_json_value* nodes;
  int capacity;
  int used;
} le_json_arena;

/* Parses `text` (NUL-terminated) into a tree of nodes carved from `arena`,
 * returning the root value, or NULL if the text is malformed JSON or the
 * arena runs out of capacity. `text` must outlive every `le_json_value` this
 * call returns (strings/keys point directly into it — no copies). */
le_json_value* le_json_parse(const char* text, le_json_arena* arena);

/* Looks up member `key` in OBJECT `obj`, or NULL if `obj` is not an object,
 * `key` is absent, or `obj` is NULL. */
const le_json_value* le_json_get(const le_json_value* obj, const char* key);

/* Returns the number of elements in ARRAY `arr` (or OBJECT `arr`'s member
 * count), or 0 if `arr` is NULL or not an array/object. */
int le_json_length(const le_json_value* arr);

/* Returns ARRAY `arr`'s element at `index` (0-based), or NULL if out of
 * range or `arr` is not an array. */
const le_json_value* le_json_at(const le_json_value* arr, int index);

/* Scalar accessors. Each returns `fallback` if `value` is NULL or not the
 * expected type — every call site treats a schema mismatch as "absent", the
 * same defaulting convention the Dart-side `fromJson` factories use. */
double le_json_number(const le_json_value* value, double fallback);
int le_json_bool(const le_json_value* value, int fallback);

/* Copies `value`'s string content (NOT NUL-terminated in the source text) to
 * `out`, NUL-terminating within `out_cap`. Returns 1 on success, 0 if
 * `value` is NULL, not a string, or does not fit in `out_cap`. */
int le_json_string(const le_json_value* value, char* out, size_t out_cap);

#ifdef __cplusplus
}
#endif

#endif /* LOOPY_JSON_READ_H */
