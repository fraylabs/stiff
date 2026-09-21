#include <curl/curl.h>
#include <json-c/json.h>
#include <limits.h>
#include <math.h>

#define STIFF_MAX_HEADERS 128
typedef struct { char *name, *value; } StiffHeader;

typedef struct {
  StiffHeader headers[STIFF_MAX_HEADERS];
  size_t header_count;
  StiffHeader response_headers[STIFF_MAX_HEADERS];
  size_t response_count, response_header_bytes, response_field_count;
  int response_started, response_headers_done, response_interim;
  char *method, *url, *body, *response;
  size_t body_size, used, capacity, limit;
  long timeout, status;
  const char* error;
} StiffRequest;

// ASCII-only comparison: HTTP field names are ASCII tokens, independent of locale.
static int stiff_header_eq(const char* a, const char* b) {
  while (*a && *b) {
    unsigned x = (unsigned char)*a++, y = (unsigned char)*b++;
    if (x >= 'A' && x <= 'Z') x += 'a' - 'A';
    if (y >= 'A' && y <= 'Z') y += 'a' - 'A';
    if (x != y) return 0;
  }
  return *a == *b;
}

static int stiff_header_valid(const char* name, size_t n, const char* value, size_t v) {
  if (!n || n > 8192 || v > 8192) return 0;
  for (size_t i = 0; i < n; i++) {
    unsigned c = (unsigned char)name[i];
    if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
      || (c && strchr("!#$%&'*+-.^_`|~", c)))) return 0;
  }
  for (size_t i = 0; i < v; i++) {
    unsigned c = (unsigned char)value[i];
    if ((c < 32 && c != '\t') || c == 127) return 0;
  }
  // The transport owns routing, framing, compression and connection management.
  const char* reserved[] = {"Host", "Content-Length", "Transfer-Encoding", "Connection",
    "Expect", "Trailer", "Upgrade", "Proxy-Authorization", "Proxy-Connection", "Accept-Encoding", "TE"};
  for (size_t i = 0; i < sizeof(reserved) / sizeof(*reserved); i++)
    if (stiff_header_eq(name, reserved[i])) return 0;
  return 1;
}

static int stiff_has_header(StiffRequest* request, const char* name, size_t before) {
  for (size_t i = 0; i < before; i++)
    if (stiff_header_eq(request->headers[i].name, name)) return 1;
  return 0;
}

// Native effects share one generated translation unit and one libcurl lifetime.
#ifndef STIFF_CURL_INIT_DEFINED
#define STIFF_CURL_INIT_DEFINED
static pthread_once_t stiff_curl_once = PTHREAD_ONCE_INIT;
static CURLcode stiff_curl_ready;
static void stiff_curl_init(void) { stiff_curl_ready = curl_global_init(CURL_GLOBAL_DEFAULT); }
#endif

static int stiff_utf8(const unsigned char* p, size_t n) {
  size_t i = 0;
  while (i < n) {
    unsigned c = p[i++], count, lo = 0x80, hi = 0xbf;
    if (c < 0x80) continue;
    if (c >= 0xc2 && c <= 0xdf) count = 1;
    else if (c >= 0xe0 && c <= 0xef) {
      count = 2; if (c == 0xe0) lo = 0xa0; if (c == 0xed) hi = 0x9f;
    } else if (c >= 0xf0 && c <= 0xf4) {
      count = 3; if (c == 0xf0) lo = 0x90; if (c == 0xf4) hi = 0x8f;
    } else return 0;
    if (n - i < count || p[i] < lo || p[i] > hi) return 0;
    i++;
    while (--count) if (p[i] < 0x80 || p[i++] > 0xbf) return 0;
  }
  return 1;
}

static void stiff_clear_response_headers(StiffRequest* request) {
  for (size_t i = 0; i < request->response_count; i++) {
    free(request->response_headers[i].name);
    free(request->response_headers[i].value);
  }
  request->response_count = 0;
}

