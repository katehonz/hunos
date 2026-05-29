## sessions.nim
##
## Thread-safe in-memory session management for Hunos.
## Provides session middleware and helper API for handlers.
##
## Usage:
##   import hunos/sessions
##
##   var store = newSessionStore(maxAge = 3600)
##   stack.use(sessionMiddleware(store))
##
##   proc handler(request: Request) =
##     let sess = request.getSession()
##     sess.set("user", "alice")
##     let user = sess.get("user")
##     request.respond(200, body = "Hello " & user)

import ../hunos, ../hunos/middleware, std/tables, std/locks, std/times, std/json, std/base64, std/strutils, std/sysrand
import checksums/sha2

type
  FlashLevel* = enum
    flInfo = "info"
    flSuccess = "success"
    flWarning = "warning"
    flError = "error"

  Session* = ref object
    id*: string
    data*: Table[string, string]
    modified*: bool
    accessed*: bool
    createdAt*: float64

  SessionStore* = ref object
    sessions: Table[string, Session]
    lock: Lock
    maxAge*: int  # seconds

proc generateSessionId(): string =
  let bytes = urandom(16)
  const hexChars = "0123456789abcdef"
  result = newString(32)
  for i in 0 ..< 16:
    result[i * 2]     = hexChars[(bytes[i] shr 4) and 0x0F]
    result[i * 2 + 1] = hexChars[bytes[i] and 0x0F]

proc newSessionStore*(maxAge: int = 86400): SessionStore =
  new(result)
  result.sessions = initTable[string, Session]()
  result.maxAge = maxAge
  initLock(result.lock)

proc newSession*(store: SessionStore): Session =
  result = Session(
    id: generateSessionId(),
    data: initTable[string, string](),
    modified: false,
    accessed: false,
    createdAt: epochTime()
  )

proc get*(store: SessionStore, id: string): Session =
  withLock store.lock:
    if id in store.sessions:
      let sess = store.sessions[id]
      let now = epochTime()
      if now - sess.createdAt > float(store.maxAge):
        store.sessions.del(id)
        return nil
      sess.accessed = true
      return sess
    return nil

proc put*(store: SessionStore, session: Session) =
  withLock store.lock:
    store.sessions[session.id] = session

proc delete*(store: SessionStore, id: string) =
  withLock store.lock:
    if id in store.sessions:
      store.sessions.del(id)

proc cleanup*(store: SessionStore) =
  let now = epochTime()
  withLock store.lock:
    var toDelete: seq[string] = @[]
    for id, sess in store.sessions:
      if now - sess.createdAt > float(store.maxAge):
        toDelete.add(id)
    for id in toDelete:
      store.sessions.del(id)

# Session helpers
proc get*(session: Session, key: string): string =
  session.accessed = true
  session.data.getOrDefault(key, "")

proc set*(session: Session, key, value: string) =
  session.accessed = true
  session.modified = true
  session.data[key] = value

proc del*(session: Session, key: string) =
  session.accessed = true
  session.modified = true
  session.data.del(key)

proc clear*(session: Session) =
  session.accessed = true
  session.modified = true
  session.data.clear()

proc hasKey*(session: Session, key: string): bool =
  session.accessed = true
  session.data.hasKey(key)

proc len*(session: Session): int =
  session.data.len

proc flash*(session: Session, message: string, level: FlashLevel = flInfo) =
  session.accessed = true
  session.modified = true
  session.data["_flash_" & $level] = message

proc getFlashedMsgs*(session: Session): seq[(FlashLevel, string)] =
  result = @[]
  for level in FlashLevel:
    let key = "_flash_" & $level
    if key in session.data:
      result.add((level, session.data[key]))
      session.data.del(key)
      session.modified = true
  session.accessed = true

proc getFlashedMsgsWithCategory*(session: Session): seq[(string, string)] =
  result = @[]
  for level in FlashLevel:
    let key = "_flash_" & $level
    if key in session.data:
      result.add(($level, session.data[key]))
      session.data.del(key)
      session.modified = true
  session.accessed = true

# Request helpers
proc getSession*(request: Request): Session =
  if request.userData != nil:
    result = cast[Session](request.userData)

proc getCookieValue(request: Request, name: string): string =
  let cookieHeader = request.headers["Cookie"]
  if cookieHeader.len == 0:
    return ""
  var i = 0
  while i < cookieHeader.len:
    var start = i
    while i < cookieHeader.len and cookieHeader[i] == ' ':
      inc i
    start = i
    while i < cookieHeader.len and cookieHeader[i] != ';':
      inc i
    var pairLen = i - start
    while pairLen > 0 and cookieHeader[start + pairLen - 1] == ' ':
      dec pairLen
    if pairLen > name.len + 1 and cookieHeader[start ..< start + name.len] == name and
       cookieHeader[start + name.len] == '=':
      return cookieHeader[start + name.len + 1 ..< start + pairLen]
    if i < cookieHeader.len and cookieHeader[i] == ';':
      inc i
  return ""

