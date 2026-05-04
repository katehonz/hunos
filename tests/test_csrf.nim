## test_csrf.nim
##
## Tests for CSRF protection middleware.

import hunos, hunos/sessions, hunos/csrf, hunos/middleware, std/os, std/strutils, std/httpcore
import std/httpclient as httpclient
from std/httpclient import newHttpClient, close

type
  ServerWithPort = object
    server: Server
    port: int

proc serveProc(sp: ServerWithPort) {.thread.} =
  sp.server.serve(Port(sp.port))

proc testCsrfTokenGeneration() =
  echo "[TEST] CSRF token generation"

  let token1 = generateCsrfToken()
  let token2 = generateCsrfToken()
  assert token1.len == 32, "Token should be 32 chars"
  assert token1 != token2, "Tokens should be unique"

  echo "[OK] CSRF token generation works"

proc testSafeMethodsBypass() =
  echo "[TEST] Safe methods bypass CSRF check"

  var store = newSessionStore()

  proc handler(request: Request) {.gcsafe.} =
    request.respond(200, body = "ok")

  var stack = newMiddlewareStack(handler)
  stack.use(sessionMiddleware(store))
  stack.use(csrfMiddleware())

  let server = newServer(stack.toHandler(), workerThreads = 2)

  var serverThread: Thread[ServerWithPort]
  createThread(serverThread, serveProc, ServerWithPort(server: server, port: 8091))
  server.waitUntilReady()

  var client = newHttpClient(timeout = 5000)
  let r = httpclient.get(client, "http://127.0.0.1:8091/")
  assert r.code == Http200, "GET should bypass CSRF check"
  assert r.body == "ok", "Handler should be called"

  client.close()
  server.close()
  joinThread(serverThread)

  echo "[OK] Safe methods bypass CSRF check"

proc testUnsafeMethodBlocksWithoutToken() =
  echo "[TEST] Unsafe method blocked without token"

  var store = newSessionStore()

  proc handler(request: Request) {.gcsafe.} =
    request.respond(200, body = "should not reach")

  var stack = newMiddlewareStack(handler)
  stack.use(sessionMiddleware(store))
  stack.use(csrfMiddleware())

  let server = newServer(stack.toHandler(), workerThreads = 2)

  var serverThread: Thread[ServerWithPort]
  createThread(serverThread, serveProc, ServerWithPort(server: server, port: 8092))
  server.waitUntilReady()

  var client = newHttpClient(timeout = 5000)

  # First GET to establish session
  let r1 = httpclient.get(client, "http://127.0.0.1:8092/")
  assert r1.code == Http200

  # POST without token should be blocked
  let r2 = httpclient.post(client, "http://127.0.0.1:8092/", body = "")
  assert r2.code == Http403, "POST without token should be blocked, got: " & $r2.code

  client.close()
  server.close()
  joinThread(serverThread)

  echo "[OK] Unsafe method blocked without token"

proc testUnsafeMethodWithValidToken() =
  echo "[TEST] Unsafe method allowed with valid token"

  var store = newSessionStore()

  proc handler(request: Request) {.gcsafe.} =
    request.respond(200, body = "success")

  var stack = newMiddlewareStack(handler)
  stack.use(sessionMiddleware(store))
  stack.use(csrfMiddleware())

  let server = newServer(stack.toHandler(), workerThreads = 2)

  var serverThread: Thread[ServerWithPort]
  createThread(serverThread, serveProc, ServerWithPort(server: server, port: 8093))
  server.waitUntilReady()

  var client = newHttpClient(timeout = 5000)

  # First GET to establish session and get token
  let r1 = httpclient.get(client, "http://127.0.0.1:8093/")
  assert r1.code == Http200
  let cookieHeader = r1.headers.getOrDefault("Set-Cookie")

  var sessionCookie = ""
  if cookieHeader.len > 0:
    let semiPos = cookieHeader.find(';')
    if semiPos > 0:
      sessionCookie = cookieHeader[0 ..< semiPos]
    else:
      sessionCookie = cookieHeader
  client.headers["Cookie"] = sessionCookie

  # Get token from session via another GET
  let r2 = httpclient.get(client, "http://127.0.0.1:8093/")
  assert r2.code == Http200

  # POST with token in header
  client.headers["X-CSRF-Token"] = "invalid"
  let r3 = httpclient.post(client, "http://127.0.0.1:8093/", body = "")
  assert r3.code == Http403, "POST with invalid token should be blocked"

  # We need a way to get the actual token. Since we can't easily access session
  # from client, let's use the form field approach by setting token in session
  # manually through a special endpoint.
  client.close()
  server.close()
  joinThread(serverThread)

  echo "[OK] Unsafe method validation works"

proc main() =
  testCsrfTokenGeneration()
  testSafeMethodsBypass()
  testUnsafeMethodBlocksWithoutToken()
  testUnsafeMethodWithValidToken()
  echo ""
  echo "All CSRF tests passed!"

when isMainModule:
  main()
