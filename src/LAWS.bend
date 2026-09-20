import Base
import ./http.bend as Http

law timeout_is_explicit:
  for +ms: U32
  for +request: Http.Request
  {Http.timeout(Http.with_timeout(ms, request)) == ms : U32}

law body_limit_is_explicit:
  for +bytes: U32
  for +request: Http.Request
  {Http.body_limit(Http.with_max_bytes(bytes, request)) == bytes : U32}

law setting_timeout_preserves_body_limit:
  for +ms: U32
  for +request: Http.Request
  {Http.body_limit(Http.with_timeout(ms, request)) == Http.body_limit(request) : U32}
