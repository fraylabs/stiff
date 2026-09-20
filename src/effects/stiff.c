#include <curl/curl.h>
#include <json-c/json.h>
#include <limits.h>
#include <math.h>

typedef struct {
  char *method, *url, *body, *response;
  size_t body_size, used, capacity, limit;
  long timeout, status;
  const char* error;
} StiffRequest;

static pthread_once_t stiff_curl_once = PTHREAD_ONCE_INIT;
static CURLcode stiff_curl_ready;
static void stiff_curl_init(void) { stiff_curl_ready = curl_global_init(CURL_GLOBAL_DEFAULT); }

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
  headers = curl_slist_append(NULL, "Accept: application/json");
  if (!headers) { request->error = "network"; goto done; }
  if (!strcmp(request->method, "POST")) {
    if (!stiff_valid_json(request->body, request->body_size)) { request->error = "invalid_json_request"; goto done; }
    struct curl_slist* next = curl_slist_append(headers, "Content-Type: application/json");
    if (!next) { request->error = "network"; goto done; }
    headers = next;
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
  STIFF_SET(CURLOPT_WRITEFUNCTION, stiff_receive);
  STIFF_SET(CURLOPT_WRITEDATA, request);
  const char* ca = getenv("STIFF_CA_BUNDLE");
  if (ca && *ca) { STIFF_SET(CURLOPT_CAINFO, ca); }
  if (!strcmp(request->method, "POST")) {
    STIFF_SET(CURLOPT_POST, 1L);
    STIFF_SET(CURLOPT_POSTFIELDS, request->body);
    STIFF_SET(CURLOPT_POSTFIELDSIZE_LARGE, (curl_off_t)request->body_size);
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
    // Bend 2.0.20 flattens HttpOk{Response{status, body}} into two fields.
    result = io_node(e, CID_HTTPOK, request->status, io_str(e, request->response, request->used));
  }
  free(request->method); free(request->url); free(request->body); free(request->response); free(request);
  work->data = NULL;
  return result;
}

static Term stiff_send_run(Env e, Term* f, IoWork* work) {
  Term fields[5];
  spare_free(e, cls_fit(5), ctr_take(e, f[0], 5, fields));
  StiffRequest* request = io_mem(calloc(1, sizeof(StiffRequest)));
  u64 method_size, url_size, body_size;
  request->method = io_cstr(e, fields[0], &method_size);
  request->url = io_cstr(e, fields[1], &url_size);
  request->body = io_cstr(e, fields[2], &body_size);
  request->body_size = body_size;
  request->timeout = (u32)fields[3];
  request->limit = (u32)fields[4];
  work->data = (char*)request;
  if (io_nul(request->method, method_size) || io_nul(request->url, url_size)
    || (strcmp(request->method, "GET") && strcmp(request->method, "POST"))
    || (!strcmp(request->method, "GET") && body_size != 0)
    || request->timeout < 1 || request->timeout > INT_MAX || request->limit < 1 || request->limit > INT_MAX) {
    request->error = "invalid_request";
    return stiff_send_pack(e, work);
  }
  return io_work(work, stiff_send_call, stiff_send_pack);
}

static void __attribute__((constructor)) stiff_send_register(void) {
  io_eff(CID_STIFF_SEND, stiff_send_run, 0);
}