// Bound all callback data, including informational responses and trailers.
// Only the final response's initial fields are exposed.
static size_t stiff_receive_header(char* data, size_t size, size_t count, void* context) {
  StiffRequest* request = context;
  if (size && count > SIZE_MAX / size) goto too_large;
  size_t n = size * count;
  if (n > 8192 || n > 65536 - request->response_header_bytes) goto too_large;
  request->response_header_bytes += n;
  size_t end = n;
  if (end && data[end - 1] == '\n') end--;
  if (end && data[end - 1] == '\r') end--;
  for (size_t i = 0; i < end; i++) {
    unsigned c = (unsigned char)data[i];
    if ((c < 32 && c != '\t') || c == 127) goto invalid;
  }
  if (end >= 5 && !memcmp(data, "HTTP/", 5)) {
    // Only informational responses may precede another status line. In
    // particular, a malformed trailer must not reset final response metadata.
    if (request->response_started && (!request->response_headers_done || !request->response_interim)) goto invalid;
    size_t code = 5;
    while (code < end && data[code] != ' ') code++;
    while (code < end && data[code] == ' ') code++;
    if (end - code < 3 || data[code] < '1' || data[code] > '9'
      || data[code + 1] < '0' || data[code + 1] > '9'
      || data[code + 2] < '0' || data[code + 2] > '9') goto invalid;
    request->response_interim = data[code] == '1';
    stiff_clear_response_headers(request);
    request->response_started = 1;
    request->response_headers_done = 0;
    return n;
  }
  if (!request->response_started) goto invalid;
  if (!end) { request->response_headers_done = 1; return n; }
  if (++request->response_field_count > STIFF_MAX_HEADERS) goto too_large;
  size_t colon = 0;
  while (colon < end && data[colon] != ':') {
    unsigned c = (unsigned char)data[colon];
    if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
      || (c && strchr("!#$%&'*+-.^_`|~", c)))) goto invalid;
    colon++;
  }
  if (!colon || colon == end) goto invalid;
  size_t start = colon + 1;
  while (start < end && (data[start] == ' ' || data[start] == '\t')) start++;
  while (end > start && (data[end - 1] == ' ' || data[end - 1] == '\t')) end--;
  if (!stiff_utf8((unsigned char*)data + start, end - start)) goto invalid;
  if (request->response_headers_done) return n; // Trailer: never override initial metadata.
  StiffHeader* header = &request->response_headers[request->response_count];
  header->name = malloc(colon + 1);
  header->value = malloc(end - start + 1);
  if (!header->name || !header->value) {
    free(header->name); free(header->value);
    request->error = "network";
    return 0;
  }
  for (size_t i = 0; i < colon; i++) {
    unsigned c = (unsigned char)data[i];
    header->name[i] = c >= 'A' && c <= 'Z' ? c + ('a' - 'A') : c;
  }
  header->name[colon] = 0;
  memcpy(header->value, data + start, end - start);
  header->value[end - start] = 0;
  request->response_count++;
  return n;
too_large:
  request->error = "headers_too_large";
  return 0;
invalid:
  request->error = "invalid_response_header";
  return 0;
}

static int stiff_json_finite(struct json_object* value) {
  if (json_object_is_type(value, json_type_double)) return isfinite(json_object_get_double(value));
  if (json_object_is_type(value, json_type_array)) {
    for (size_t i = 0; i < json_object_array_length(value); i++)
      if (!stiff_json_finite(json_object_array_get_idx(value, i))) return 0;
  } else if (json_object_is_type(value, json_type_object)) {
    json_object_object_foreach(value, key, child) { (void)key; if (!stiff_json_finite(child)) return 0; }
  }
  return 1;
}

static int stiff_valid_json(const char* text, size_t length) {
  if (length >= INT_MAX) return 0;
  struct json_tokener* parser = json_tokener_new_ex(130);
  if (!parser) return 0;
  json_tokener_set_flags(parser, JSON_TOKENER_STRICT | JSON_TOKENER_VALIDATE_UTF8);
  struct json_object* value = json_tokener_parse_ex(parser, text, (int)length + 1);
  int ok = json_tokener_get_error(parser) == json_tokener_success
    && json_tokener_get_parse_end(parser) >= length && stiff_json_finite(value);
  json_object_put(value);
  json_tokener_free(parser);
  return ok;
}

static size_t stiff_receive(char* data, size_t size, size_t count, void* context) {
  StiffRequest* request = context;
  if (size != 0 && count > SIZE_MAX / size) { request->error = "body_too_large"; return 0; }
  size_t n = size * count;
  if (n > request->limit - request->used) { request->error = "body_too_large"; return 0; }
  size_t needed = request->used + n + 1;
  if (needed > request->capacity) {
    size_t capacity = request->capacity ? request->capacity * 2 : 4096;
    if (capacity < needed) capacity = needed;
    if (capacity > request->limit + 1) capacity = request->limit + 1;
    char* grown = realloc(request->response, capacity);
    if (!grown) { request->error = "network"; return 0; }
    request->response = grown;
    request->capacity = capacity;
  }
  if (n) memcpy(request->response + request->used, data, n);
  request->used += n;
  request->response[request->used] = 0;
  return n;
}

// Only these exact methods can carry a JSON request body.
static int stiff_json_method(const char* method) {
  return !strcmp(method, "POST") || !strcmp(method, "PUT") || !strcmp(method, "PATCH");
}

