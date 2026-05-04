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

Sessions stored in cryptographically signed cookies (HMAC-SHA256):

```nim
let secret = newSecretKey("my-secret")
let signedStore = newSessionStore()
stack.use(signedCookieMiddleware(secret, signedStore))
```

- Signature verified on every request
- Tampered cookies are rejected → new session created
- Timestamp-based expiration
- Survives server restarts

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
