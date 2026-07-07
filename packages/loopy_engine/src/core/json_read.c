#include "json_read.h"

#include <stdlib.h>
#include <string.h>

typedef struct le_json_parser {
  const char* s;
  int i;
  le_json_arena* arena;
  int failed;
} le_json_parser;

static void skip_ws(le_json_parser* p) {
  while (p->s[p->i] == ' ' || p->s[p->i] == '\t' || p->s[p->i] == '\n' ||
         p->s[p->i] == '\r') {
    p->i++;
  }
}

static le_json_value* alloc_node(le_json_parser* p) {
  if (p->arena->used >= p->arena->capacity) {
    p->failed = 1;
    return NULL;
  }
  le_json_value* v = &p->arena->nodes[p->arena->used++];
  v->key = NULL;
  v->key_len = 0;
  v->first_child = NULL;
  v->next_sibling = NULL;
  return v;
}

/* Parses a quoted string starting at the opening '"' (p->i points at it),
 * leaving p->i just past the closing '"'. Handles only the escapes this
 * codebase's own writers ever emit (`\"`, `\\`) — anything else is copied
 * through literally rather than rejected, since a stray unknown escape in a
 * file this engine wrote itself would indicate a bug elsewhere, not
 * malicious input this parser must harden against. */
static int parse_string_span(le_json_parser* p, const char** out_start,
                             int* out_len) {
  if (p->s[p->i] != '"') return 0;
  p->i++;
  const int start = p->i;
  while (p->s[p->i] != '\0' && p->s[p->i] != '"') {
    if (p->s[p->i] == '\\' && p->s[p->i + 1] != '\0') {
      p->i += 2;
    } else {
      p->i++;
    }
  }
  if (p->s[p->i] != '"') return 0;
  *out_start = p->s + start;
  *out_len = p->i - start;
  p->i++;
  return 1;
}

static le_json_value* parse_value(le_json_parser* p);

static le_json_value* parse_object(le_json_parser* p) {
  le_json_value* obj = alloc_node(p);
  if (obj == NULL) return NULL;
  obj->type = LE_JSON_OBJECT;
  p->i++; /* '{' */
  skip_ws(p);
  le_json_value* tail = NULL;
  if (p->s[p->i] == '}') {
    p->i++;
    return obj;
  }
  for (;;) {
    skip_ws(p);
    const char* key_start;
    int key_len;
    if (!parse_string_span(p, &key_start, &key_len)) {
      p->failed = 1;
      return NULL;
    }
    skip_ws(p);
    if (p->s[p->i] != ':') {
      p->failed = 1;
      return NULL;
    }
    p->i++;
    skip_ws(p);
    le_json_value* member = parse_value(p);
    if (member == NULL) return NULL;
    member->key = key_start;
    member->key_len = key_len;
    if (tail == NULL) {
      obj->first_child = member;
    } else {
      tail->next_sibling = member;
    }
    tail = member;
    skip_ws(p);
    if (p->s[p->i] == ',') {
      p->i++;
      continue;
    }
    if (p->s[p->i] == '}') {
      p->i++;
      return obj;
    }
    p->failed = 1;
    return NULL;
  }
}

static le_json_value* parse_array(le_json_parser* p) {
  le_json_value* arr = alloc_node(p);
  if (arr == NULL) return NULL;
  arr->type = LE_JSON_ARRAY;
  p->i++; /* '[' */
  skip_ws(p);
  le_json_value* tail = NULL;
  if (p->s[p->i] == ']') {
    p->i++;
    return arr;
  }
  for (;;) {
    skip_ws(p);
    le_json_value* element = parse_value(p);
    if (element == NULL) return NULL;
    if (tail == NULL) {
      arr->first_child = element;
    } else {
      tail->next_sibling = element;
    }
    tail = element;
    skip_ws(p);
    if (p->s[p->i] == ',') {
      p->i++;
      continue;
    }
    if (p->s[p->i] == ']') {
      p->i++;
      return arr;
    }
    p->failed = 1;
    return NULL;
  }
}

