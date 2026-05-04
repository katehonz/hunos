# Basic Auth (`hunos/middleware`)

HTTP Basic Authentication middleware.

## Usage

```nim
import hunos/middleware

proc verifyUser(username, password: string): bool {.gcsafe.} =
  username == "admin" and password == "secret"

var stack = newMiddlewareStack(router)
stack.use(basicAuthMiddleware("Secure Area", verifyUser))
```

## Behavior

- Missing `Authorization` header → `401` with `WWW-Authenticate: Basic realm="..."`
- Invalid credentials → `401`
- Valid credentials → request proceeds

## Custom Verify Handler

```nim
type VerifyHandler* = proc(username, password: string): bool {.gcsafe.}

proc basicAuthMiddleware*(realm: string, verifyHandler: VerifyHandler): MiddlewareProc
```

The verify handler must be `{.gcsafe.}` since it runs on worker threads.
