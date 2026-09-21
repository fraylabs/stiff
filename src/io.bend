import Base
import ./http.bend as Http
import ./json.bend as Json

type ResponseHeader is Data:
  ResponseHeader{name: String, value: String}

type Response is Data:
  Response{status: U32, body: String, headers: List<&2, ResponseHeader>}

# Names from the transport are lowercase. Pass a lowercase lookup name.
def header_step(equal: Bool, value: String, rest: Unit -> Maybe<String>) -> Maybe<String>:
  match equal:
    case True{}: Some{value}
    case False{}: rest(Unit{})

def header(+name: String, headers: List<&2, ResponseHeader>) -> Maybe<String>:
  match headers:
    case Nil{}: None{}
    case Con{ResponseHeader{key, value}, tail}:
      header_step(String.eq(name, key), value, u => header(name, tail))

def header_values_step(equal: Bool, value: String, rest: List<String>) -> List<String>:
  match equal:
    case True{}: Con{value, rest}
    case False{}: rest

def header_values(+name: String, headers: List<&2, ResponseHeader>) -> List<String>:
  match headers:
    case Nil{}: Nil{}
    case Con{ResponseHeader{key, value}, tail}:
      header_values_step(String.eq(name, key), value, header_values(name, tail))

type HttpResult is Data:
  HttpOk{response: Response}
  HttpError{code: String, message: String}

type JsonResult is Data:
  JsonOk{status: U32, value: Json.Json}
  JsonError{code: String, message: String}

def Stiff.send(request: Http.Request) -> IO(HttpResult):
  import "./effects/stiff.c"

def finish_json(status: U32, result: Json.ParseResult) -> IO(JsonResult):
  match result:
    case Json.JsonDone{value}:
      IO.pure(JsonResult, JsonOk{status, value})
    case Json.JsonFailure{code, message}:
      IO.pure(JsonResult, JsonError{code, message})

def decode_response(result: HttpResult) -> IO(JsonResult):
  match result:
    case HttpOk{Response{status, body, headers}}:
      do IO<JsonResult>:
        parsed : Json.ParseResult <- Json.Json.parse(body)
        finish_json(status, parsed)
    case HttpError{code, message}:
      IO.pure(JsonResult, JsonError{code, message})

def Stiff.send_json(request: Http.Request) -> IO(JsonResult):
  IO.bind(HttpResult, JsonResult, Stiff.send(request), decode_response)
