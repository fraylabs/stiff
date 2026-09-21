#include <json-c/json.h>
#include <limits.h>
#include <math.h>

static unsigned stiff_hex4(const char* text) {
  unsigned value = 0;
  for (int i = 0; i < 4; i++) {
    unsigned c = (unsigned char)text[i];
    unsigned digit = c >= '0' && c <= '9' ? c - '0'
      : c >= 'a' && c <= 'f' ? c - 'a' + 10 : c >= 'A' && c <= 'F' ? c - 'A' + 10 : 16;
    if (digit == 16) return UINT_MAX;
    value = value * 16 + digit;
  }
  return value;
}

// Prevent json-c's lossy cases: C-string NUL keys and lone surrogate escapes.
// Syntax validation itself remains with json-c.
static int stiff_json_subset_valid(const char* text, size_t n) {
  for (size_t i = 0; i < n; i++) {
    if (text[i] != '"') continue;
    int nul = 0;
    while (++i < n) {
      if (text[i] == '\\') {
        i++;
        if (i + 4 < n && !memcmp(text + i, "u0000", 5)) nul = 1;
        if (i + 4 < n && text[i] == 'u') {
          unsigned unit = stiff_hex4(text + i + 1);
          if (unit >= 0xd800 && unit <= 0xdbff) {
            if (i + 10 >= n || text[i + 5] != '\\' || text[i + 6] != 'u') return 0;
            unsigned low = stiff_hex4(text + i + 7);
            if (low < 0xdc00 || low > 0xdfff) return 0;
            i += 10;
          } else if (unit >= 0xdc00 && unit <= 0xdfff) return 0;
        }
      } else if (text[i] == '"') break;
    }
    size_t next = i + 1;
    while (next < n && (text[next] == ' ' || text[next] == '\t' || text[next] == '\r' || text[next] == '\n')) next++;
    if (nul && next < n && text[next] == ':') return 0;
  }
  return 1;
}

// Exact JSON number grammar; json-c's strict mode still accepts e.g. "1.".
static int stiff_json_number_syntax(const char* text, size_t n) {
  size_t i = 0;
  if (i < n && text[i] == '-') i++;
  if (i == n) return 0;
  if (text[i] == '0') i++;
  else {
    if (text[i] < '1' || text[i] > '9') return 0;
    do { i++; } while (i < n && text[i] >= '0' && text[i] <= '9');
  }
  if (i < n && text[i] == '.') {
    i++;
    size_t start = i;
    while (i < n && text[i] >= '0' && text[i] <= '9') i++;
    if (i == start) return 0;
  }
  if (i < n && (text[i] == 'e' || text[i] == 'E')) {
    i++;
    if (i < n && (text[i] == '+' || text[i] == '-')) i++;
    size_t start = i;
    while (i < n && text[i] >= '0' && text[i] <= '9') i++;
    if (i == start) return 0;
  }
  return i == n;
}

static const char* stiff_json_check(struct json_object* value, unsigned depth) {
  if (depth > 128) return "json_too_deep";
  enum json_type type = json_object_get_type(value);
  if ((type == json_type_double || type == json_type_int) && !isfinite(json_object_get_double(value))) return "json_number_range";
  if (type == json_type_int && fabs(json_object_get_double(value)) > 9007199254740991.0) return "json_number_range";
  if (type == json_type_double || type == json_type_int) {
    const char* number = json_object_get_string(value);
    if (!stiff_json_number_syntax(number, strlen(number))) return "invalid_json_response";
  }
  if (type == json_type_array) {
    for (size_t i = 0; i < json_object_array_length(value); i++) {
      const char* error = stiff_json_check(json_object_array_get_idx(value, i), depth + 1);
      if (error) return error;
    }
  } else if (type == json_type_object) {
    json_object_object_foreach(value, key, child) {
      (void)key;
      const char* error = stiff_json_check(child, depth + 1);
      if (error) return error;
    }
  }
  return NULL;
}

