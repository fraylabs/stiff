/* Compile around generated C to exercise the actual registered callback. */
/* Match Bend's feature selection before the first system header. */
#ifndef __APPLE__
#define _GNU_SOURCE
#endif
#include <event2/http.h>
static void (*retained_callback)(struct evhttp_connection*, void*);
static void* retained_argument;
static void capture_chunk_callback(struct evhttp_request* request,
    struct evbuffer* body, void (*callback)(struct evhttp_connection*, void*), void* argument) {
  (void)request; (void)body;
  retained_callback = callback;
  retained_argument = argument;
}
#define evhttp_send_reply_chunk_with_cb capture_chunk_callback
#define main stiff_bend_program_main
#include "generated.c"
#undef main
#undef evhttp_send_reply_chunk_with_cb
#include <assert.h>

static SgReply* queue_chunk(void) {
  SgReply* reply = calloc(1, sizeof(*reply));
  assert(reply);
  reply->id = 1;
  reply->operation = SG_STREAM_WRITE;
  reply->body = calloc(2, 1);
  assert(reply->body);
  reply->body[0] = 'x';
  reply->size = 1;
  sg_handle_reply(reply);
  assert(!reply->error && reply->wait_write && !reply->done);
  assert(retained_callback);
  return reply;
}
static void free_reply(SgReply* reply) {
  free(reply->body);
  free(reply);
}
static void drain(struct evbuffer* buffer) {
  evbuffer_unfreeze(buffer, 1);
  evbuffer_drain(buffer, evbuffer_get_length(buffer));
}
int main(void) {
  int listener = socket(AF_INET, SOCK_STREAM, 0);
  assert(listener >= 0);
  struct sockaddr_in address = {.sin_family = AF_INET, .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
  assert(bind(listener, (struct sockaddr*)&address, sizeof(address)) == 0);
  assert(listen(listener, 1) == 0);
  socklen_t length = sizeof(address);
  assert(getsockname(listener, (struct sockaddr*)&address, &length) == 0);
  struct event_base* base = event_base_new();
  assert(base);
  struct evhttp_connection* connection = evhttp_connection_base_new(base, NULL, "127.0.0.1", ntohs(address.sin_port));
  struct evhttp_request* request = evhttp_request_new(NULL, NULL);
  assert(connection && request);
  assert(evhttp_make_request(connection, request, EVHTTP_REQ_GET, "/") == 0);
  assert(evhttp_request_get_connection(request) == connection);
  struct evbuffer* output = bufferevent_get_output(evhttp_connection_get_bufferevent(connection));
  drain(output);
  sg.max_pending = 1;
  sg.slots[0].id = 1;
  sg.slots[0].request = request;
  sg.slots[0].streaming = 1;

  SgReply* first = queue_chunk();
  void (*old_callback)(struct evhttp_connection*, void*) = retained_callback;
  void* old_argument = retained_argument;
  old_callback(connection, old_argument);
  assert(first->done && !sg.slots[0].write_waiter);
  free_reply(first);
  /* Libevent retains cb/cb_arg and can notify the same empty output again. */
  old_callback(connection, old_argument);

  SgReply* second = queue_chunk();
  assert(evbuffer_add(output, "pending", 7) == 0);
  old_callback(connection, old_argument);
  assert(!second->done && sg.slots[0].write_waiter == second);
  drain(output);
  retained_callback(connection, retained_argument);
  assert(second->done && !sg.slots[0].write_waiter);
  free_reply(second);
  retained_callback(connection, retained_argument);

  /* Closing wakes the waiter; later notifications must not touch its storage. */
  SgReply* closed = queue_chunk();
  sg_closed(connection, &sg.slots[0]);
  assert(closed->done && !strcmp(closed->error, "request_closed"));
  assert(!sg.slots[0].write_waiter);
  free_reply(closed);
  old_callback(connection, old_argument);

  memset(&sg.slots[0], 0, sizeof(sg.slots[0]));
  old_callback(connection, old_argument);

  /* A reused slot on another connection must ignore the old notification. */
  struct evhttp_connection* replacement = evhttp_connection_base_new(
      base, NULL, "127.0.0.1", ntohs(address.sin_port));
  struct evhttp_request* replacement_request = evhttp_request_new(NULL, NULL);
  assert(replacement && replacement_request);
  assert(evhttp_make_request(replacement, replacement_request, EVHTTP_REQ_GET, "/") == 0);
  drain(bufferevent_get_output(evhttp_connection_get_bufferevent(replacement)));
  sg.slots[0].id = 1;
  sg.slots[0].request = replacement_request;
  sg.slots[0].streaming = 1;
  SgReply* reused = queue_chunk();
  old_callback(connection, old_argument);
  assert(!reused->done && sg.slots[0].write_waiter == reused);
  retained_callback(replacement, retained_argument);
  assert(reused->done && !sg.slots[0].write_waiter);
  free_reply(reused);

  memset(&sg.slots[0], 0, sizeof(sg.slots[0]));
  evhttp_connection_free(replacement);
  evhttp_connection_free(connection);
  event_base_free(base);
  close(listener);
  puts("retained callback lifetime and drain checks passed");
  return 0;
}
