import Base

# Numbers contain the decimal rendering produced by the host JSON parser.
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