proc sessionMiddleware*(
  store: SessionStore,
  cookieName: string = "hunos_session",
  maxAge: int = 86400,
  httpOnly: bool = true,
  secure: bool = false,
  sameSite: string = "Lax"
): MiddlewareProc =
  return proc(request: Request, next: proc() {.gcsafe.}) {.gcsafe.} =
    let sessionId = getCookieValue(request, cookieName)
    var session: Session

    if sessionId.len > 0:
      session = store.get(sessionId)

    if session == nil:
      session = store.newSession()
      session.modified = true

    request.userData = cast[pointer](session)

    # Set cookie BEFORE next() so it is included even if handler calls respond()
    var cookie = cookieName & "=" & session.id
    if maxAge > 0:
      cookie &= "; Max-Age=" & $maxAge
    if httpOnly:
      cookie &= "; HttpOnly"
    if secure:
      cookie &= "; Secure"
    if sameSite.len > 0:
      cookie &= "; SameSite=" & sameSite
    request.responseHeaders.add(("Set-Cookie", cookie))

    next()

    if session.modified:
      store.put(session)

type
  SignedCookieSecretKey* = object
    key: string

proc newSecretKey*(key: string): SignedCookieSecretKey =
  if key.len == 0:
    raise newException(ValueError, "Secret key must not be empty")
  result.key = key

proc newRandomSecretKey*(): SignedCookieSecretKey =
  let bytes = urandom(48)
  result.key = encode(bytes)

proc hmacSha256(key, message: string): string =
  const blockSize = 64
  var blockKey = if key.len > blockSize:
    var hasher = initSha_256()
    hasher.update(key)
    $hasher.digest()
  else:
    key

  var ipad = newString(blockSize)
  var opad = newString(blockSize)
  for i in 0 ..< blockSize:
    ipad[i] = if i < blockKey.len: chr(ord(blockKey[i]) xor 0x36) else: chr(0x36)
    opad[i] = if i < blockKey.len: chr(ord(blockKey[i]) xor 0x5C) else: chr(0x5C)

  var inner = initSha_256()
  inner.update(ipad)
  inner.update(message)
  let innerHash = $inner.digest()

  var outer = initSha_256()
  outer.update(opad)
  outer.update(innerHash)
  result = $outer.digest()

proc base64urlEncode(data: string): string =
  result = encode(data).replace("+", "-").replace("/", "_").replace("=", "")

proc base64urlDecode(data: string): string =
  var padded = data.replace("-", "+").replace("_", "/")
  while padded.len mod 4 != 0:
    padded &= "="
  result = decode(padded)

proc encodeSignedCookie*(secretKey: SignedCookieSecretKey, data: Table[string, string], timestamp: float64): string =
  let jsonData = $(%* data)
  let payload = jsonData & "." & $timestamp
  let signature = hmacSha256(secretKey.key, payload)
  result = base64urlEncode(jsonData) & "." & base64urlEncode($timestamp) & "." & base64urlEncode(signature)

proc decodeSignedCookie*(secretKey: SignedCookieSecretKey, cookieValue: string): (Table[string, string], float64) =
  let parts = cookieValue.split('.')
  if parts.len != 3:
    return

  try:
    let jsonData = base64urlDecode(parts[0])
    let timestamp = parseFloat(base64urlDecode(parts[1]))
    let signature = base64urlDecode(parts[2])

    let payload = jsonData & "." & $timestamp
    let expectedSig = hmacSha256(secretKey.key, payload)
    if signature != expectedSig:
      return

    let parsed = parseJson(jsonData)
    if parsed.kind != JObject:
      return

    var data: Table[string, string]
    for key, val in parsed:
      if val.kind == JString:
        data[key] = val.getStr()
      else:
        data[key] = $val

    result = (data, timestamp)
  except CatchableError:
    discard

proc signedCookieMiddleware*(
  secretKey: SignedCookieSecretKey,
  cookieName: string = "hunos_session",
  maxAge: int = 86400,
  httpOnly: bool = true,
  secure: bool = false,
  sameSite: string = "Lax"
): MiddlewareProc =
  return proc(request: Request, next: proc() {.gcsafe.}) {.gcsafe.} =
    var session = Session(
      id: generateSessionId(),
      data: initTable[string, string](),
      modified: false,
      accessed: false,
      createdAt: epochTime()
    )

    let cookieValue = getCookieValue(request, cookieName)
    if cookieValue.len > 0:
      let (data, timestamp) = decodeSignedCookie(secretKey, cookieValue)
      if data.len > 0:
        session.data = data
        session.createdAt = timestamp
        session.id = "signed:" & $timestamp

    request.userData = cast[pointer](session)

    next()

    let now = epochTime()
    let signedValue = encodeSignedCookie(secretKey, session.data, now)
    var cookie = cookieName & "=" & signedValue
    if maxAge > 0:
      cookie &= "; Max-Age=" & $maxAge
    if httpOnly:
      cookie &= "; HttpOnly"
    if secure:
      cookie &= "; Secure"
    if sameSite.len > 0:
      cookie &= "; SameSite=" & sameSite

    for i in countdown(request.responseHeaders.len - 1, 0):
      let (k, _) = request.responseHeaders[i]
      if k == "Set-Cookie":
        request.responseHeaders.delete(i)

    request.responseHeaders.add(("Set-Cookie", cookie))

    if not request.responded:
      var body = "OK"
      if session.data.hasKey("_response_body"):
        body = session.data["_response_body"]
        session.data.del("_response_body")
      request.respond(200, body = body)