#ifdef CID_JSON_PARSE
static Term stiff_json_value(Env e, struct json_object* value, unsigned depth, const char** error) {
  if (depth > 128) { *error = "json_too_deep"; return 0; }
  switch (json_object_get_type(value)) {
    case json_type_null: return term_pak(CID_JSONNULL, 0);
    case json_type_boolean:
      // The single scalar field is packed into the constructor word, not the heap.
      return term_pak(CID_JSONBOOL, json_object_get_boolean(value) != 0);
    case json_type_int:
    case json_type_double: {
      double n = json_object_get_double(value);
      if (!isfinite(n)) { *error = "json_number_range"; return 0; }
      const char* text = json_object_get_string(value);
      return io_box(e, CID_JSONNUMBER, io_str(e, text, strlen(text)));
    }
    case json_type_string:
      return io_box(e, CID_JSONSTRING, io_str(e, json_object_get_string(value), json_object_get_string_len(value)));
    case json_type_array: {
      Term items = term_pak(CID_NIL, 0);
      size_t n = json_object_array_length(value);
      while (n > 0) {
        Term item = stiff_json_value(e, json_object_array_get_idx(value, --n), depth + 1, error);
        if (*error) return 0;
        items = io_node(e, CID_CON, item, items);
      }
      return io_box(e, CID_JSONARRAY, items);
    }
    case json_type_object: {
      Term entries = term_pak(CID_NIL, 0);
      // Object fields are unique after json-c decoding; lookup does not depend on order.
      json_object_object_foreach(value, key, child) {
        Term item = stiff_json_value(e, child, depth + 1, error);
        if (*error) return 0;
        Term pair = io_node(e, CID_TUPLE, io_str(e, key, strlen(key)), item);
        entries = io_node(e, CID_CON, pair, entries);
      }
      return io_box(e, CID_JSONOBJECT, entries);
    }
  }
  *error = "invalid_json_response";
  return 0;
}

static Term json_parse_run(Env e, Term* f, IoWork* w) {
  (void)w;
  u64 length;
  char* text = io_cstr(e, f[0], &length);
  const char* error = NULL;
  struct json_tokener* parser = json_tokener_new_ex(130);
  if (!parser) { free(text); err_fail("json-c allocation failed"); }
  json_tokener_set_flags(parser, JSON_TOKENER_STRICT | JSON_TOKENER_VALIDATE_UTF8);
  struct json_object* value = length < INT_MAX
    ? json_tokener_parse_ex(parser, text, (int)length + 1) : NULL;
  enum json_tokener_error status = json_tokener_get_error(parser);
  if (length >= INT_MAX || status != json_tokener_success || json_tokener_get_parse_end(parser) < length
    || !stiff_json_subset_valid(text, length)) {
    error = status == json_tokener_error_depth ? "json_too_deep" : "invalid_json_response";
  }
  if (!error) error = stiff_json_check(value, 0);
  Term result = error ? 0 : stiff_json_value(e, value, 0, &error);
  json_object_put(value);
  json_tokener_free(parser);
  free(text);
  if (error) return io_node(e, CID_JSONFAILURE, io_str(e, error, strlen(error)),
    io_str(e, "Native JSON decoding failed.", strlen("Native JSON decoding failed.")));
  return io_box(e, CID_JSONDONE, result);
}

#endif

#ifdef CID_JSON_STRINGIFY_WITH_LIMIT
typedef struct {
  char* text;
  size_t used, capacity, limit;
  const char* error;
} StiffJsonOutput;

static void stiff_json_append(StiffJsonOutput* out, const char* text, size_t n) {
  if (out->error) return;
  if (n > out->limit - out->used) { out->error = "json_too_large"; return; }
  size_t needed = out->used + n + 1;
  if (needed > out->capacity) {
    size_t capacity = out->capacity ? out->capacity * 2 : 64;
    if (capacity < needed) capacity = needed;
    if (capacity > out->limit + 1) capacity = out->limit + 1;
    out->text = io_mem(realloc(out->text, capacity)); out->capacity = capacity;
  }
  memcpy(out->text + out->used, text, n);
  out->used += n; out->text[out->used] = 0;
}

