import Base

type QueryParam is Data:
  QueryParam{name: String, value: String}

type UrlResult is Data:
  UrlReady{text: String}
  UrlError{code: String}

# Encode one raw component, not an already-encoded string or a whole URL.
def Url.encode_component(text: String) -> IO(UrlResult):
  import "./effects/url.c"

# Append encoded pairs, preserving existing query bytes, duplicates and fragment.
def Url.with_query(base: String, params: List<&2, QueryParam>) -> IO(UrlResult):
  import "./effects/url.c"
