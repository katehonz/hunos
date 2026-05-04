# JSON Body Middleware (`hunos/middleware`)

Automatically parses JSON request bodies and attaches them to the request.

## Usage

```nim
import hunos/middleware

var stack = newMiddlewareStack(router)
stack.use(jsonBodyMiddleware())
```

## In Handlers

```nim
import hunos/context

proc apiHandler(request: Request) {.gcsafe.} =
  let ctx = newContext(request)
  let json = ctx.getJsonBody()
  let name = json["name"].getStr()
  ctx.json(%*{"received": name})
```

## Behavior

- Only processes requests with `Content-Type: application/json`
- Invalid JSON → `400 Bad Request`
- Empty body → empty JSON object `{}`
- Parsed JSON is accessible via `getJsonBody()`
