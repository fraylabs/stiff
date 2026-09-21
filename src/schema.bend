import Base
import ./json.bend as Json
import ./server.bend as Web

type Field<-S: Data> is Data:
  Field{name: String, required: Bool, schema: S}

type Schema is Data:
  Text{min: Nat, max: Nat}
  UInt{min: U32, max: U32}
  Boolean{}
  Nullable{inner: Schema}
  Sequence{inner: Schema, min: Nat, max: Nat}
  Object{fields: List<&2, Field<Schema>>, strict: Bool}

type Verdict is Data:
  Valid{}
  Invalid{path: List<&2, String>, code: String}

type Task is Data:
  Check{schema: Schema, path: List<&2, String>, value: Json.Json}
  Failure{path: List<&2, String>, code: String}

def check(ok: Bool, path: List<&2, String>, code: String, rest: List<&2, Task>) -> List<&2, Task>:
  match ok:
    case True{}: rest
    case False{}: [Failure{path, code}]

def text(min: Nat, max: Nat, path: List<&2, String>, value: Json.Json, rest: List<&2, Task>) -> List<&2, Task>:
  match value:
    case Json.JsonString{+s}:
      check(Bool.and(Nat.is_ge(String.length(s), min), Nat.is_le(String.length(s), max)), path, "length", rest)
    case other: [Failure{path, "type"}]

def uint_value(min: U32, max: U32, path: List<&2, String>, value: Maybe<&2, U32>, rest: List<&2, Task>) -> List<&2, Task>:
  match value:
    case Some{+n}: check(Bool.and(U32.is_ge(n, min), U32.is_le(n, max)), path, "range", rest)
    case None{}: [Failure{path, "integer"}]

def uint(min: U32, max: U32, path: List<&2, String>, value: Json.Json, rest: List<&2, Task>) -> List<&2, Task>:
  match value:
    case Json.JsonNumber{s}: uint_value(min, max, path, U32.read(s), rest)
    case other: [Failure{path, "type"}]

def boolean(path: List<&2, String>, value: Json.Json, rest: List<&2, Task>) -> List<&2, Task>:
  match value:
    case Json.JsonBool{b}: rest
    case other: [Failure{path, "type"}]

def nullable(inner: Schema, path: List<&2, String>, value: Json.Json, rest: List<&2, Task>) -> List<&2, Task>:
  match value:
    case Json.JsonNull{}: rest
    case other: Check{inner, path, other} <> rest

def child(path: List<&2, String>, name: String) -> List<&2, String>:
  List.append(&2, String, path, [name])

def items(+schema: Schema, +path: List<&2, String>, values: List<&2, Json.Json>, +index: Nat, rest: List<&2, Task>) -> List<&2, Task>:
  match values:
    case Nil{}: rest
    case Con{value, tail}:
      Check{schema, child(path, Nat.show(index)), value} <> items(schema, path, tail, 1n+index, rest)

def sequence(inner: Schema, min: Nat, max: Nat, +path: List<&2, String>, value: Json.Json, rest: List<&2, Task>) -> List<&2, Task>:
  match value:
    case Json.JsonArray{+values}:
      check(Bool.and(Nat.is_ge(List.length(&2, Json.Json, values), min), Nat.is_le(List.length(&2, Json.Json, values), max)), path, "length", items(inner, path, values, 0n, rest))
    case other: [Failure{path, "type"}]

def field_value(required: Bool, schema: Schema, path: List<&2, String>, value: Maybe<Json.Json>, rest: List<&2, Task>) -> List<&2, Task>:
  match value:
    case Some{v}: Check{schema, path, v} <> rest
    case None{}: check(Bool.not(required), path, "required", rest)

def fields(rules: List<&2, Field<Schema>>, +path: List<&2, String>, +entries: List<&2, Sigma<&2, &2, String, _ => Json.Json>>, rest: List<&2, Task>) -> List<&2, Task>:
  match rules:
    case Nil{}: rest
    case Con{Field{+name, required, schema}, tail}:
      field_value(required, schema, child(path, name), Json.lookup(name, entries), fields(tail, path, entries, rest))

def named_step(found: Bool, next: Unit -> Bool) -> Bool:
  match found:
    case True{}: True{}
    case False{}: next(Unit{})

def named(+name: String, rules: List<&2, Field<Schema>>) -> Bool:
  match rules:
    case Nil{}: False{}
    case Con{Field{key, required, schema}, tail}: named_step(String.eq(name, key), u => named(name, tail))

def extras(+rules: List<&2, Field<Schema>>, +path: List<&2, String>, entries: List<&2, Sigma<&2, &2, String, _ => Json.Json>>, rest: List<&2, Task>) -> List<&2, Task>:
  match entries:
    case Nil{}: rest
    case Con{(+name, value), tail}:
      check(named(name, rules), child(path, name), "unknown", extras(rules, path, tail, rest))

def strict(enabled: Bool, rules: List<&2, Field<Schema>>, path: List<&2, String>, entries: List<&2, Sigma<&2, &2, String, _ => Json.Json>>, rest: List<&2, Task>) -> List<&2, Task>:
  match enabled:
    case False{}: rest
    case True{}: extras(rules, path, entries, rest)

def object(+rules: List<&2, Field<Schema>>, closed: Bool, +path: List<&2, String>, value: Json.Json, rest: List<&2, Task>) -> List<&2, Task>:
  match value:
    case Json.JsonObject{+entries}: fields(rules, path, entries, strict(closed, rules, path, entries, rest))
    case other: [Failure{path, "type"}]

def expand(schema: Schema, path: List<&2, String>, value: Json.Json, rest: List<&2, Task>) -> List<&2, Task>:
  match schema:
    case Text{min, max}: text(min, max, path, value, rest)
    case UInt{min, max}: uint(min, max, path, value, rest)
    case Boolean{}: boolean(path, value, rest)
    case Nullable{inner}: nullable(inner, path, value, rest)
    case Sequence{inner, min, max}: sequence(inner, min, max, path, value, rest)
    case Object{rules, closed}: object(rules, closed, path, value, rest)

# Worklist expansion terminates for finite schema/data; this is tested, not a law.
@unsafe
def run(tasks: List<&2, Task>) -> Verdict:
  match tasks:
    case Nil{}: Valid{}
    case Con{Failure{path, code}, rest}: Invalid{path, code}
    case Con{Check{schema, path, value}, rest}: run(expand(schema, path, value, rest))

def validate(schema: Schema, value: Json.Json) -> Verdict:
  run([Check{schema, Nil{}, value}])

def path_json(path: List<&2, String>) -> List<&2, Json.Json>:
  match path:
    case Nil{}: Nil{}
    case Con{segment, tail}: Json.string(segment) <> path_json(tail)

def error(path: List<&2, String>, code: String) -> IO(Web.Reply):
  Web.json_value(422, Json.object([("error", Json.object([
    ("code", Json.string("validation_failed")), ("message", Json.string("Request validation failed")),
    ("path", Json.array(path_json(path))), ("reason", Json.string(code))]))]))

def accepted(result: Verdict, value: Json.Json, next: Json.Json -> IO(Web.Reply)) -> IO(Web.Reply):
  match result:
    case Valid{}: next(value)
    case Invalid{path, code}: error(path, code)

def apply(schema: Schema, +value: Json.Json, next: Json.Json -> IO(Web.Reply)) -> IO(Web.Reply):
  accepted(validate(schema, value), value, next)
