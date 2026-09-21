#define STIFF_SERVER_EFFECT 1
#include <event2/event.h>
#include <event2/http.h>
#include <event2/buffer.h>
#include <event2/bufferevent.h>
#include <event2/listener.h>
#include <event2/keyvalq_struct.h>
#include <sys/queue.h>
#include <arpa/inet.h>
#include <signal.h>
#include <limits.h>
#include <stdatomic.h>
#include <stdio.h>

#define SG_HEADERS 128
#define SG_PENDING 128
#define SG_BODY_READ (64 * 1024)
#define SG_BODY_QUEUE (SG_BODY_READ + 4)
typedef struct { char *name, *value; } SgHeader;
typedef struct SgBody {
  char* data;
  size_t size;
  struct SgBody* next;
} SgBody;
typedef struct SgInput {
  u32 id;
  char *method, *path, *target, *body;
  size_t size, count;
  SgHeader headers[SG_HEADERS];
  struct SgInput* next;
} SgInput;
typedef struct SgReply {
  u32 id, status;
  unsigned operation, keep_alive, wait_write;
  char* body;
  size_t size, count;
  SgHeader headers[SG_HEADERS];
  const char* error;
  int done;
  struct SgReply* next;
} SgReply;
typedef struct SgConnection {
  struct bufferevent* bev;
  struct event* read_timer;
  u64 deadline;
  int expired;
  size_t forwarded;
  struct SgConnection* next;
} SgConnection;
typedef struct {
  u32 id;
  u64 deadline;
  int claimed, closed, body_complete, resume, cancel;
  const char* body_error;
  size_t body_queued, body_received, body_limit;
  SgBody *body, *body_tail;
} SgWork;
typedef struct {
  u32 id;
  struct evhttp_request* request;
  u64 deadline;
  int closed, replying, streaming, keep_alive, request_streaming, body_terminal;
  u32 status;
  size_t streamed;
  const char* body_error;
  SgReply* write_waiter;
  unsigned char utf8_tail[4];
  size_t utf8_tail_size;
} SgSlot;
static struct {
  pthread_mutex_t lock;
  pthread_cond_t ready;
  pthread_t thread;
  struct event_base* base;
  struct evhttp* http;
  struct evhttp_bound_socket* listener;
  struct event *wake, *tick, *sigint, *sigterm;
  int pipe[2], started, stopped, stopping, joined, cleaning, streaming_requests;
  u32 max_connections, read_timeout, connection_count;
  SgConnection* connections;
  u32 port, max_body, max_pending, timeout, grace, next_id;
  u64 stop_deadline;
  SgSlot slots[SG_PENDING];
  SgWork work[SG_PENDING]; // Protected by lock, including after network shutdown.
  SgInput *inputs, *inputs_tail;
  SgReply *replies, *replies_tail;
} sg = {.lock = PTHREAD_MUTEX_INITIALIZER, .ready = PTHREAD_COND_INITIALIZER, .pipe = {-1, -1}};

// Independent relaxed snapshots: counters saturate; bounded gauges do not wrap.
enum { SM_ADMITTED, SM_COMPLETED, SM_FAILED, SM_REJECTED, SM_EXPIRED,
       SM_READ_EXPIRED, SM_DISCONNECTED, SM_CONNECTIONS, SM_PENDING, SM_HANDLERS, SM_COUNT };
static _Atomic u32 sg_metrics[SM_COUNT];
// Cumulative counters have a single writer: the network event thread.
static void sg_count(unsigned field) {
  if (atomic_load_explicit(&sg_metrics[field], memory_order_relaxed) != UINT32_MAX)
    atomic_fetch_add_explicit(&sg_metrics[field], 1, memory_order_relaxed);
}
static void sg_gauge(unsigned field, int delta) {
  if (delta > 0) atomic_fetch_add_explicit(&sg_metrics[field], 1, memory_order_relaxed);
  else atomic_fetch_sub_explicit(&sg_metrics[field], 1, memory_order_relaxed);
}

