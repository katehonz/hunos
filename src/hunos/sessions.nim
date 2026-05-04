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

import ../hunos, ../hunos/middleware, std/tables, std/locks, std/times, std/random

type
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
  const chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
  result = newString(32)
  for i in 0 ..< 32:
    result[i] = chars[rand(chars.len - 1)]

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
