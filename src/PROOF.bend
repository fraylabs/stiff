import Base
import ./http.bend as Http
import ./LAWS.bend as Laws

def Laws.timeout_is_explicit(ms, request):
  match request:
    case Http.Request{method, url, body, timeout_ms, max_bytes}:
      {==}

def Laws.body_limit_is_explicit(bytes, request):
  match request:
    case Http.Request{method, url, body, timeout_ms, max_bytes}:
      {==}

def Laws.setting_timeout_preserves_body_limit(ms, request):
  match request:
    case Http.Request{method, url, body, timeout_ms, max_bytes}:
      {==}
