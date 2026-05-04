## test_auth.nim
##
## Tests for basicAuthMiddleware.
##
## Run:
##   nim c --threads:on --mm:orc --path:src -r tests/test_auth.nim

import hunos, hunos/router, hunos/middleware, std/base64

var verifyCalls = 0

proc verifyUser(username, password: string): bool {.gcsafe.} =
  verifyCalls += 1
  return username == "admin" and password == "secret123"

proc apiHandler(request: Request) {.gcsafe.} =
  var headers: HttpHeaders
  headers["Content-Type"] = "text/plain"
  request.respond(200, headers, "Welcome")

var r = newRouter()
r.get("/protected", apiHandler)

var stack = newMiddlewareStack(r)
stack.use(basicAuthMiddleware("Admin Area", verifyUser))

let handler = stack.toHandler()

block: # Test basicAuthMiddleware compiles and chains correctly
  assert handler != nil
  echo "[OK] basicAuthMiddleware compiles correctly"

block: # Test verifyUser function
  assert verifyUser("admin", "secret123") == true
  assert verifyUser("admin", "wrong") == false
  assert verifyUser("unknown", "secret123") == false
  echo "[OK] Verify handler works correctly"

block: # Test basicAuthMiddleware returns proc
  let middleware = basicAuthMiddleware("Test", verifyUser)
  assert middleware != nil
  echo "[OK] basicAuthMiddleware returns valid proc"

echo "All auth tests passed!"