static le_json_value* parse_value(le_json_parser* p) {
  skip_ws(p);
  const char c = p->s[p->i];
  if (c == '{') return parse_object(p);
  if (c == '[') return parse_array(p);
  if (c == '"') {
    le_json_value* v = alloc_node(p);
    if (v == NULL) return NULL;
    v->type = LE_JSON_STRING;
    if (!parse_string_span(p, &v->string_start, &v->string_len)) {
      p->failed = 1;
      return NULL;
    }
    return v;
  }
  if (c == 't' && strncmp(p->s + p->i, "true", 4) == 0) {
    le_json_value* v = alloc_node(p);
    if (v == NULL) return NULL;
    v->type = LE_JSON_BOOL;
    v->bool_value = 1;
    p->i += 4;
    return v;
  }
  if (c == 'f' && strncmp(p->s + p->i, "false", 5) == 0) {
    le_json_value* v = alloc_node(p);
    if (v == NULL) return NULL;
    v->type = LE_JSON_BOOL;
    v->bool_value = 0;
    p->i += 5;
    return v;
  }
  if (c == 'n' && strncmp(p->s + p->i, "null", 4) == 0) {
    le_json_value* v = alloc_node(p);
    if (v == NULL) return NULL;
    v->type = LE_JSON_NULL;
    p->i += 4;
    return v;
  }
  if (c == '-' || (c >= '0' && c <= '9')) {
    char* end = NULL;
    const double n = strtod(p->s + p->i, &end);
    if (end == p->s + p->i) {
      p->failed = 1;
      return NULL;
    }
    le_json_value* v = alloc_node(p);
    if (v == NULL) return NULL;
    v->type = LE_JSON_NUMBER;
    v->number_value = n;
    p->i = (int)(end - p->s);
    return v;
  }
  p->failed = 1;
  return NULL;
}

le_json_value* le_json_parse(const char* text, le_json_arena* arena) {
  if (text == NULL || arena == NULL) return NULL;
  arena->used = 0;
  le_json_parser p = {.s = text, .i = 0, .arena = arena, .failed = 0};
  le_json_value* root = parse_value(&p);
  if (p.failed) return NULL;
  return root;
}

const le_json_value* le_json_get(const le_json_value* obj, const char* key) {
  if (obj == NULL || obj->type != LE_JSON_OBJECT || key == NULL) return NULL;
  const size_t key_len = strlen(key);
  for (const le_json_value* c = obj->first_child; c != NULL;
       c = c->next_sibling) {
    if ((size_t)c->key_len == key_len &&
        strncmp(c->key, key, key_len) == 0) {
      return c;
    }
  }
  return NULL;
}

int le_json_length(const le_json_value* arr) {
  if (arr == NULL ||
      (arr->type != LE_JSON_ARRAY && arr->type != LE_JSON_OBJECT)) {
    return 0;
  }
  int n = 0;
  for (const le_json_value* c = arr->first_child; c != NULL;
       c = c->next_sibling) {
    n++;
  }
  return n;
}

const le_json_value* le_json_at(const le_json_value* arr, int index) {
  if (arr == NULL || arr->type != LE_JSON_ARRAY || index < 0) return NULL;
  int n = 0;
  for (const le_json_value* c = arr->first_child; c != NULL;
       c = c->next_sibling, ++n) {
    if (n == index) return c;
  }
  return NULL;
}

double le_json_number(const le_json_value* value, double fallback) {
  if (value == NULL || value->type != LE_JSON_NUMBER) return fallback;
  return value->number_value;
}

int le_json_bool(const le_json_value* value, int fallback) {
  if (value == NULL || value->type != LE_JSON_BOOL) return fallback;
  return value->bool_value;
}

int le_json_string(const le_json_value* value, char* out, size_t out_cap) {
  if (value == NULL || value->type != LE_JSON_STRING || out_cap == 0) {
    return 0;
  }
  if ((size_t)value->string_len >= out_cap) return 0;
  memcpy(out, value->string_start, (size_t)value->string_len);
  out[value->string_len] = '\0';
  return 1;
}
