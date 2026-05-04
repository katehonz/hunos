## test_sessions.nim
##
## Tests for session management.

import hunos, hunos/sessions, hunos/middleware, std/os, std/strutils
import std/httpclient as httpclient
from std/httpclient import newHttpClient, close

type
  ServerWithPort = object
    server: Server
    port: int

proc serveProc(sp: ServerWithPort) {.thread.} =
  sp.server.serve(Port(sp.port))

proc testBasicSession() =
  echo "[TEST] Basic session create/get/set"

  var store = newSessionStore(maxAge = 3600)
  var sess = store.newSession()
  assert sess.id.len == 32, "Session ID should be 32 chars"

  sess.set("user", "alice")
  assert sess.get("user") == "alice", "Session set/get failed"

  sess.del("user")
  assert sess.get("user") == "", "Session del failed"

  store.put(sess)
  let retrieved = store.get(sess.id)
  assert retrieved != nil, "Store put/get failed"
  assert retrieved.get("user") == "", "Retrieved session should not have deleted key"

  retrieved.set("role", "admin")
  store.put(retrieved)

  let again = store.get(sess.id)
  assert again.get("role") == "admin", "Store update failed"

  echo "[OK] Basic session operations work"

proc testSessionExpiration() =
  echo "[TEST] Session expiration"

  var store = newSessionStore(maxAge = 1)
  var sess = store.newSession()
  sess.set("data", "important")
  store.put(sess)

  assert store.get(sess.id) != nil, "Session should exist"
  sleep(1100)
  assert store.get(sess.id) == nil, "Session should be expired"

  echo "[OK] Session expiration works"

proc testSessionCleanup() =
  echo "[TEST] Session cleanup"

  var store = newSessionStore(maxAge = 1)
  var ids: seq[string] = @[]
  for i in 0 ..< 5:
    var s = store.newSession()
    store.put(s)
    ids.add(s.id)

  sleep(1100)
  store.cleanup()

  for id in ids:
    assert store.get(id) == nil, "Cleanup should remove expired session"

  echo "[OK] Session cleanup works"

proc testSessionMiddleware() =
  echo "[TEST] Session middleware integration"

  var store = newSessionStore(maxAge = 3600)

  proc handler(request: Request) {.gcsafe.} =
    let sess = request.getSession()
    if sess == nil:
      request.respond(500, body = "no session")
      return

    let counterStr = sess.get("counter")
    var counter = 0
    if counterStr.len > 0:
      counter = parseInt(counterStr)
    counter += 1
    sess.set("counter", $counter)

    request.respond(200, body = $counter)

  var stack = newMiddlewareStack(handler)
  stack.use(sessionMiddleware(store))

  let server = newServer(stack.toHandler(), workerThreads = 2)

  var serverThread: Thread[ServerWithPort]
  createThread(serverThread, serveProc, ServerWithPort(server: server, port: 8090))
  server.waitUntilReady()

  var client = newHttpClient(timeout = 5000)

  # First request — should set cookie
  let r1 = httpclient.get(client, "http://127.0.0.1:8090/")
  let resp1 = r1.body
  let cookieHeader = r1.headers.getOrDefault("Set-Cookie")
  assert resp1 == "1", "First request should return 1, got: " & resp1

  # Extract cookie value for subsequent requests
  var sessionCookie = ""
  if cookieHeader.len > 0:
    let semiPos = cookieHeader.find(';')
    if semiPos > 0:
      sessionCookie = cookieHeader[0 ..< semiPos]
    else:
      sessionCookie = cookieHeader

  # Second request — send cookie manually
  client.headers["Cookie"] = sessionCookie
  let r2 = httpclient.get(client, "http://127.0.0.1:8090/")
  let resp2 = r2.body
  assert resp2 == "2", "Second request should return 2, got: " & resp2

  # Third request
  client.headers["Cookie"] = sessionCookie
  let r3 = httpclient.get(client, "http://127.0.0.1:8090/")
  let resp3 = r3.body
  assert resp3 == "3", "Third request should return 3, got: " & resp3

  client.close()
  server.close()
  joinThread(serverThread)

  echo "[OK] Session middleware integration works"

proc main() =
  testBasicSession()
  testSessionExpiration()
  testSessionCleanup()
  testSessionMiddleware()
  echo ""
  echo "All session tests passed!"

when isMainModule:
  main()
