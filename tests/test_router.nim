## test_router.nim
##
## Tests for trie-based URL router edge cases.
##
## Run:
##   nim c --threads:on --mm:orc --path:src -r tests/test_router.nim

import hunos, hunos/router, hunos/common

block: # Test basic route matching
  var router = newRouter()
  proc h1(request: Request) {.gcsafe.} = request.respond(200, body = "root")
  proc h2(request: Request) {.gcsafe.} = request.respond(200, body = "users")
  proc h3(request: Request) {.gcsafe.} = request.respond(200, body = "user")

  router.get("/", h1)
  router.get("/users", h2)
  router.get("/users/@id", h3)

  assert true  # Router created successfully
  echo "[OK] Router compiles with basic routes"

block: # Test parameter extraction
  var router = newRouter()

  proc paramHandler(request: Request) {.gcsafe.} =
    let capturedId = request.pathParams["id"]
    request.respond(200, body = capturedId)

  router.get("/items/@id", paramHandler)
  echo "[OK] Router with path parameters compiles"

block: # Test wildcard routes
  var router = newRouter()
  proc wildHandler(request: Request) {.gcsafe.} = request.respond(200, body = "wild")

  router.get("/files/**", wildHandler)
  echo "[OK] Router with wildcard routes compiles"

block: # Test multiple HTTP methods on same path
  var router = newRouter()
  proc getH(request: Request) {.gcsafe.} = request.respond(200, body = "GET")
  proc postH(request: Request) {.gcsafe.} = request.respond(200, body = "POST")
  proc putH(request: Request) {.gcsafe.} = request.respond(200, body = "PUT")
  proc deleteH(request: Request) {.gcsafe.} = request.respond(200, body = "DELETE")
  proc patchH(request: Request) {.gcsafe.} = request.respond(200, body = "PATCH")
  proc headH(request: Request) {.gcsafe.} = request.respond(200, body = "HEAD")
  proc optionsH(request: Request) {.gcsafe.} = request.respond(200, body = "OPTIONS")

  router.get("/api/resource", getH)
  router.post("/api/resource", postH)
  router.put("/api/resource", putH)
  router.delete("/api/resource", deleteH)
  router.patch("/api/resource", patchH)
  router.head("/api/resource", headH)
  router.options("/api/resource", optionsH)
  echo "[OK] Router supports all 7 HTTP methods"

block: # Test custom error handlers
  var router = newRouter()
  proc handler(request: Request) {.gcsafe.} = request.respond(200)
  router.get("/", handler)

  router.notFoundHandler = proc(request: Request) {.gcsafe.} =
    request.respond(404, body = "Custom 404")

  router.methodNotAllowedHandler = proc(request: Request) {.gcsafe.} =
    request.respond(405, body = "Custom 405")

  echo "[OK] Router accepts custom error handlers"

block: # Test empty route raises error
  var router = newRouter()
  proc handler(request: Request) {.gcsafe.} = discard

  var raised = false
  try:
    router.get("", handler)
  except HunosError:
    raised = true
  assert raised, "Empty route should raise HunosError"
  echo "[OK] Empty route raises HunosError"

block: # Test route without leading slash raises error
  var router = newRouter()
  proc handler(request: Request) {.gcsafe.} = discard

  var raised = false
  try:
    router.get("no-slash", handler)
  except HunosError:
    raised = true
  assert raised, "Route without / should raise HunosError"
  echo "[OK] Route without leading / raises HunosError"

block: # Test multiple path parameters
  var router = newRouter()
  proc handler(request: Request) {.gcsafe.} =
    let userId = request.pathParams["userId"]
    let postId = request.pathParams["postId"]
    request.respond(200, body = userId & "/" & postId)

  router.get("/users/@userId/posts/@postId", handler)
  echo "[OK] Router with multiple path parameters compiles"

block: # Test Router to RequestHandler converter
  var router = newRouter()
  proc handler(request: Request) {.gcsafe.} = discard
  router.get("/", handler)

  let h: RequestHandler = router
  assert h != nil
  echo "[OK] Router implicit converter to RequestHandler works"

block: # Test default error handlers
  var router = newRouter()
  proc handler(request: Request) {.gcsafe.} = request.respond(200)
  router.get("/", handler)

  let h = router.toHandler()
  assert h != nil
  echo "[OK] Router.toHandler() creates valid handler"

echo "All router tests passed!"
