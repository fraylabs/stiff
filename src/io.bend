import Base
import ./http.bend as Http
import ./json.bend as Json

type Response is Data:
  Response{status: U32, body: String}

type HttpResult is Data:
  HttpOk{response: Response}
  HttpError{code: String, message: String}

type JsonResult is Data:
  JsonOk{status: U32, value: Json.Json}
  JsonError{code: String, message: String}

def Stiff.send(request: Http.Request) -> IO(HttpResult):
  import "./effects/stiff.c"
  import "./effects/stiff.js"

def finish_json(status: U32, result: Json.ParseResult) -> IO(JsonResult):
  match result:
    case Json.JsonDone{value}:
      IO.pure(JsonResult, JsonOk{status, value})
    case Json.JsonFailure{code, message}:
      IO.pure(JsonResult, JsonError{code, message})

def decode_response(result: HttpResult) -> IO(JsonResult):
  match result:
    case HttpOk{Response{status, body}}:
      do IO<JsonResult>:
        parsed : Json.ParseResult <- Json.Json.parse(body)
        finish_json(status, parsed)
    case HttpError{code, message}:
      IO.pure(JsonResult, JsonError{code, message})

def Stiff.send_json(request: Http.Request) -> IO(JsonResult):
  IO.bind(HttpResult, JsonResult, Stiff.send(request), decode_response)
