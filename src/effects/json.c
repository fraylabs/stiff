#include <json-c/json.h>
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

static const char* stiff_json_check(struct json_object* value, unsigned depth) {
  if (depth > 128) return "json_too_deep";
  enum json_type type = json_object_get_type(value);
  if ((type == json_type_double || type == json_type_int) && !isfinite(json_object_get_double(value))) return "json_number_range";
  if (type == json_type_int && fabs(json_object_get_double(value)) > 9007199254740991.0) return "json_number_range";
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

static void __attribute__((constructor)) stiff_json_register(void) {
  io_eff(CID_JSON_PARSE, json_parse_run, 0);
}
