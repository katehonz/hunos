# Sessions (`hunos/sessions`)

Thread-safe session management with in-memory and signed-cookie backends.

## In-Memory Sessions

```nim
import hunos, hunos/sessions

var store = newSessionStore(maxAge = 3600)

proc handler(request: Request) {.gcsafe.} =
  let session = request.getSession()
  session.set("user", "alice")
  let user = session.get("user")
  request.respond(200, body = "Hello, " & user)

var stack = newMiddlewareStack(router)
stack.use(sessionMiddleware(store))
```

## Flash Messages

One-time read messages that auto-clear after retrieval:

```nim
session.flash("Welcome back!", flSuccess)
let msgs = session.getFlashedMsgs()  # seq[(FlashLevel, string)]
# Messages are deleted after reading
```

Flash levels: `flInfo`, `flWarning`, `flError`, `flSuccess`.

## Signed Cookie Backend

Sessions stored in cryptographically signed cookies (HMAC-SHA256, RFC 2104):

```nim
let secret = newSecretKey("my-secret")
# or: let secret = newRandomSecretKey()
stack.use(signedCookieMiddleware(secret, maxAge = 3600))
```

- Signature verified on every request with constant-time compare
- Tampered cookies are rejected → new session created
- **Server-side** maxAge enforcement (not only browser `Max-Age`)
- Survives server restarts (no server-side store needed)

> **Note (v1.3.4):** cookies issued by ≤1.3.3 used a non-standard hex HMAC and will not verify after upgrade; clients simply get a fresh session.

## SessionStore API

| Proc | Description |
|------|-------------|
| `newSessionStore(maxAge=86400)` | Create in-memory store |
| `store.get(id)` | Get or create session |
| `store.put(session)` | Store session |
| `store.delete(id)` | Remove session |
| `store.cleanup()` | Remove expired sessions |

## Session API

| Proc | Description |
|------|-------------|
| `session.set(key, value)` | Store string value |
| `session.get(key)` | Retrieve string value |
| `session.delete(key)` | Remove key |
| `session.flash(msg, level)` | Add flash message |
| `session.getFlashedMsgs()` | Read and clear flashes |
| `session.getFlashedMsgsWithCategory()` | Read with custom categories |
