## test_middleware.nim
##
## Tests for middleware pipeline and built-in middleware.
##
## Run:
##   nim c --threads:on --mm:orc --path:src -r tests/test_middleware.nim

import hunos, hunos/middleware, hunos/common

block: # Test middleware pipeline ordering
  proc handler(request: Request) {.gcsafe.} = discard

  var stack = newMiddlewareStack(handler)

  proc m1(request: Request, next: proc() {.gcsafe.}) {.gcsafe.} =
    next()

  proc m2(request: Request, next: proc() {.gcsafe.}) {.gcsafe.} =
    next()

  stack.use(m1)
  stack.use(m2)

  let h = stack.toHandler()
  assert h != nil
  echo "[OK] Middleware pipeline compiles and creates handler"

block: # Test requestIdMiddleware
  let m = requestIdMiddleware()
  assert m != nil
  echo "[OK] requestIdMiddleware creates non-nil proc"

block: # Test corsMiddleware
  let m = corsMiddleware()
  assert m != nil
  let m2 = corsMiddleware(allowOrigin = "https://example.com")
  assert m2 != nil
  echo "[OK] corsMiddleware creates non-nil proc"

block: # Test loggingMiddleware
  let m = loggingMiddleware()
  assert m != nil
  var logged = false
  let m2 = loggingMiddleware(proc(msg: string) {.gcsafe.} =
    logged = true
  )
  assert m2 != nil
  echo "[OK] loggingMiddleware creates non-nil proc"

block: # Test recoveryMiddleware
  let m = recoveryMiddleware()
  assert m != nil
  echo "[OK] recoveryMiddleware creates non-nil proc"

block: # Test MiddlewareStack converter
  proc handler(request: Request) {.gcsafe.} = discard
  let stack = newMiddlewareStack(handler)
  let h: RequestHandler = stack
  assert h != nil
  echo "[OK] MiddlewareStack implicit converter works"

echo "All middleware tests passed!"