static u64 sg_now(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (u64)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}
// All connection tracking runs on the libevent thread. A filter context gives
// a public-API lifetime callback, including connections that never reach HTTP
// dispatch. Returning NULL from evhttp's bevcb would silently use a default
// untracked socket, so allocation/setup failures fail closed instead.
static void sg_connection_free(void* context) {
  SgConnection* p = context;
  SgConnection** link = &sg.connections;
  while (*link && *link != p) link = &(*link)->next;
  if (*link) { *link = p->next; sg.connection_count--; sg_gauge(SM_CONNECTIONS, -1); }
  if (p->read_timer) event_free(p->read_timer);
  free(p);
  if (!sg.cleaning && !sg.stopping && sg.listener && sg.connection_count < sg.max_connections) {
    if (evconnlistener_enable(evhttp_bound_socket_get_listener(sg.listener)))
      err_fail("server listener enable failed");
  }
}
static void sg_read_expired(evutil_socket_t fd, short events, void* context) {
  (void)fd; (void)events;
  SgConnection* p = context;
  p->expired = 1;
  sg_count(SM_READ_EXPIRED);
  // Defer through evhttp's own error callback so it retains connection/request
  // ownership. The filter cancels this callback if freed in the meantime.
  bufferevent_trigger_event(p->bev, BEV_EVENT_TIMEOUT | BEV_EVENT_READING, BEV_TRIG_DEFER_CALLBACKS);
}
// Keep bytes in the HTTP-facing output until the socket has actually drained.
// A plain pass-through filter reports completion when bytes merely enter the
// underlying queue; evhttp would then close the socket before they are sent.
static enum bufferevent_filter_result sg_output(struct evbuffer* source,
    struct evbuffer* destination, ev_ssize_t limit,
    enum bufferevent_flush_mode mode, void* context) {
  (void)limit; (void)mode;
  SgConnection* p = context;
  int drained = 0;
  if (p->forwarded) {
    if (evbuffer_get_length(destination)) return BEV_NEED_MORE;
    evbuffer_drain(source, p->forwarded);
    p->forwarded = 0;
    drained = 1;
  }
  // A stream chunk or its terminator can be appended while the preceding
  // bytes are in the underlying queue. Forward that remainder before allowing
  // evhttp to observe completion.
  size_t size = evbuffer_get_length(source);
  if (!size) return drained ? BEV_OK : BEV_NEED_MORE;
  const unsigned char* data = evbuffer_pullup(source, -1);
  if (!data || evbuffer_add(destination, data, size)) return BEV_ERROR;
  p->forwarded = size;
  return BEV_NEED_MORE;
}
static void sg_output_added(struct evbuffer* buffer, const struct evbuffer_cb_info* info, void* context) {
  (void)buffer;
  if (!info->n_added) return;
  SgConnection* p = context;
  // evhttp adds output while writing is disabled. Filters do not flush that
  // queue on enable, unlike socket bufferevents. Start the filter explicitly;
  // its completion callback is deferred until evhttp finishes setting it up.
  bufferevent_enable(p->bev, EV_WRITE);
  bufferevent_flush(p->bev, EV_WRITE, BEV_NORMAL);
}
static struct bufferevent* sg_connection_new(struct event_base* base, void* unused) {
  (void)unused;
  if (sg.connection_count >= sg.max_connections) err_fail("server connection admission invariant");
  SgConnection* p = io_mem(calloc(1, sizeof(*p)));
  struct bufferevent* socket = bufferevent_socket_new(base, -1, BEV_OPT_CLOSE_ON_FREE);
  if (!socket) err_fail("server connection allocation failed");
  p->bev = bufferevent_filter_new(socket, NULL, sg_output, BEV_OPT_CLOSE_ON_FREE | BEV_OPT_DEFER_CALLBACKS, sg_connection_free, p);
  if (!p->bev) err_fail("server connection filter allocation failed");
  if (sg.streaming_requests)
    bufferevent_setwatermark(p->bev, EV_READ, 0, SG_BODY_READ);
  if (!evbuffer_add_cb(bufferevent_get_output(p->bev), sg_output_added, p))
    err_fail("server write callback setup failed");
  p->deadline = sg_now() + sg.read_timeout;
  p->read_timer = evtimer_new(base, sg_read_expired, p);
  struct timeval timeout = {sg.read_timeout / 1000, (sg.read_timeout % 1000) * 1000};
  if (!p->read_timer || event_add(p->read_timer, &timeout)) err_fail("server read deadline setup failed");
  p->next = sg.connections; sg.connections = p; sg.connection_count++;
  sg_gauge(SM_CONNECTIONS, 1);
  if (sg.connection_count == sg.max_connections &&
      evconnlistener_disable(evhttp_bound_socket_get_listener(sg.listener)))
    err_fail("server listener disable failed");
  return p->bev;
}
static int sg_request_read_complete(struct evhttp_request* request) {
  struct bufferevent* bev = evhttp_connection_get_bufferevent(evhttp_request_get_connection(request));
  for (SgConnection* p = sg.connections; p; p = p->next) {
    if (p->bev == bev) {
      event_del(p->read_timer);
      return !p->expired && sg_now() < p->deadline;
    }
  }
  return 0;
}
static void sg_request_read_again(struct evhttp_request* request) {
  struct evhttp_connection* connection = evhttp_request_get_connection(request);
  if (!connection) return;
  struct bufferevent* bev = evhttp_connection_get_bufferevent(connection);
  for (SgConnection* p = sg.connections; p; p = p->next) {
    if (p->bev == bev) {
      p->expired = 0;
      p->deadline = sg_now() + sg.read_timeout;
      struct timeval timeout = {sg.read_timeout / 1000, (sg.read_timeout % 1000) * 1000};
      if (event_add(p->read_timer, &timeout)) err_fail("server read deadline setup failed");
      return;
    }
  }
}
static char* sg_copy(const void* p, size_t n) {
  char* s = io_mem(malloc(n + 1));
  if (n) memcpy(s, p, n);
  s[n] = 0;
  return s;
}
static void sg_input_free(SgInput* p) {
  free(p->method); free(p->path); free(p->target); free(p->body);
  for (size_t i = 0; i < p->count; i++) { free(p->headers[i].name); free(p->headers[i].value); }
  free(p);
}
static void sg_body_free(SgBody* p) {
  while (p) {
    SgBody* next = p->next;
    free(p->data); free(p); p = next;
  }
}
static void sg_work_clear(SgWork* work) {
  sg_body_free(work->body);
  memset(work, 0, sizeof(*work));
  sg_gauge(SM_HANDLERS, -1);
}
static int sg_token(const char* s, size_t n) {
  if (!n || n > 8192) return 0;
  for (size_t i = 0; i < n; i++) {
    unsigned c = (unsigned char)s[i];
    if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
      || (c && strchr("!#$%&'*+-.^_`|~", c)))) return 0;
  }
  return 1;
}
static void sg_lower(char* s) {
  for (; *s; s++) if (*s >= 'A' && *s <= 'Z') *s += 'a' - 'A';
}
static int sg_value(const char* s, size_t n) {
  if (n > 8192) return 0;
  for (size_t i = 0; i < n; i++) {
    unsigned c = (unsigned char)s[i];
    if ((c < 32 && c != '\t') || c == 127) return 0;
  }
  return 1;
}
static int sg_utf8(const unsigned char* p, size_t n) {
  size_t i = 0;
  while (i < n) {
    unsigned c = p[i++], count, lo = 0x80, hi = 0xbf;
    if (c < 0x80) continue;
    if (c >= 0xc2 && c <= 0xdf) count = 1;
    else if (c >= 0xe0 && c <= 0xef) { count = 2; if (c == 0xe0) lo = 0xa0; if (c == 0xed) hi = 0x9f; }
    else if (c >= 0xf0 && c <= 0xf4) { count = 3; if (c == 0xf0) lo = 0x90; if (c == 0xf4) hi = 0x8f; }
    else return 0;
    if (n - i < count || p[i] < lo || p[i] > hi) return 0;
    i++;
    while (--count) if (p[i] < 0x80 || p[i++] > 0xbf) return 0;
  }
  return 1;
}
static void sg_notify(void) {
  char c = 1;
  // A full pipe is already readable; the event loop always drains the queue.
  if (sg.pipe[1] >= 0) {
    ssize_t result;
    do { result = write(sg.pipe[1], &c, 1); } while (result < 0 && errno == EINTR);
    // The periodic tick also drains replies, covering an unexpected wake error.
  }
}
// Caller holds sg.lock. IDs are never reused during the listener lifetime.
static SgWork* sg_work(u32 id) {
  if (!id) return NULL;
  for (u32 i = 0; i < sg.max_pending; i++)
    if (sg.work[i].id == id) return &sg.work[i];
  return NULL;
}
static void sg_forget(SgSlot* slot) {
  pthread_mutex_lock(&sg.lock);
  if (slot->write_waiter) {
    slot->write_waiter->error = "request_closed";
    slot->write_waiter->done = 1;
    slot->write_waiter = NULL;
  }
  SgWork* work = sg_work(slot->id);
  if (work) {
    if (work->claimed) work->closed = 1;
    else sg_work_clear(work);
  }
  SgInput** link = &sg.inputs;
  while (*link) {
    if ((*link)->id == slot->id) {
      SgInput* old = *link;
      *link = old->next;
      sg_input_free(old);
      break;
    }
    link = &(*link)->next;
  }
  sg.inputs_tail = sg.inputs;
  while (sg.inputs_tail && sg.inputs_tail->next) sg.inputs_tail = sg.inputs_tail->next;
  pthread_cond_broadcast(&sg.ready);
  pthread_mutex_unlock(&sg.lock);
  sg_gauge(SM_PENDING, -1);
  memset(slot, 0, sizeof(*slot));
}
static void sg_closed(struct evhttp_connection* connection, void* arg) {
  (void)connection;
  SgSlot* slot = arg;
  slot->closed = 1;
  pthread_mutex_lock(&sg.lock);
  if (slot->write_waiter) {
    slot->write_waiter->error = "request_closed";
    slot->write_waiter->done = 1;
    slot->write_waiter = NULL;
  }
  SgWork* work = sg_work(slot->id);
  if (work) work->closed = 1;
  pthread_cond_broadcast(&sg.ready);
  pthread_mutex_unlock(&sg.lock);
}
static void sg_complete(struct evhttp_request* request, void* arg) {
  SgSlot* slot = arg;
  struct evhttp_connection* connection = evhttp_request_get_connection(request);
  if (connection) evhttp_connection_set_closecb(connection, NULL, NULL);
  sg_count(SM_COMPLETED);
  if (slot->status >= 400) sg_count(SM_FAILED);
  // Explicit keep-alive starts a fresh absolute read window only after the
  // existing output filter confirms the preceding response reached the socket.
  if (slot->keep_alive && !sg.stopping) sg_request_read_again(request);
  // libevent frees the request after this callback, including owned requests.
  sg_forget(slot);
}
static const char* sg_method(enum evhttp_cmd_type m) {
  switch (m) {
    case EVHTTP_REQ_GET: return "GET"; case EVHTTP_REQ_POST: return "POST";
    case EVHTTP_REQ_PUT: return "PUT"; case EVHTTP_REQ_DELETE: return "DELETE";
    case EVHTTP_REQ_PATCH: return "PATCH"; case EVHTTP_REQ_HEAD: return "HEAD";
    case EVHTTP_REQ_OPTIONS: return "OPTIONS"; default: return "";
  }
}
static void sg_error(struct evhttp_request* req, int code) {
  sg_count(SM_REJECTED);
  const char *error = "internal_error", *message = "HTTP transport failed";
  switch (code) {
    case 400: error = "bad_request"; message = "Request rejected by HTTP transport"; break;
    case 408: error = "request_timeout"; message = "Request read deadline exceeded"; break;
    case 413: error = "payload_too_large"; message = "Request body exceeds configured limit"; break;
    case 503: error = "service_unavailable"; message = "Server cannot accept this request"; break;
  }
  char json[224];
  int length = snprintf(json, sizeof json,
    "{\"error\":{\"code\":\"%s\",\"message\":\"%s\"}}", error, message);
  int head = evhttp_request_get_command(req) == EVHTTP_REQ_HEAD;
  struct evbuffer* body = evbuffer_new();
  if (!body || length < 0 || (size_t)length >= sizeof json
      || (!head && evbuffer_add(body, json, (size_t)length))) {
    if (body) evbuffer_free(body);
    evhttp_send_error(req, code, NULL);
    return;
  }
  struct evkeyvalq* headers = evhttp_request_get_output_headers(req);
  evhttp_add_header(headers, "Content-Type", "application/json");
  evhttp_add_header(headers, "Connection", "close");
  if (head) {
    char content_length[32];
    int n = snprintf(content_length, sizeof content_length, "%d", length);
    if (n > 0 && (size_t)n < sizeof content_length)
      evhttp_add_header(headers, "Content-Length", content_length);
  }
  evhttp_send_reply(req, code, NULL, body);
  evbuffer_free(body);
}
static int sg_error_page(struct evhttp_request* req, struct evbuffer* buffer,
    int code, const char* reason, void* unused) {
  (void)reason; (void)unused;
  const char *error = "internal_error", *message = "HTTP transport failed";
  switch (code) {
    case 400: error = "bad_request"; message = "Request rejected by HTTP transport"; break;
    case 408: error = "request_timeout"; message = "Request read deadline exceeded"; break;
    case 413: error = "payload_too_large"; message = "Request body exceeds configured limit"; break;
    case 503: error = "service_unavailable"; message = "Server cannot accept this request"; break;
  }
  char json[224];
  int length = snprintf(json, sizeof json,
    "{\"error\":{\"code\":\"%s\",\"message\":\"%s\"}}", error, message);
  if (length < 0 || (size_t)length >= sizeof json) return -1;
  sg_count(SM_REJECTED);
  evhttp_add_header(evhttp_request_get_output_headers(req), "Content-Type", "application/json");
  evhttp_add_header(evhttp_request_get_output_headers(req), "Connection", "close");
  if (evhttp_request_get_command(req) == EVHTTP_REQ_HEAD) {
    char content_length[32];
    int n = snprintf(content_length, sizeof content_length, "%d", length);
    if (n > 0 && (size_t)n < sizeof content_length)
      evhttp_add_header(evhttp_request_get_output_headers(req), "Content-Length", content_length);
  } else if (evbuffer_add(buffer, json, (size_t)length)) return -1;
  for (u32 i = 0; i < sg.max_pending; i++) {
    SgSlot* slot = &sg.slots[i];
    if (slot->request != req || !slot->request_streaming) continue;
    slot->body_terminal = 1; slot->replying = 1; slot->status = (u32)code;
    pthread_mutex_lock(&sg.lock);
    SgWork* work = sg_work(slot->id);
    if (work) {
      work->body_error = error;
      work->body_complete = 1;
      pthread_cond_broadcast(&sg.ready);
    }
    pthread_mutex_unlock(&sg.lock);
    break;
  }
  return 0;
}
static SgInput* sg_request_input(struct evhttp_request* req,
    const unsigned char* bytes, size_t size) {
  const char* target = evhttp_request_get_uri(req);
  const struct evhttp_uri* uri = evhttp_request_get_evhttp_uri(req);
  const char* path = uri ? evhttp_uri_get_path(uri) : NULL;
  if (!target || target[0] != '/' || strchr(target, '#') || !path
      || !sg_utf8((const unsigned char*)target, strlen(target))
      || (size && (!bytes || !sg_utf8(bytes, size)))) return NULL;
  SgInput* p = io_mem(calloc(1, sizeof(*p)));
  p->method = sg_copy(sg_method(evhttp_request_get_command(req)), strlen(sg_method(evhttp_request_get_command(req))));
  p->path = sg_copy(path, strlen(path)); p->target = sg_copy(target, strlen(target));
  p->body = sg_copy(bytes, size); p->size = size;
  struct evkeyval* header;
  unsigned content_lengths = 0, transfers = 0, hosts = 0;
  TAILQ_FOREACH(header, evhttp_request_get_input_headers(req), next) {
    if (p->count == SG_HEADERS || !sg_token(header->key, strlen(header->key))
      || !sg_value(header->value, strlen(header->value))
      || !sg_utf8((const unsigned char*)header->value, strlen(header->value))) {
      sg_input_free(p); return NULL;
    }
    SgHeader* h = &p->headers[p->count++];
    h->name = sg_copy(header->key, strlen(header->key)); sg_lower(h->name);
    h->value = sg_copy(header->value, strlen(header->value));
    content_lengths += !strcmp(h->name, "content-length");
    transfers += !strcmp(h->name, "transfer-encoding");
    hosts += !strcmp(h->name, "host");
  }
  if (content_lengths > 1 || transfers > 1 || hosts > 1 || (content_lengths && transfers)) {
    sg_input_free(p); return NULL;
  }
  return p;
}
static SgSlot* sg_admit(struct evhttp_request* req, SgInput* p, int streaming,
    size_t body_limit) {
  SgSlot* slot = NULL;
  for (u32 i = 0; i < sg.max_pending; i++)
    if (!sg.slots[i].request) { slot = &sg.slots[i]; break; }
  if (!slot || sg.next_id == UINT32_MAX) return NULL;
  pthread_mutex_lock(&sg.lock);
  SgWork* work = NULL;
  for (u32 i = 0; i < sg.max_pending; i++)
    if (!sg.work[i].id) { work = &sg.work[i]; break; }
  if (!work) {
    pthread_mutex_unlock(&sg.lock);
    return NULL;
  }
  p->id = ++sg.next_id;
  *work = (SgWork){.id = p->id, .deadline = sg_now() + sg.timeout,
    .body_complete = !streaming, .body_limit = body_limit};
  sg_gauge(SM_HANDLERS, 1);
  pthread_mutex_unlock(&sg.lock);
  slot->id = p->id; slot->request = req; slot->deadline = sg_now() + sg.timeout;
  slot->request_streaming = streaming;
  sg_count(SM_ADMITTED); sg_gauge(SM_PENDING, 1);
  evhttp_request_own(req);
  evhttp_request_set_on_complete_cb(req, sg_complete, slot);
  evhttp_connection_set_closecb(evhttp_request_get_connection(req), sg_closed, slot);
  pthread_mutex_lock(&sg.lock);
  if (sg.inputs_tail) sg.inputs_tail->next = p; else sg.inputs = p;
  sg.inputs_tail = p;
  pthread_cond_broadcast(&sg.ready);
  pthread_mutex_unlock(&sg.lock);
  return slot;
}
static size_t sg_utf8_prefix(const unsigned char* p, size_t n, int* invalid) {
  size_t i = 0;
  *invalid = 0;
  while (i < n) {
    size_t start = i;
    unsigned c = p[i++], count, lo = 0x80, hi = 0xbf;
    if (c < 0x80) continue;
    if (c >= 0xc2 && c <= 0xdf) count = 1;
    else if (c >= 0xe0 && c <= 0xef) { count = 2; if (c == 0xe0) lo = 0xa0; if (c == 0xed) hi = 0x9f; }
    else if (c >= 0xf0 && c <= 0xf4) { count = 3; if (c == 0xf0) lo = 0x90; if (c == 0xf4) hi = 0x8f; }
    else { *invalid = 1; return start; }
    if (n - i < count) return start;
    if (p[i] < lo || p[i] > hi) { *invalid = 1; return start; }
    i++;
    while (--count) if (p[i] < 0x80 || p[i++] > 0xbf) { *invalid = 1; return start; }
  }
  return n;
}
static SgSlot* sg_request_slot(struct evhttp_request* req) {
  for (u32 i = 0; i < sg.max_pending; i++)
    if (sg.slots[i].request == req) return &sg.slots[i];
  return NULL;
}
static void sg_body_chunk(struct evhttp_request* req, void* unused) {
  (void)unused;
  SgSlot* slot = sg_request_slot(req);
  if (!slot || !slot->request_streaming || slot->body_terminal) return;
  struct evbuffer* input = evhttp_request_get_input_buffer(req);
  size_t size = evbuffer_get_length(input);
  const unsigned char* bytes = evbuffer_pullup(input, -1);
  if (!size) return;
  if (slot->body_error) {
    if (size > sg.max_body - slot->streamed) slot->body_error = "payload_too_large";
    else slot->streamed += size;
    return;
  }
  if (!bytes) { slot->body_error = "internal_error"; sg_count(SM_REJECTED); return; }
  if (size > sg.max_body - slot->streamed) {
    slot->body_error = "payload_too_large";
    sg_count(SM_REJECTED);
    return;
  }
  size_t total = slot->utf8_tail_size + size;
  unsigned char* combined = io_mem(malloc(total));
  memcpy(combined, slot->utf8_tail, slot->utf8_tail_size);
  memcpy(combined + slot->utf8_tail_size, bytes, size);
  int invalid;
  size_t prefix = sg_utf8_prefix(combined, total, &invalid);
  slot->streamed += size;
  size_t residual = total - prefix;
  if (!invalid) {
    if (residual > 3) err_fail("server UTF-8 streaming invariant");
    slot->utf8_tail_size = residual;
    if (residual) memcpy(slot->utf8_tail, combined + prefix, residual);
  }
  SgBody* body = NULL;
  if (prefix) {
    body = io_mem(calloc(1, sizeof(*body)));
    body->data = sg_copy(combined, prefix); body->size = prefix;
  }
  free(combined);
  pthread_mutex_lock(&sg.lock);
  SgWork* work = sg_work(slot->id);
  if (!work || prefix > work->body_limit || work->body_queued > work->body_limit - prefix) {
    if (body) { free(body->data); free(body); }
    slot->body_error = "body_backpressure";
    sg_count(SM_REJECTED);
  } else if (invalid) {
    if (body) { free(body->data); free(body); }
    slot->body_error = "bad_request";
    sg_count(SM_REJECTED);
  } else {
    work->body_received += size;
    if (body) {
      if (work->body_tail) work->body_tail->next = body; else work->body = body;
      work->body_tail = body; work->body_queued += prefix;
      pthread_cond_broadcast(&sg.ready);
    }
  }
  pthread_mutex_unlock(&sg.lock);
  if (body && !slot->body_error)
    bufferevent_disable(evhttp_connection_get_bufferevent(evhttp_request_get_connection(req)), EV_READ);
}
static int sg_stream_headers(struct evhttp_request* req, void* unused) {
  (void)unused;
  if (sg.stopping) return -1;
  SgInput* p = sg_request_input(req, NULL, 0);
  if (!p) return -1;
  int chunked = 0;
  for (size_t i = 0; i < p->count; i++)
    if (!strcmp(p->headers[i].name, "transfer-encoding")) chunked = 1;
  if (chunked) {
    struct evhttp_connection* connection = evhttp_request_get_connection(req);
    bufferevent_setwatermark(evhttp_connection_get_bufferevent(connection), EV_READ,
      0, sg.max_body + 8192);
  }
  SgSlot* slot = sg_admit(req, p, 1, chunked ? sg.max_body + 4 : SG_BODY_QUEUE);
  if (!slot) { sg_input_free(p); return -1; }
  return 0;
}
static int sg_new_request(struct evhttp_request* req, void* unused) {
  (void)unused;
  bufferevent_setwatermark(evhttp_connection_get_bufferevent(
    evhttp_request_get_connection(req)), EV_READ, 0, SG_BODY_READ);
  evhttp_request_set_header_cb(req, sg_stream_headers);
  evhttp_request_set_chunked_cb(req, sg_body_chunk);
  return 0;
}
static void sg_incoming(struct evhttp_request* req, void* unused) {
  (void)unused;
  if (sg.streaming_requests) {
    SgSlot* slot = sg_request_slot(req);
    if (!slot) { sg_error(req, 400); return; }
    int complete = sg_request_read_complete(req);
    if (!complete || (!slot->body_error && slot->utf8_tail_size)) sg_count(SM_REJECTED);
    pthread_mutex_lock(&sg.lock);
    SgWork* work = sg_work(slot->id);
    if (work) {
      if (!complete) work->body_error = "request_timeout";
      else if (slot->body_error) work->body_error = slot->body_error;
      else if (slot->utf8_tail_size) work->body_error = "bad_request";
      work->body_complete = 1;
      pthread_cond_broadcast(&sg.ready);
    }
    pthread_mutex_unlock(&sg.lock);
    slot->body_terminal = 1;
    return;
  }
  if (sg.stopping) { sg_error(req, 503); return; }
  if (!sg_request_read_complete(req)) { sg_error(req, 408); return; }
  struct evbuffer* buffer = evhttp_request_get_input_buffer(req);
  size_t size = evbuffer_get_length(buffer);
  const unsigned char* bytes = evbuffer_pullup(buffer, -1);
  if (size > sg.max_body) { sg_error(req, 413); return; }
  SgInput* p = sg_request_input(req, bytes, size);
  if (!p) { sg_error(req, size && !bytes ? 500 : 400); return; }
  if (!sg_admit(req, p, 0, 0)) { sg_input_free(p); sg_error(req, 503); }
}
static void sg_stop_begin(void) {
  if (sg.stopping) return;
  sg.stopping = 1; sg.stop_deadline = sg_now() + sg.grace;
  if (sg.listener) { evhttp_del_accept_socket(sg.http, sg.listener); sg.listener = NULL; }
}
static void sg_signal(evutil_socket_t fd, short events, void* arg) {
  (void)fd; (void)events; (void)arg;
  sg_stop_begin();
}
enum { SG_REPLY, SG_STREAM_START, SG_STREAM_WRITE, SG_STREAM_END };
static SgSlot* sg_reply_slot(SgReply* p) {
  SgSlot* slot = NULL;
  for (u32 i = 0; i < sg.max_pending; i++)
    if (sg.slots[i].id == p->id && sg.slots[i].request) { slot = &sg.slots[i]; break; }
  if (!slot || slot->closed) { p->error = "request_closed"; return NULL; }
  return slot;
}
static int sg_add_reply_headers(SgReply* p, SgSlot* slot) {
  struct evkeyvalq* headers = evhttp_request_get_output_headers(slot->request);
  for (size_t i = 0; i < p->count; i++) {
    if (evhttp_find_header(headers, p->headers[i].name)) continue;
    if (evhttp_add_header(headers, p->headers[i].name, p->headers[i].value)) {
      p->error = "invalid_response";
      return 0;
    }
  }
  return 1;
}
static void sg_chunk_written(struct evhttp_connection* connection, void* arg) {
  SgSlot* slot = arg;
  struct bufferevent* bev = evhttp_connection_get_bufferevent(connection);
  // libevent retains and can invoke a chunk callback more than once. The slot
  // is stable storage, unlike the effect-owned reply. Our output filter keeps
  // bytes in this HTTP-facing buffer until the socket-facing buffer drains.
  // Do not let a deferred callback for an earlier chunk complete a newer one.
  if (!bev || evbuffer_get_length(bufferevent_get_output(bev))) return;
  pthread_mutex_lock(&sg.lock);
  SgReply* p = NULL;
  if (slot->request && evhttp_request_get_connection(slot->request) == connection) {
    p = slot->write_waiter;
    slot->write_waiter = NULL;
  }
  if (p) {
    p->done = 1;
    pthread_cond_broadcast(&sg.ready);
  }
  pthread_mutex_unlock(&sg.lock);
}
static void sg_handle_reply(SgReply* p) {
  SgSlot* slot = sg_reply_slot(p);
  if (!slot) return;
  if (slot->request_streaming && !slot->body_terminal) {
    p->error = "request_body_incomplete";
    return;
  }
  if ((p->operation == SG_STREAM_WRITE || p->operation == SG_STREAM_END)
      && slot->write_waiter) {
    p->error = "response_write_pending";
    return;
  }
  if (p->operation == SG_STREAM_WRITE) {
    if (!slot->streaming) { p->error = "stream_not_open"; return; }
    if (p->size > 16 * 1024 * 1024 - slot->streamed) { p->error = "response_too_large"; return; }
    struct evbuffer* chunk = evbuffer_new();
    if (!chunk || evbuffer_add(chunk, p->body, p->size)) {
      if (chunk) evbuffer_free(chunk);
      p->error = "server_memory";
      return;
    }
    if (p->size) {
      p->wait_write = 1;
      slot->write_waiter = p;
      evhttp_send_reply_chunk_with_cb(slot->request, chunk, sg_chunk_written, slot);
    }
    evbuffer_free(chunk);
    slot->streamed += p->size;
    return;
  }
  if (p->operation == SG_STREAM_END) {
    if (!slot->streaming) { p->error = "stream_not_open"; return; }
    slot->streaming = 0;
    evhttp_send_reply_end(slot->request);
    return;
  }
  if (slot->replying) { p->error = "response_started"; return; }
  if (p->operation == SG_STREAM_START &&
      evhttp_request_get_command(slot->request) == EVHTTP_REQ_HEAD) {
    p->error = "invalid_response";
    return;
  }
  if (!sg_add_reply_headers(p, slot)) return;
  if (p->operation == SG_STREAM_START) {
    if (p->keep_alive) evhttp_add_header(evhttp_request_get_output_headers(slot->request), "Connection", "keep-alive");
    else evhttp_add_header(evhttp_request_get_output_headers(slot->request), "Connection", "close");
    slot->replying = 1; slot->streaming = 1; slot->keep_alive = p->keep_alive;
    slot->status = p->status; slot->streamed = 0;
    evhttp_send_reply_start(slot->request, (int)p->status, NULL);
    return;
  }
  evhttp_add_header(evhttp_request_get_output_headers(slot->request), "Connection", "close");
  struct evbuffer* body = evbuffer_new();
  if (!body || evbuffer_add(body, p->body, p->size)) {
    if (body) evbuffer_free(body);
    p->error = "server_memory"; return;
  }
  slot->replying = 1; slot->status = p->status;
  evhttp_send_reply(slot->request, (int)p->status, NULL, body);
  evbuffer_free(body);
}
static void sg_wake(evutil_socket_t fd, short events, void* arg) {
  (void)events; (void)arg;
  char buffer[256];
  while (read(fd, buffer, sizeof buffer) > 0) {}
  for (;;) {
    pthread_mutex_lock(&sg.lock);
    SgReply* p = sg.replies;
    if (p) { sg.replies = p->next; if (!sg.replies) sg.replies_tail = NULL; }
    pthread_mutex_unlock(&sg.lock);
    if (!p) break;
    if (!p->id) sg_stop_begin(); else sg_handle_reply(p);
    pthread_mutex_lock(&sg.lock);
    if (!p->wait_write) p->done = 1;
    pthread_cond_broadcast(&sg.ready);
    pthread_mutex_unlock(&sg.lock);
  }
  for (u32 i = 0; i < sg.max_pending; i++) {
    SgSlot* slot = &sg.slots[i];
    if (!slot->request || !slot->request_streaming || slot->body_terminal) continue;
    int resume = 0;
    pthread_mutex_lock(&sg.lock);
    SgWork* work = sg_work(slot->id);
    if (work && work->resume) { work->resume = 0; resume = 1; }
    pthread_mutex_unlock(&sg.lock);
    if (resume) {
      struct evhttp_connection* connection = evhttp_request_get_connection(slot->request);
      if (connection) bufferevent_enable(evhttp_connection_get_bufferevent(connection), EV_READ);
    }
  }
  for (u32 i = 0; i < sg.max_pending; i++) {
    SgSlot* slot = &sg.slots[i];
    if (!slot->request) continue;
    int cancel = 0;
    pthread_mutex_lock(&sg.lock);
    SgWork* work = sg_work(slot->id);
    if (work && work->cancel) { work->cancel = 0; cancel = 1; }
    pthread_mutex_unlock(&sg.lock);
    if (cancel) {
      struct evhttp_connection* connection = evhttp_request_get_connection(slot->request);
      if (connection) {
        evhttp_connection_set_closecb(connection, NULL, NULL);
        evhttp_connection_free(connection);
      }
      evhttp_request_free(slot->request);
      sg_forget(slot);
    }
  }
}
static void sg_tick(evutil_socket_t fd, short events, void* arg) {
  (void)fd; (void)events; (void)arg;
  sg_wake(sg.pipe[0], 0, NULL);
  u64 now = sg_now();
  unsigned active = 0;
  for (u32 i = 0; i < sg.max_pending; i++) {
    SgSlot* slot = &sg.slots[i];
    if (!slot->request) continue;
    if (slot->closed || now >= slot->deadline || (sg.stopping && now >= sg.stop_deadline)) {
      sg_count(slot->closed ? SM_DISCONNECTED : SM_EXPIRED);
      if (!slot->closed) {
        struct evhttp_connection* connection = evhttp_request_get_connection(slot->request);
        if (connection) { evhttp_connection_set_closecb(connection, NULL, NULL); evhttp_connection_free(connection); }
      }
      // Owned requests survive connection teardown. Free only after its callback returns.
      evhttp_request_free(slot->request);
      sg_forget(slot);
    } else active++;
  }
  if (sg.stopping && active == 0) event_base_loopexit(sg.base, NULL);
}
static void sg_cleanup(void) {
  sg.cleaning = 1;
  if (sg.wake) event_free(sg.wake);
  if (sg.tick) event_free(sg.tick);
  if (sg.sigint) event_free(sg.sigint);
  if (sg.sigterm) event_free(sg.sigterm);
  if (sg.http) evhttp_free(sg.http);
  if (sg.base) event_base_free(sg.base);
  if (sg.pipe[0] >= 0) close(sg.pipe[0]);
  if (sg.pipe[1] >= 0) close(sg.pipe[1]);
  sg.wake = sg.tick = sg.sigint = sg.sigterm = NULL;
  sg.http = NULL; sg.base = NULL; sg.listener = NULL;
  sg.pipe[0] = sg.pipe[1] = -1;
  sg.cleaning = 0;
}
static void* sg_thread(void* unused) {
  (void)unused;
  event_base_dispatch(sg.base);
  pthread_mutex_lock(&sg.lock);
  sg.stopped = 1;
  // Complete queued effects before waking their Bend continuations.
  for (SgReply* p = sg.replies; p; p = p->next) { p->error = "server_stopped"; p->done = 1; }
  sg.replies = sg.replies_tail = NULL;
  sg_cleanup();
  pthread_cond_broadcast(&sg.ready);
  pthread_mutex_unlock(&sg.lock);
  return NULL;
}
#if defined(CID_SERVER_LISTEN) || defined(CID_SERVER_LISTEN_WITH_LIMITS) || defined(CID_SERVER_LISTEN_STREAMING) || defined(CID_SERVER_LISTEN_STREAMING_WITH_LIMITS)
static Term sg_listen(Env e, Term config, u32 connections, u32 read_timeout, int streaming) {
  Term fields[6];
  spare_free(e, cls_fit(6), ctr_take(e, config, 6, fields));
  u64 length;
  char* address = io_cstr(e, fields[0], &length);
  u32 port = fields[1], body = fields[2], pending = fields[3], timeout = fields[4], grace = fields[5];
  unsigned char binary[16];
  const char* error = NULL;
  if (streaming && connections == UINT32_MAX) connections = pending;
  if (!read_timeout) read_timeout = timeout;
  if (sg.started) error = "already_started";
  else if (io_nul(address, length) || (inet_pton(AF_INET, address, binary) != 1 && inet_pton(AF_INET6, address, binary) != 1)
    || port > 65535 || !body || body > 16 * 1024 * 1024 || !pending || pending > SG_PENDING
    || !timeout || timeout > 600000 || !grace || grace > 600000
    || !connections || connections > 1024 || (streaming && connections > pending)
    || !read_timeout || read_timeout > 600000) error = "invalid_config";
  if (!error) {
    sg.max_connections = connections; sg.read_timeout = read_timeout;
    sg.max_body = body; sg.max_pending = pending; sg.timeout = timeout; sg.grace = grace;
    sg.streaming_requests = streaming;
    sg.base = event_base_new();
    if (sg.base) sg.http = evhttp_new(sg.base);
    if (!sg.http || pipe(sg.pipe)) error = "listen_failed";
    if (!error) {
      if (evutil_make_socket_nonblocking(sg.pipe[0]) || evutil_make_socket_nonblocking(sg.pipe[1])
        || evutil_make_socket_closeonexec(sg.pipe[0]) || evutil_make_socket_closeonexec(sg.pipe[1])) {
        error = "listen_failed";
      }
    }
    if (!error) {
      evhttp_set_max_body_size(sg.http, body); evhttp_set_max_headers_size(sg.http, 16384);
      struct timeval t = {timeout / 1000, (timeout % 1000) * 1000};
      evhttp_set_timeout_tv(sg.http, &t);
      evhttp_set_allowed_methods(sg.http, EVHTTP_REQ_GET | EVHTTP_REQ_POST | EVHTTP_REQ_PUT | EVHTTP_REQ_DELETE | EVHTTP_REQ_PATCH | EVHTTP_REQ_HEAD | EVHTTP_REQ_OPTIONS);
      evhttp_set_errorcb(sg.http, sg_error_page, NULL);
      if (streaming) evhttp_set_newreqcb(sg.http, sg_new_request, NULL);
      evhttp_set_gencb(sg.http, sg_incoming, NULL);
      evhttp_set_bevcb(sg.http, sg_connection_new, NULL);
      sg.listener = evhttp_bind_socket_with_handle(sg.http, address, (ev_uint16_t)port);
      sg.wake = event_new(sg.base, sg.pipe[0], EV_READ | EV_PERSIST, sg_wake, NULL);
      sg.tick = event_new(sg.base, -1, EV_PERSIST, sg_tick, NULL);
      sg.sigint = evsignal_new(sg.base, SIGINT, sg_signal, NULL);
      sg.sigterm = evsignal_new(sg.base, SIGTERM, sg_signal, NULL);
      struct timeval tick = {0, 10000};
      if (!sg.listener || !sg.wake || !sg.tick || !sg.sigint || !sg.sigterm
        || event_add(sg.wake, NULL) || event_add(sg.tick, &tick) || event_add(sg.sigint, NULL) || event_add(sg.sigterm, NULL)) error = "listen_failed";
      if (!error) {
        struct sockaddr_storage local;
        socklen_t size = sizeof local;
        if (getsockname(evhttp_bound_socket_get_fd(sg.listener), (struct sockaddr*)&local, &size)) error = "listen_failed";
        else sg.port = ntohs(local.ss_family == AF_INET ? ((struct sockaddr_in*)&local)->sin_port : ((struct sockaddr_in6*)&local)->sin6_port);
      }
      if (!error && pthread_create(&sg.thread, NULL, sg_thread, NULL)) error = "listen_failed";
    }
    if (error) sg_cleanup(); else sg.started = 1;
  }
  free(address);
  return error ? io_box(e, CID_LISTENERROR, io_str(e, error, strlen(error))) : term_pak(CID_LISTENING, sg.port);
}
#endif
#ifdef CID_SERVER_LISTEN
static Term server_listen_run(Env e, Term* f, IoWork* w) {
  (void)w;
  return sg_listen(e, f[0], 256, 0, 0);
}
#endif
#ifdef CID_SERVER_LISTEN_WITH_LIMITS
static Term server_listen_with_limits_run(Env e, Term* f, IoWork* w) {
  (void)w;
  Term fields[2];
  spare_free(e, cls_fit(2), ctr_take(e, f[1], 2, fields));
  // Explicit zero is invalid; only the compatibility entry uses zero internally.
  if (!(u32)fields[1]) {
    term_sink(e, f[0]);
    return io_box(e, CID_LISTENERROR, io_str(e, "invalid_config", 14));
  }
  return sg_listen(e, f[0], (u32)fields[0], (u32)fields[1], 0);
}
#endif
#ifdef CID_SERVER_LISTEN_STREAMING
static Term server_listen_streaming_run(Env e, Term* f, IoWork* w) {
  (void)w;
  return sg_listen(e, f[0], UINT32_MAX, 0, 1);
}
#endif
#ifdef CID_SERVER_LISTEN_STREAMING_WITH_LIMITS
static Term server_listen_streaming_with_limits_run(Env e, Term* f, IoWork* w) {
  (void)w;
  Term fields[2];
  spare_free(e, cls_fit(2), ctr_take(e, f[1], 2, fields));
  if (!(u32)fields[1]) {
    term_sink(e, f[0]);
    return io_box(e, CID_LISTENERROR, io_str(e, "invalid_config", 14));
  }
  return sg_listen(e, f[0], (u32)fields[0], (u32)fields[1], 1);
}
#endif
#if defined(CID_SERVER_NEXT) || defined(CID_SERVER_NEXT_STREAM)
static void server_next_call(IoWork* w) {
  pthread_mutex_lock(&sg.lock);
  while (sg.started && !sg.stopped && !sg.inputs) pthread_cond_wait(&sg.ready, &sg.lock);
  SgInput* p = sg.inputs;
  if (p) {
    sg.inputs = p->next; if (!sg.inputs) sg.inputs_tail = NULL;
    SgWork* work = sg_work(p->id);
    if (work) work->claimed = 1;
  }
  w->data = (char*)p;
  pthread_mutex_unlock(&sg.lock);
}
#endif
#ifdef CID_SERVER_NEXT
static Term server_next_pack(Env e, IoWork* w) {
  SgInput* p = (SgInput*)w->data;
  if (!p) {
    if (sg.started && !sg.joined) { pthread_join(sg.thread, NULL); sg.joined = 1; }
    return term_pak(CID_STOPPED, 0);
  }
  Term headers = term_pak(CID_NIL, 0);
  for (size_t i = p->count; i > 0; i--) {
    SgHeader* h = &p->headers[i - 1];
    Term header = io_node(e, CID_SERVERHEADER, io_str(e, h->name, strlen(h->name)), io_str(e, h->value, strlen(h->value)));
    headers = io_node(e, CID_CON, header, headers);
  }
  // Received flattens its Incoming value into six fields.
  Loc loc = heap_alloc(e, cls_fit(6));
  e.mem[loc] = p->id;
  e.mem[loc + 1] = io_str(e, p->method, strlen(p->method));
  e.mem[loc + 2] = io_str(e, p->path, strlen(p->path));
  e.mem[loc + 3] = io_str(e, p->target, strlen(p->target));
  e.mem[loc + 4] = headers; e.mem[loc + 5] = io_str(e, p->body, p->size);
  sg_input_free(p); w->data = NULL;
  return term_ctr(CID_RECEIVED, loc);
}
static Term server_next_run(Env e, Term* f, IoWork* w) {
  (void)e; (void)f;
  return io_work(w, server_next_call, server_next_pack);
}
#endif
#ifdef CID_SERVER_NEXT_STREAM
static void server_next_stream_call(IoWork* w) {
  server_next_call(w);
}
static Term server_next_stream_pack(Env e, IoWork* w) {
  SgInput* p = (SgInput*)w->data;
  if (!p) {
    if (sg.started && !sg.joined) { pthread_join(sg.thread, NULL); sg.joined = 1; }
    return term_pak(CID_STREAMSTOPPED, 0);
  }
  Term headers = term_pak(CID_NIL, 0);
  for (size_t i = p->count; i > 0; i--) {
    SgHeader* h = &p->headers[i - 1];
    Term header = io_node(e, CID_SERVERHEADER, io_str(e, h->name, strlen(h->name)), io_str(e, h->value, strlen(h->value)));
    headers = io_node(e, CID_CON, header, headers);
  }
  Loc loc = heap_alloc(e, cls_fit(5));
  e.mem[loc] = p->id;
  e.mem[loc + 1] = io_str(e, p->method, strlen(p->method));
  e.mem[loc + 2] = io_str(e, p->path, strlen(p->path));
  e.mem[loc + 3] = io_str(e, p->target, strlen(p->target));
  e.mem[loc + 4] = headers;
  sg_input_free(p); w->data = NULL;
  return term_ctr(CID_STREAMRECEIVED, loc);
}
static Term server_next_stream_run(Env e, Term* f, IoWork* w) {
  (void)e; (void)f;
  return io_work(w, server_next_stream_call, server_next_stream_pack);
}
#endif
#ifdef CID_SERVER_BODY_NEXT
typedef struct {
  SgBody* body;
  const char* error;
  int end;
} SgBodyResult;
static void server_body_next_call(IoWork* w) {
  u32 id = (u32)(uintptr_t)w->data;
  SgBodyResult* result = io_mem(calloc(1, sizeof(*result)));
  pthread_mutex_lock(&sg.lock);
  SgWork* work = sg_work(id);
  while (work && !work->body && !work->body_complete && !work->body_error
      && !work->closed && !sg.stopped) {
    pthread_cond_wait(&sg.ready, &sg.lock);
    work = sg_work(id);
  }
  if (!work) result->error = "request_closed";
  else if (work->body) {
    result->body = work->body;
    work->body = result->body->next;
    if (!work->body) work->body_tail = NULL;
    work->body_queued -= result->body->size;
    result->body->next = NULL;
    if (!work->body_complete && !work->body_error && !work->closed) {
      work->resume = 1;
      sg_notify();
    }
  } else if (work->body_error) result->error = work->body_error;
  else if (work->closed || sg.stopped) result->error = "request_closed";
  else result->end = 1;
  pthread_mutex_unlock(&sg.lock);
  w->data = (char*)result;
}
static Term server_body_next_pack(Env e, IoWork* w) {
  SgBodyResult* result = (SgBodyResult*)w->data;
  Term value;
  if (result->body) {
    value = io_box(e, CID_BODYCHUNK, io_str(e, result->body->data, result->body->size));
    free(result->body->data); free(result->body);
  } else if (result->error) {
    value = io_box(e, CID_BODYFAILURE, io_str(e, result->error, strlen(result->error)));
  } else value = term_pak(CID_BODYEND, 0);
  free(result); w->data = NULL;
  return value;
}
static Term server_body_next_run(Env e, Term* f, IoWork* w) {
  (void)e;
  if (!(u32)f[0]) return io_box(e, CID_BODYFAILURE, io_str(e, "request_closed", 14));
  w->data = (char*)(uintptr_t)(u32)f[0];
  return io_work(w, server_body_next_call, server_body_next_pack);
}
#endif
#ifdef CID_SERVER_METRICS
static Term server_metrics_run(Env e, Term* f, IoWork* w) {
  (void)f; (void)w;
  Loc loc = heap_alloc(e, cls_fit(SM_COUNT));
  for (unsigned i = 0; i < SM_COUNT; i++)
    e.mem[loc + i] = atomic_load_explicit(&sg_metrics[i], memory_order_relaxed);
  return term_ctr(CID_METRICS, loc);
}
#endif
#ifdef CID_SERVER_ACTIVE
static Term server_active_run(Env e, Term* f, IoWork* w) {
  (void)e; (void)w;
  pthread_mutex_lock(&sg.lock);
  SgWork* work = sg_work((u32)f[0]);
  int active = work && work->claimed && !work->closed && !sg.stopped && sg_now() < work->deadline;
  pthread_mutex_unlock(&sg.lock);
  return term_pak(active ? CID_TRUE : CID_FALSE, 0);
}
#endif
#ifdef CID_SERVER_FINISH
static Term server_finish_run(Env e, Term* f, IoWork* w) {
  (void)e; (void)w;
  pthread_mutex_lock(&sg.lock);
  SgWork* work = sg_work((u32)f[0]);
  if (work && work->claimed) {
    if (work->closed || sg.stopped) sg_work_clear(work);
    else if (!work->body_complete) {
      work->claimed = 0;
      work->cancel = 1;
      sg_notify();
    } else sg_work_clear(work);
    pthread_cond_broadcast(&sg.ready);
  }
  pthread_mutex_unlock(&sg.lock);
  return term_pak(CID_UNIT, 0);
}
#endif
static void server_reply_call(IoWork* w) {
  SgReply* p = (SgReply*)w->data;
  pthread_mutex_lock(&sg.lock);
  if (!sg.started || sg.stopped) p->error = "server_stopped";
  else {
    if (sg.replies_tail) sg.replies_tail->next = p; else sg.replies = p;
    sg.replies_tail = p;
    sg_notify();
    while (!p->done) pthread_cond_wait(&sg.ready, &sg.lock);
  }
  pthread_mutex_unlock(&sg.lock);
}
static Term server_reply_pack(Env e, IoWork* w) {
  SgReply* p = (SgReply*)w->data;
  Term result = p->error ? io_box(e, CID_REPLYERROR, io_str(e, p->error, strlen(p->error))) : term_pak(CID_SENT, 0);
  for (size_t i = 0; i < p->count; i++) { free(p->headers[i].name); free(p->headers[i].value); }
  free(p->body); free(p); w->data = NULL;
  return result;
}
static int sg_reply_headers(Env e, SgReply* p, Term items) {
  size_t total = 0;
  while (term_aux(items) != CID_NIL) {
    if (p->count == SG_HEADERS) { term_sink(e, items); p->error = "invalid_response"; return 0; }
    Term pair[2], header[2];
    spare_free(e, cls_fit(2), ctr_take(e, items, 2, pair));
    spare_free(e, cls_fit(2), ctr_take(e, pair[0], 2, header));
    items = pair[1];
    SgHeader* h = &p->headers[p->count++];
    u64 n, v;
    h->name = io_cstr(e, header[0], &n); h->value = io_cstr(e, header[1], &v);
    int valid = sg_token(h->name, n) && sg_value(h->value, v);
    sg_lower(h->name);
    if (!valid || n + v + 4 > 16384 - total || !strcmp(h->name, "content-length")
      || !strcmp(h->name, "transfer-encoding") || !strcmp(h->name, "connection") || !strcmp(h->name, "trailer")) {
      p->error = "invalid_response"; term_sink(e, items); return 0;
    }
    total += n + v + 4;
  }
  return 1;
}
static Term sg_reply_effect(Env e, IoWork* w, SgReply* p) {
  w->data = (char*)p;
  if (p->error) return server_reply_pack(e, w);
  return io_work(w, server_reply_call, server_reply_pack);
}
#ifdef CID_SERVER_REPLY
static Term server_reply_run(Env e, Term* f, IoWork* w) {
  SgReply* p = io_mem(calloc(1, sizeof(*p)));
  p->id = f[0]; p->operation = SG_REPLY;
  Term fields[3];
  spare_free(e, cls_fit(3), ctr_take(e, f[1], 3, fields));
  p->status = fields[0];
  u64 size;
  p->body = io_cstr(e, fields[2], &size); p->size = size;
  if (!p->id || p->status < 200 || p->status > 599 || size > 16 * 1024 * 1024
    || ((p->status == 204 || p->status == 205 || p->status == 304) && size)) p->error = "invalid_response";
  sg_reply_headers(e, p, fields[1]);
  return sg_reply_effect(e, w, p);
}
#endif
#ifdef CID_SERVER_STREAM_START_RAW
static Term server_stream_start_raw_run(Env e, Term* f, IoWork* w) {
  SgReply* p = io_mem(calloc(1, sizeof(*p)));
  p->id = f[0]; p->operation = SG_STREAM_START;
  p->status = f[1];
  p->keep_alive = (u32)f[3] != 0;
  if (!p->id || (u32)f[3] > 1 || p->status < 200 || p->status > 599
    || p->status == 204 || p->status == 205 || p->status == 304) p->error = "invalid_response";
  sg_reply_headers(e, p, f[2]);
  return sg_reply_effect(e, w, p);
}
#endif
#ifdef CID_SERVER_STREAM_WRITE
static Term server_stream_write_run(Env e, Term* f, IoWork* w) {
  SgReply* p = io_mem(calloc(1, sizeof(*p)));
  p->id = f[0]; p->operation = SG_STREAM_WRITE;
  u64 size;
  p->body = io_cstr(e, f[1], &size); p->size = size;
  if (!p->id || size > 16 * 1024 * 1024) p->error = "invalid_response";
  return sg_reply_effect(e, w, p);
}
#endif
#ifdef CID_SERVER_STREAM_END
static Term server_stream_end_run(Env e, Term* f, IoWork* w) {
  SgReply* p = io_mem(calloc(1, sizeof(*p)));
  p->id = f[0]; p->operation = SG_STREAM_END;
  if (!p->id) p->error = "invalid_response";
  return sg_reply_effect(e, w, p);
}
#endif
#ifdef CID_SERVER_STOP
static Term server_stop_pack(Env e, IoWork* w) {
  (void)e;
  free(w->data); w->data = NULL;
  return term_pak(CID_UNIT, 0);
}
static Term server_stop_run(Env e, Term* f, IoWork* w) {
  (void)e; (void)f;
  w->data = (char*)io_mem(calloc(1, sizeof(SgReply)));
  return io_work(w, server_reply_call, server_stop_pack);
}
#endif
static void __attribute__((constructor)) server_register(void) {
#ifdef CID_SERVER_METRICS
  io_eff(CID_SERVER_METRICS, server_metrics_run, 0);
#endif
#ifdef CID_SERVER_ACTIVE
  io_eff(CID_SERVER_ACTIVE, server_active_run, 0);
#endif
#ifdef CID_SERVER_FINISH
  io_eff(CID_SERVER_FINISH, server_finish_run, 0);
#endif
#ifdef CID_SERVER_LISTEN
  io_eff(CID_SERVER_LISTEN, server_listen_run, 0);
#endif
#ifdef CID_SERVER_LISTEN_WITH_LIMITS
  io_eff(CID_SERVER_LISTEN_WITH_LIMITS, server_listen_with_limits_run, 0);
#endif
#ifdef CID_SERVER_LISTEN_STREAMING
  io_eff(CID_SERVER_LISTEN_STREAMING, server_listen_streaming_run, 0);
#endif
#ifdef CID_SERVER_LISTEN_STREAMING_WITH_LIMITS
  io_eff(CID_SERVER_LISTEN_STREAMING_WITH_LIMITS, server_listen_streaming_with_limits_run, 0);
#endif
#ifdef CID_SERVER_NEXT
  io_eff(CID_SERVER_NEXT, server_next_run, 0);
#endif
#ifdef CID_SERVER_NEXT_STREAM
  io_eff(CID_SERVER_NEXT_STREAM, server_next_stream_run, 0);
#endif
#ifdef CID_SERVER_BODY_NEXT
  io_eff(CID_SERVER_BODY_NEXT, server_body_next_run, 0);
#endif
#ifdef CID_SERVER_REPLY
  io_eff(CID_SERVER_REPLY, server_reply_run, 0);
#endif
#ifdef CID_SERVER_STREAM_START_RAW
  io_eff(CID_SERVER_STREAM_START_RAW, server_stream_start_raw_run, 0);
#endif
#ifdef CID_SERVER_STREAM_WRITE
  io_eff(CID_SERVER_STREAM_WRITE, server_stream_write_run, 0);
#endif
#ifdef CID_SERVER_STREAM_END
  io_eff(CID_SERVER_STREAM_END, server_stream_end_run, 0);
#endif
#ifdef CID_SERVER_STOP
  io_eff(CID_SERVER_STOP, server_stop_run, 0);
#endif
}