// Consume the Bend string while checking scalar validity before UTF-8 encoding.
// Input extraction is bounded too, rather than allocating an unbounded C string.
static char* stiff_json_text(Env e, Term text, size_t* size, StiffJsonOutput* out) {
  StiffJsonOutput raw = {.limit = out->limit};
  while (term_aux(text) == CID_SCON) {
    Term fields[2];
    spare_free(e, cls_fit(2), ctr_take(e, text, 2, fields));
    text = fields[1];
    u64 c = fields[0];
    if (c > 0x10ffff || (c >= 0xd800 && c <= 0xdfff)) raw.error = "invalid_json_value";
    else {
      char bytes[4];
      size_t n = io_utf8(bytes, c);
      stiff_json_append(&raw, bytes, n);
    }
    if (raw.error) { term_sink(e, text); out->error = raw.error; break; }
  }
  if (!raw.text) raw.text = io_mem(calloc(1, 1));
  *size = raw.used;
  return raw.text;
}
static void stiff_json_quote(StiffJsonOutput* out, const char* text, size_t n) {
  static const char hex[] = "0123456789abcdef";
  stiff_json_append(out, "\"", 1);
  for (size_t i = 0; i < n && !out->error; i++) {
    unsigned c = (unsigned char)text[i];
    if (c == '"' || c == '\\') {
      char escaped[2] = {'\\', (char)c}; stiff_json_append(out, escaped, 2);
    } else if (c < 32) {
      char escaped[6] = {'\\', 'u', '0', '0', hex[c >> 4], hex[c & 15]};
      stiff_json_append(out, escaped, 6);
    } else stiff_json_append(out, text + i, 1);
  }
  stiff_json_append(out, "\"", 1);
}
static void stiff_json_number(StiffJsonOutput* out, const char* text, size_t n) {
  if (out->error) return;
  if (n >= INT_MAX || !stiff_json_number_syntax(text, n)) {
    out->error = "invalid_json_value"; return;
  }
  struct json_tokener* parser = json_tokener_new();
  if (!parser) err_fail("json-c allocation failed");
  json_tokener_set_flags(parser, JSON_TOKENER_STRICT);
  struct json_object* value = json_tokener_parse_ex(parser, text, (int)n + 1);
  if (json_tokener_get_error(parser) != json_tokener_success
    || json_tokener_get_parse_end(parser) != n
    || !(json_object_is_type(value, json_type_int) || json_object_is_type(value, json_type_double)))
    out->error = "invalid_json_value";
  else out->error = stiff_json_check(value, 0);
  json_object_put(value); json_tokener_free(parser);
  if (!out->error) stiff_json_append(out, text, n);
}
static void stiff_json_encode(Env e, Term value, unsigned depth, StiffJsonOutput* out) {
  if (out->error || depth > 128) {
    if (!out->error) out->error = "json_too_deep";
    term_sink(e, value); return;
  }
  u32 tag = term_aux(value);
  if (tag == CID_JSONNULL) { stiff_json_append(out, "null", 4); return; }
  if (tag == CID_JSONBOOL) {
    int yes = term_loc(value) != 0;
    stiff_json_append(out, yes ? "true" : "false", yes ? 4 : 5); return;
  }
  Term fields[1];
  spare_free(e, cls_fit(1), ctr_take(e, value, 1, fields));
  if (tag == CID_JSONSTRING || tag == CID_JSONNUMBER) {
    size_t n;
    char* text = stiff_json_text(e, fields[0], &n, out);
    if (tag == CID_JSONSTRING) stiff_json_quote(out, text, n);
    else stiff_json_number(out, text, n);
    free(text); return;
  }
  int object = tag == CID_JSONOBJECT;
  struct json_object* seen = object ? json_object_new_object() : NULL;
  if (object && !seen) err_fail("json-c allocation failed");
  stiff_json_append(out, object ? "{" : "[", 1);
  Term items = fields[0];
  int first = 1;
  while (term_aux(items) != CID_NIL && !out->error) {
    Term pair[2];
    spare_free(e, cls_fit(2), ctr_take(e, items, 2, pair));
    items = pair[1];
    if (!first) stiff_json_append(out, ",", 1);
    first = 0;
    if (object) {
      Term entry[2];
      spare_free(e, cls_fit(2), ctr_take(e, pair[0], 2, entry));
      size_t n;
      char* key = stiff_json_text(e, entry[0], &n, out);
      struct json_object* previous;
      if (!out->error && (strlen(key) != n || json_object_object_get_ex(seen, key, &previous)))
        out->error = "invalid_json_value";
      if (!out->error) {
        if (json_object_object_add(seen, key, NULL)) err_fail("json-c allocation failed");
        stiff_json_quote(out, key, n); stiff_json_append(out, ":", 1);
      }
      free(key);
      stiff_json_encode(e, entry[1], depth + 1, out);
    } else stiff_json_encode(e, pair[0], depth + 1, out);
  }
  term_sink(e, items);
  if (seen) json_object_put(seen);
  stiff_json_append(out, object ? "}" : "]", 1);
}
static Term json_stringify_with_limit_run(Env e, Term* f, IoWork* w) {
  (void)w;
  StiffJsonOutput out = {.limit = (u32)f[1]};
  if (!out.limit || out.limit > 16777216) out.error = "invalid_json_limit";
  stiff_json_encode(e, f[0], 0, &out);
  Term result;
  if (out.error) result = io_node(e, CID_JSONENCODEFAILURE,
    io_str(e, out.error, strlen(out.error)), io_str(e, "Native JSON encoding failed.", strlen("Native JSON encoding failed.")));
  else result = io_box(e, CID_JSONENCODED, io_str(e, out.text, out.used));
  free(out.text);
  return result;
}
#endif

static void __attribute__((constructor)) stiff_json_register(void) {
#ifdef CID_JSON_PARSE
  io_eff(CID_JSON_PARSE, json_parse_run, 0);
#endif
#ifdef CID_JSON_STRINGIFY_WITH_LIMIT
  io_eff(CID_JSON_STRINGIFY_WITH_LIMIT, json_stringify_with_limit_run, 0);
#endif
}
