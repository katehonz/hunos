## test_jsonbody.nim
##
## Tests for jsonBodyMiddleware.
##
## Run:
##   nim c --threads:on --mm:orc --path:src -r tests/test_jsonbody.nim

import hunos, hunos/router, hunos/middleware, std/json

proc apiHandler(request: Request) {.gcsafe.} =
  let json = getJsonBody(request)
  var headers: HttpHeaders
  headers["Content-Type"] = "application/json"
  request.respond(200, headers, $json)

var r = newRouter()
r.post("/api", apiHandler)

var stack = newMiddlewareStack(r)
stack.use(jsonBodyMiddleware())

let handler = stack.toHandler()

block: # Test middleware chain compiles and converts correctly
  assert handler != nil
  let h2: RequestHandler = stack
  assert h2 != nil
  echo "[OK] jsonBodyMiddleware compiles and chains correctly"

block: # Test getJsonBody parses valid JSON
  let testBody = """{"name":"test","value":123}"""
  var headers: HttpHeaders
  headers["Content-Type"] = "application/json"

  var mockReq: RequestObj
  mockReq.body = testBody
  mockReq.headers = headers

  let json = getJsonBody(addr mockReq)
  assert json.kind == JObject
  assert json["name"].str == "test"
  assert json["value"].num == 123
  echo "[OK] getJsonBody parses valid JSON correctly"

block: # Test getJsonBody returns empty object for empty body
  var mockReq: RequestObj
  mockReq.body = ""
  mockReq.headers = newSeq[(string, string)]()

  let json = getJsonBody(addr mockReq)
  assert json.kind == JObject
  assert json.len == 0
  echo "[OK] getJsonBody returns empty object for empty body"

echo "All jsonBody middleware tests passed!"