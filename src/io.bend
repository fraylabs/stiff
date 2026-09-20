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

def Stiff.send_json(request: Http.Request) -> IO(JsonResult):
  import "./effects/stiff.c"
  import "./effects/stiff.js"
