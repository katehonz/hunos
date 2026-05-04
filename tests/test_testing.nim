## test_testing.nim
##
## Tests for testing utilities.
##
## Run:
##   nim c --threads:on --mm:orc --path:src -r tests/test_testing.nim

import hunos, hunos/testing, std/strutils

block: # Test mockServer creation
  echo "[TEST] mockServer creation"
  proc defaultHandler(request: Request, res: var MockResponse) {.gcsafe.} = discard
  let server = mockServer(proc(r: Request) {.gcsafe.} = discard)
  assert server != nil
  echo "[OK] mockServer creates valid server"

block: # Test runOnce with handler
  echo "[TEST] runOnce with handler"

  proc testHandler(request: Request, res: var MockResponse) {.gcsafe.} =
    if request.path == "/":
      res.code = 200
      res.body = "Hello World"
    elif request.path == "/api":
      res.code = 200
      res.headers = @[("Content-Type", "application/json")]
      res.body = "{\"status\": \"ok\"}"
    else:
      res.code = 404
      res.body = "Not Found"

  let resp1 = runOnce(testHandler, "GET", "/")
  assert resp1.code == 200
  assert resp1.body == "Hello World"
  echo "[OK] runOnce returns correct response"

  let resp2 = runOnce(testHandler, "GET", "/api")
  assert resp2.code == 200
  assert resp2.headers["Content-Type"] == "application/json"
  echo "[OK] runOnce handles JSON response"

  let resp3 = runOnce(testHandler, "GET", "/nonexistent")
  assert resp3.code == 404
  assert resp3.body == "Not Found"
  echo "[OK] runOnce returns 404 for unknown path"

block: # Test debugResponse
  echo "[TEST] debugResponse formatting"
  var resp: MockResponse
  resp.code = 200
  resp.headers = @[("Content-Type", "text/plain")]
  resp.body = "Hello"

  let debug = debugResponse(resp)
  assert debug.startsWith("HTTP/1.1 200 OK")
  assert debug.contains("Content-Type: text/plain")
  assert debug.contains("Hello")
  echo "[OK] debugResponse formats correctly"

block: # Test runOnce with POST and body
  echo "[TEST] runOnce with POST body"

  proc postHandler(request: Request, res: var MockResponse) {.gcsafe.} =
    if request.httpMethod == "POST" and request.path == "/data":
      res.code = 201
      res.headers = @[("Content-Type", "text/plain")]
      res.body = "Created: " & request.body
    else:
      res.code = 405

  var reqHeaders: HttpHeaders
  reqHeaders.add(("Content-Type", "application/json"))

  let resp = runOnce(postHandler, "POST", "/data", "{\"name\":\"test\"}", reqHeaders)
  assert resp.code == 201
  assert resp.body.contains("Created:")
  assert resp.body.contains("{\"name\":\"test\"}")
  echo "[OK] runOnce handles POST with body correctly"

block: # Test statusText
  echo "[TEST] statusText helper"
  assert statusText(200) == "OK"
  assert statusText(404) == "Not Found"
  assert statusText(500) == "Internal Server Error"
  echo "[OK] statusText returns correct texts"

echo ""
echo "All testing utilities tests passed!"