static void stiff_send_call(IoWork* work) {
  StiffRequest* request = (StiffRequest*)work->data;
  pthread_once(&stiff_curl_once, stiff_curl_init);
  if (stiff_curl_ready != CURLE_OK) { request->error = "network"; return; }
  CURL* curl = curl_easy_init();
  CURLU* url = curl_url();
  struct curl_slist* headers = NULL;
  char *user = NULL, *password = NULL;
  if (!curl || !url) { request->error = "network"; goto done; }
  if ((strncmp(request->url, "https://", 8) && strncmp(request->url, "http://", 7))
    || curl_url_set(url, CURLUPART_URL, request->url, 0) != CURLUE_OK) {
    request->error = "invalid_request"; goto done;
  }
  curl_url_get(url, CURLUPART_USER, &user, 0);
  curl_url_get(url, CURLUPART_PASSWORD, &password, 0);
  if ((user && *user) || (password && *password)) { request->error = "invalid_request"; goto done; }
  for (size_t i = 0; i < request->header_count; i++) {
    StiffHeader* header = &request->headers[i];
    if (stiff_has_header(request, header->name, i)) continue;
    size_t n = strlen(header->name), v = strlen(header->value);
    char* line = malloc(n + v + 3);
    if (!line) { request->error = "network"; goto done; }
    // libcurl's semicolon form sends an explicitly empty value.
    if (v) snprintf(line, n + v + 3, "%s: %s", header->name, header->value);
    else snprintf(line, n + v + 3, "%s;", header->name);
    struct curl_slist* next = curl_slist_append(headers, line);
    free(line);
    if (!next) { request->error = "network"; goto done; }
    headers = next;
  }
  if (!stiff_has_header(request, "Accept", request->header_count)) {
    struct curl_slist* next = curl_slist_append(headers, "Accept: application/json");
    if (!next) { request->error = "network"; goto done; }
    headers = next;
  }
  if (stiff_json_method(request->method)) {
    if (!stiff_valid_json(request->body, request->body_size)) { request->error = "invalid_json_request"; goto done; }
    if (!stiff_has_header(request, "Content-Type", request->header_count)) {
      struct curl_slist* next = curl_slist_append(headers, "Content-Type: application/json");
      if (!next) { request->error = "network"; goto done; }
      headers = next;
    }
  }
#define STIFF_SET(option, value) do { if (curl_easy_setopt(curl, option, value) != CURLE_OK) { request->error = "network"; goto done; } } while (0)
  STIFF_SET(CURLOPT_CURLU, url);
  STIFF_SET(CURLOPT_PROTOCOLS_STR, "http,https");
  STIFF_SET(CURLOPT_FOLLOWLOCATION, 0L);
  STIFF_SET(CURLOPT_SSL_VERIFYPEER, 1L);
  STIFF_SET(CURLOPT_SSL_VERIFYHOST, 2L);
  STIFF_SET(CURLOPT_NOSIGNAL, 1L);
  STIFF_SET(CURLOPT_TIMEOUT_MS, request->timeout);
  STIFF_SET(CURLOPT_ACCEPT_ENCODING, "");
  STIFF_SET(CURLOPT_HTTPHEADER, headers);
  STIFF_SET(CURLOPT_HEADEROPT, (long)CURLHEADER_SEPARATE);
  STIFF_SET(CURLOPT_WRITEFUNCTION, stiff_receive);
  STIFF_SET(CURLOPT_WRITEDATA, request);
  STIFF_SET(CURLOPT_HEADERFUNCTION, stiff_receive_header);
  STIFF_SET(CURLOPT_HEADERDATA, request);
  STIFF_SET(CURLOPT_SUPPRESS_CONNECT_HEADERS, 1L);
  const char* ca = getenv("STIFF_CA_BUNDLE");
  if (ca && *ca) { STIFF_SET(CURLOPT_CAINFO, ca); }
  if (stiff_json_method(request->method)) {
    STIFF_SET(CURLOPT_POSTFIELDS, request->body);
    STIFF_SET(CURLOPT_POSTFIELDSIZE_LARGE, (curl_off_t)request->body_size);
    STIFF_SET(CURLOPT_CUSTOMREQUEST, request->method);
  } else if (!strcmp(request->method, "HEAD")) {
    // A custom method string alone would still wait for a response body.
    STIFF_SET(CURLOPT_NOBODY, 1L);
  } else if (!strcmp(request->method, "DELETE")) {
    STIFF_SET(CURLOPT_CUSTOMREQUEST, "DELETE");
  }
  CURLcode result = curl_easy_perform(curl);
  if (!request->error && result != CURLE_OK)
    request->error = result == CURLE_OPERATION_TIMEDOUT ? "timeout" : "network";
  if (!request->error && curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &request->status) != CURLE_OK)
    request->error = "network";
  if (!request->error && !stiff_utf8((unsigned char*)request->response, request->used)) request->error = "invalid_utf8";
  if (!request->error && request->used >= 3 && !memcmp(request->response, "\xef\xbb\xbf", 3)) {
    request->used -= 3;
    memmove(request->response, request->response + 3, request->used + 1);
  }
