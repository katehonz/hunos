## test_sessions.nim
##
## Tests for session management.

import hunos, hunos/sessions, hunos/middleware, std/os, std/strutils, std/tables
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
  createThread(serverThread, serveProc, ServerWithPort(server: server, port: 18090))
  server.waitUntilReady()

  var client = newHttpClient(timeout = 5000)

  # First request — should set cookie
  let r1 = httpclient.get(client, "http://127.0.0.1:18090/")
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
  let r2 = httpclient.get(client, "http://127.0.0.1:18090/")
  let resp2 = r2.body
  assert resp2 == "2", "Second request should return 2, got: " & resp2

  # Third request
  client.headers["Cookie"] = sessionCookie
  let r3 = httpclient.get(client, "http://127.0.0.1:18090/")
  let resp3 = r3.body
  assert resp3 == "3", "Third request should return 3, got: " & resp3

  client.close()
  server.close()
  joinThread(serverThread)

  echo "[OK] Session middleware integration works"

proc testFlashMessages() =
  echo "[TEST] Flash messages"

  var store = newSessionStore(maxAge = 3600)
  var sess = store.newSession()

  sess.flash("Welcome!", flInfo)
  sess.flash("Operation completed", flSuccess)
  sess.flash("Be careful", flWarning)
  sess.flash("Something went wrong", flError)

  let msgs = sess.getFlashedMsgs()
  assert msgs.len == 4, "Should have 4 flash messages, got: " & $msgs.len

  assert msgs[0][0] == flInfo, "First should be info"
  assert msgs[0][1] == "Welcome!"
  assert msgs[1][0] == flSuccess, "Second should be success"
  assert msgs[1][1] == "Operation completed"
  assert msgs[2][0] == flWarning, "Third should be warning"
  assert msgs[3][0] == flError, "Fourth should be error"

  let msgs2 = sess.getFlashedMsgs()
  assert msgs2.len == 0, "Flash messages should be cleared after reading, got: " & $msgs2.len

  echo "[OK] Flash messages work correctly"

proc testSignedCookieSession() =
  echo "[TEST] Signed cookie encode/decode"

  let secretKey = newSecretKey("my-secret-key-for-testing")

  var data: Table[string, string]
  data["user"] = "alice"
  data["role"] = "admin"

  let ts = 1714800000.0
  let encoded = encodeSignedCookie(secretKey, data, ts)
  assert encoded.len > 0, "Encoded cookie should not be empty"

  let (decoded, timestamp) = decodeSignedCookie(secretKey, encoded)
  assert decoded.len == 2, "Should have 2 fields, got: " & $decoded.len
  assert decoded["user"] == "alice"
  assert decoded["role"] == "admin"
  assert timestamp == ts

  echo "[OK] Signed cookie encode/decode works"

  echo "[TEST] Signed cookie tamper detection"

  let badKey = newSecretKey("different-key-for-testing")
  let (badDecode, _) = decodeSignedCookie(badKey, encoded)
  assert badDecode.len == 0, "Tampered cookie should fail decode"

  echo "[OK] Tampered cookie rejected"

  echo "[TEST] Signed cookie invalid format"

  let (invalid, _) = decodeSignedCookie(secretKey, "not-a-valid-cookie")
  assert invalid.len == 0, "Invalid format should return empty"

  echo "[OK] Invalid format rejected"

proc testSignedCookieMiddleware() =
  echo "[TEST] Signed cookie middleware integration"

  let secretKey = newSecretKey("integration-test-secret-key")

  proc handler(request: Request) {.gcsafe.} =
    let sess = request.getSession()
    if sess == nil:
      if not request.responded:
        request.respond(500, body = "no session")
      return

    let counterStr = sess.get("counter")
    var counter = 0
    if counterStr.len > 0:
      try:
        counter = parseInt(counterStr)
      except ValueError:
        counter = 0
    counter += 1
    sess.set("counter", $counter)
    sess.set("_response_body", $counter)

  var stack = newMiddlewareStack(handler)
  stack.use(signedCookieMiddleware(secretKey, maxAge = 3600))

  let server = newServer(stack.toHandler(), workerThreads = 2)

  var serverThread: Thread[ServerWithPort]
  createThread(serverThread, serveProc, ServerWithPort(server: server, port: 18091))
  server.waitUntilReady()

  var client = newHttpClient(timeout = 5000)

  let r1 = httpclient.get(client, "http://127.0.0.1:18091/")
  let resp1 = r1.body
  let cookieHeader = r1.headers.getOrDefault("Set-Cookie")
  assert resp1 == "1", "First request should return 1, got: " & resp1

  var sessionCookie = ""
  if cookieHeader.len > 0:
    let semiPos = cookieHeader.find(';')
    if semiPos > 0:
      sessionCookie = cookieHeader[0 ..< semiPos]
    else:
      sessionCookie = cookieHeader
  assert sessionCookie.len > 0, "Should have session cookie"

  # Second request with cookie from first response
  client.headers["Cookie"] = sessionCookie
  let r2 = httpclient.get(client, "http://127.0.0.1:18091/")
  let resp2 = r2.body
  assert resp2 == "2", "Second request should return 2, got: " & resp2

  # Extract updated cookie from second response
  let cookieHeader2 = r2.headers.getOrDefault("Set-Cookie")
  if cookieHeader2.len > 0:
    let semiPos = cookieHeader2.find(';')
    if semiPos > 0:
      sessionCookie = cookieHeader2[0 ..< semiPos]
    else:
      sessionCookie = cookieHeader2

  # Third request with updated cookie
  client.headers["Cookie"] = sessionCookie
  let r3 = httpclient.get(client, "http://127.0.0.1:18091/")
  let resp3 = r3.body
  assert resp3 == "3", "Third request should return 3, got: " & resp3

  echo "[OK] Signed cookie middleware works (counter: 1 → 2 → 3)"

  echo "[TEST] Tampered cookie rejected by middleware"
  client.headers["Cookie"] = sessionCookie & "tampered"
  let r4 = httpclient.get(client, "http://127.0.0.1:18091/")
  let resp4 = r4.body
  assert resp4 == "1", "Tampered cookie should start fresh, got: " & resp4

  echo "[OK] Tampered cookie restarts session"

  client.close()
  server.close()
  joinThread(serverThread)

  echo "[OK] Signed cookie middleware tests passed"

proc main() =
  testBasicSession()
  testSessionExpiration()
  testSessionCleanup()
  testSessionMiddleware()
  testFlashMessages()
  testSignedCookieSession()
  testSignedCookieMiddleware()
  echo ""
  echo "All session tests passed!"

when isMainModule:
  main()
