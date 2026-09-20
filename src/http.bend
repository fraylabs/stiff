import Base

# Pure request policy. Network effects are supplied by the native backend.
type Request is Data:
  Request{method: String, url: String, body: String, timeout_ms: U32, max_bytes: U32}

def get(url: String) -> Request:
  Request{"GET", url, "", 10000, 1048576}

def post_json(url: String, body: String) -> Request:
  Request{"POST", url, body, 10000, 1048576}

def with_timeout(ms: U32, request: Request) -> Request:
  match request:
    case Request{method, url, body, timeout_ms, max_bytes}:
      Request{method, url, body, ms, max_bytes}

def with_max_bytes(bytes: U32, request: Request) -> Request:
  match request:
    case Request{method, url, body, timeout_ms, max_bytes}:
      Request{method, url, body, timeout_ms, bytes}

def timeout(request: Request) -> U32:
  match request:
    case Request{method, url, body, timeout_ms, max_bytes}:
      timeout_ms

def body_limit(request: Request) -> U32:
  match request:
    case Request{method, url, body, timeout_ms, max_bytes}:
      max_bytes

def is_success(+status: U32) -> Bool:
  Bool.and(U32.is_ge(status, 200), U32.is_lt(status, 300))