done:
  curl_free(user); curl_free(password);
  curl_slist_free_all(headers);
  if (url) curl_url_cleanup(url);
  if (curl) curl_easy_cleanup(curl);
#undef STIFF_SET
}

static Term stiff_send_pack(Env e, IoWork* work) {
  StiffRequest* request = (StiffRequest*)work->data;
  Term result;
  if (request->error) {
    const char* message = "Native HTTP request failed.";
    result = io_node(e, CID_HTTPERROR, io_str(e, request->error, strlen(request->error)), io_str(e, message, strlen(message)));
  } else {
    Term headers = term_pak(CID_NIL, 0);
    for (size_t i = request->response_count; i > 0; i--) {
      StiffHeader* h = &request->response_headers[i - 1];
      Term header = io_node(e, CID_RESPONSEHEADER, io_str(e, h->name, strlen(h->name)), io_str(e, h->value, strlen(h->value)));
      headers = io_node(e, CID_CON, header, headers);
    }
    // Bend 2.0.20 flattens HttpOk{Response{status, body, headers}} into three fields.
    Loc loc = heap_alloc(e, cls_fit(3));
    e.mem[loc] = request->status;
    e.mem[loc + 1] = io_str(e, request->response, request->used);
    e.mem[loc + 2] = headers;
    result = term_ctr(CID_HTTPOK, loc);
  }
  for (size_t i = 0; i < request->header_count; i++) {
    free(request->headers[i].name); free(request->headers[i].value);
  }
  stiff_clear_response_headers(request);
  free(request->method); free(request->url); free(request->body); free(request->response); free(request);
  work->data = NULL;
  return result;
}

static Term stiff_send_run(Env e, Term* f, IoWork* work) {
  Term fields[6];
  spare_free(e, cls_fit(6), ctr_take(e, f[0], 6, fields));
  StiffRequest* request = io_mem(calloc(1, sizeof(StiffRequest)));
  u64 method_size, url_size, body_size;
  request->method = io_cstr(e, fields[0], &method_size);
  request->url = io_cstr(e, fields[1], &url_size);
  request->body = io_cstr(e, fields[2], &body_size);
  request->body_size = body_size;
  request->timeout = (u32)fields[3];
  request->limit = (u32)fields[4];
  work->data = (char*)request;
  Term items = fields[5];
  size_t header_bytes = 0;
  while (term_aux(items) != CID_NIL) {
    if (request->header_count == STIFF_MAX_HEADERS) {
      term_sink(e, items);
      request->error = "invalid_header";
      break;
    }
    // List nodes hold a boxed Header and tail in Bend 2.0.20.
    Term pair[2], header[2];
    spare_free(e, cls_fit(2), ctr_take(e, items, 2, pair));
    spare_free(e, cls_fit(2), ctr_take(e, pair[0], 2, header));
    items = pair[1];
    StiffHeader* entry = &request->headers[request->header_count++];
    u64 n, v;
    entry->name = io_cstr(e, header[0], &n);
    entry->value = io_cstr(e, header[1], &v);
    if (!stiff_header_valid(entry->name, n, entry->value, v) || n + v + 4 > 65536 - header_bytes) {
      term_sink(e, items);
      request->error = "invalid_header";
      break;
    }
    header_bytes += n + v + 4;
  }
  if (io_nul(request->method, method_size) || io_nul(request->url, url_size)
    || (!stiff_json_method(request->method) && strcmp(request->method, "GET")
      && strcmp(request->method, "HEAD") && strcmp(request->method, "DELETE"))
    || (!stiff_json_method(request->method) && body_size != 0)
    || request->timeout < 1 || request->timeout > INT_MAX || request->limit < 1 || request->limit > INT_MAX) {
    request->error = "invalid_request";
    return stiff_send_pack(e, work);
  }
  if (request->error) return stiff_send_pack(e, work);
  return io_work(work, stiff_send_call, stiff_send_pack);
}

static void __attribute__((constructor)) stiff_send_register(void) {
  io_eff(CID_STIFF_SEND, stiff_send_run, 0);
}
