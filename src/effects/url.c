#include <curl/curl.h>

// Native effects share one generated translation unit and one libcurl lifetime.
#ifndef STIFF_CURL_INIT_DEFINED
#define STIFF_CURL_INIT_DEFINED
static pthread_once_t stiff_curl_once = PTHREAD_ONCE_INIT;
static CURLcode stiff_curl_ready;
static void stiff_curl_init(void) { stiff_curl_ready = curl_global_init(CURL_GLOBAL_DEFAULT); }
#endif

#define STIFF_URL_LIMIT 65536
typedef struct {
  char text[STIFF_URL_LIMIT + 1];
  size_t used;
  const char* error;
} StiffUrlOutput;

static void stiff_url_append(StiffUrlOutput* out, const char* text, size_t size) {
  if (out->error) return;
  if (size > STIFF_URL_LIMIT - out->used) { out->error = "url_too_large"; return; }
  memcpy(out->text + out->used, text, size);
  out->used += size;
  out->text[out->used] = 0;
}

static void stiff_url_text(Env e, Term text, StiffUrlOutput* out, int encode) {
  const char* hex = "0123456789ABCDEF";
  while (term_aux(text) != CID_SNIL && !out->error) {
    Term parts[2];
    spare_free(e, cls_fit(2), ctr_take(e, text, 2, parts));
    u64 scalar = parts[0];
    text = parts[1];
    if (scalar > 0x10ffff || (scalar >= 0xd800 && scalar <= 0xdfff)) {
      out->error = "invalid_url_text"; break;
    }
    if (!encode) {
      // Base URLs must already be ASCII URI text; components handle Unicode.
      if (scalar <= 32 || scalar >= 127 || scalar == '\\') {
        out->error = "invalid_url"; break;
      }
      char c = (char)scalar;
      stiff_url_append(out, &c, 1);
    } else {
      char bytes[4];
      size_t size = io_utf8(bytes, scalar);
      for (size_t i = 0; i < size; i++) {
        unsigned c = (unsigned char)bytes[i];
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
          || (c >= '0' && c <= '9') || c == '-' || c == '.' || c == '_' || c == '~') {
          stiff_url_append(out, bytes + i, 1);
        } else {
          char escape[3] = {'%', hex[c >> 4], hex[c & 15]};
          stiff_url_append(out, escape, 3);
        }
      }
    }
  }
  term_sink(e, text);
}

static Term stiff_url_result(Env e, StiffUrlOutput* out) {
  Term result = out->error
    ? io_box(e, CID_URLERROR, io_str(e, out->error, strlen(out->error)))
    : io_box(e, CID_URLREADY, io_str(e, out->text, out->used));
  free(out);
  return result;
}

#ifdef CID_URL_ENCODE_COMPONENT
static Term stiff_url_encode_run(Env e, Term* f, IoWork* w) {
  (void)w;
  StiffUrlOutput* out = io_mem(calloc(1, sizeof(*out)));
  stiff_url_text(e, f[0], out, 1);
  return stiff_url_result(e, out);
}
#endif

#ifdef CID_URL_WITH_QUERY
static int stiff_url_hex(unsigned c) {
  return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
}

static Term stiff_url_query_run(Env e, Term* f, IoWork* w) {
  (void)w;
  StiffUrlOutput* base = io_mem(calloc(1, sizeof(*base)));
  StiffUrlOutput* out = io_mem(calloc(1, sizeof(*out)));
  stiff_url_text(e, f[0], base, 0);
  out->error = base->error;
  CURLU* parsed = NULL;
  if (!out->error) {
    pthread_once(&stiff_curl_once, stiff_curl_init);
    if (stiff_curl_ready != CURLE_OK) out->error = "url_initialization";
  }
  if (!out->error) {
    for (size_t i = 0; i < base->used; i++) {
      if (base->text[i] == '%' && (base->used - i < 3
        || !stiff_url_hex((unsigned char)base->text[i + 1])
        || !stiff_url_hex((unsigned char)base->text[i + 2]))) {
        out->error = "invalid_url"; break;
      }
    }
  }
  if (!out->error) {
    parsed = curl_url();
    if (!parsed) out->error = "url_allocation";
    else if ((strncmp(base->text, "http://", 7) && strncmp(base->text, "https://", 8))
      || curl_url_set(parsed, CURLUPART_URL, base->text, CURLU_DISALLOW_USER | CURLU_PATH_AS_IS) != CURLUE_OK)
      out->error = "invalid_url";
  }
  if (parsed) curl_url_cleanup(parsed);
  size_t fragment = 0;
  while (fragment < base->used && base->text[fragment] != '#') fragment++;
  size_t query = 0;
  while (query < fragment && base->text[query] != '?') query++;
  stiff_url_append(out, base->text, fragment);
  Term items = f[1];
  size_t count = 0;
  while (term_aux(items) != CID_NIL && !out->error) {
    if (++count > 128) { out->error = "too_many_query_params"; break; }
    Term pair[2], param[2];
    spare_free(e, cls_fit(2), ctr_take(e, items, 2, pair));
    spare_free(e, cls_fit(2), ctr_take(e, pair[0], 2, param));
    items = pair[1];
    if (count > 1) stiff_url_append(out, "&", 1);
    else if (query == fragment) stiff_url_append(out, "?", 1);
    else if (query + 1 < fragment && base->text[fragment - 1] != '&')
      stiff_url_append(out, "&", 1);
    stiff_url_text(e, param[0], out, 1);
    stiff_url_append(out, "=", 1);
    stiff_url_text(e, param[1], out, 1);
  }
  term_sink(e, items);
  stiff_url_append(out, base->text + fragment, base->used - fragment);
  free(base);
  return stiff_url_result(e, out);
}
#endif

static void __attribute__((constructor)) stiff_url_register(void) {
#ifdef CID_URL_ENCODE_COMPONENT
  io_eff(CID_URL_ENCODE_COMPONENT, stiff_url_encode_run, 0);
#endif
#ifdef CID_URL_WITH_QUERY
  io_eff(CID_URL_WITH_QUERY, stiff_url_query_run, 0);
#endif
}
