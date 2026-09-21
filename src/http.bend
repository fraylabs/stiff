import Base

# Pure request policy. Network effects are supplied by the native backend.
type Header is Data:
  Header{name: String, value: String}

type Request is Data:
  Request{method: String, url: String, body: String, timeout_ms: U32, max_bytes: U32, headers: List<&2, Header>}

def get(url: String) -> Request:
  Request{"GET", url, "", 10000, 1048576, Nil{}}

def post_json(url: String, body: String) -> Request:
  Request{"POST", url, body, 10000, 1048576, Nil{}}

def put_json(url: String, body: String) -> Request:
  Request{"PUT", url, body, 10000, 1048576, Nil{}}

def patch_json(url: String, body: String) -> Request:
  Request{"PATCH", url, body, 10000, 1048576, Nil{}}

def delete(url: String) -> Request:
  Request{"DELETE", url, "", 10000, 1048576, Nil{}}

def head(url: String) -> Request:
  Request{"HEAD", url, "", 10000, 1048576, Nil{}}

def with_timeout(ms: U32, request: Request) -> Request:
  match request:
    case Request{method, url, body, timeout_ms, max_bytes, headers}:
      Request{method, url, body, ms, max_bytes, headers}

def with_max_bytes(bytes: U32, request: Request) -> Request:
  match request:
    case Request{method, url, body, timeout_ms, max_bytes, headers}:
      Request{method, url, body, timeout_ms, bytes, headers}

def timeout(request: Request) -> U32:
  match request:
    case Request{method, url, body, timeout_ms, max_bytes, headers}:
      timeout_ms

def body_limit(request: Request) -> U32:
  match request:
    case Request{method, url, body, timeout_ms, max_bytes, headers}:
      max_bytes

def is_success(+status: U32) -> Bool:
  Bool.and(U32.is_ge(status, 200), U32.is_lt(status, 300))

# Latest call wins for the same case-insensitive name at the native boundary.
def with_header(name: String, value: String, request: Request) -> Request:
  match request:
    case Request{method, url, body, timeout_ms, max_bytes, headers}:
      Request{method, url, body, timeout_ms, max_bytes, Con{Header{name, value}, headers}}

def with_bearer(token: String, request: Request) -> Request:
  with_header("Authorization", "Bearer " ++ token, request)
