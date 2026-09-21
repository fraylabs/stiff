import Base

# Numbers contain decimal tokens; native effects validate syntax and range.
type Json is Data:
  JsonNull{}
  JsonBool{value: Bool}
  JsonNumber{decimal: String}
  JsonString{value: String}
  JsonArray{items: List<&2, Json>}
  JsonObject{entries: List<&2, Sigma<&2, &2, String, _ => Json>>}

type ParseResult is Data:
  JsonDone{value: Json}
  JsonFailure{code: String, message: String}

def Json.parse(text: String) -> IO(ParseResult):
  import "./effects/json.c"

def lookup_step(found: Bool, value: Json, rest: Unit -> Maybe<Json>) -> Maybe<Json>:
  match found:
    case True{}:
      Some{value}
    case False{}:
      rest(Unit{})

def lookup(+key: String, entries: List<&2, Sigma<&2, &2, String, _ => Json>>) -> Maybe<Json>:
  match entries:
    case Nil{}:
      None{}
    case Con{(name, value), tail}:
      lookup_step(String.eq(key, name), value, u => lookup(key, tail))

def field(key: String, value: Json) -> Maybe<Json>:
  match value:
    case JsonObject{entries}:
      lookup(key, entries)
    case other:
      None{}

def as_string(value: Json) -> Maybe<String>:
  match value:
    case JsonString{text}:
      Some{text}
    case other:
      None{}

# Builders preserve list order. Duplicate object keys are rejected on encoding.
def object(entries: List<&2, Sigma<&2, &2, String, _ => Json>>) -> Json:
  JsonObject{entries}

def array(items: List<&2, Json>) -> Json:
  JsonArray{items}

def string(text: String) -> Json:
  JsonString{text}

def boolean(value: Bool) -> Json:
  JsonBool{value}

def null() -> Json:
  JsonNull{}

def u32(value: U32) -> Json:
  JsonNumber{U32.show(value)}

type EncodeResult is Data:
  JsonEncoded{text: String}
  JsonEncodeFailure{code: String, message: String}

def Json.stringify_with_limit(value: Json, max_bytes: U32) -> IO(EncodeResult):
  import "./effects/json.c"

def Json.stringify(value: Json) -> IO(EncodeResult):
  Json.stringify_with_limit(value, 16777216)
