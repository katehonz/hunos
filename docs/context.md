# Context API (`hunos/context`)

NimMax-style wrapper around Hunos `Request`/`Response` for easier migration and ergonomic handler code.

## Usage

```nim
import hunos/context

proc handler(request: Request) {.gcsafe.} =
  let ctx = newContext(request)
  let id = ctx.getInt("id")
  if id.isSome:
    ctx.json(%*{"id": id.get})
  else:
    ctx.text("Invalid ID", 400)
```

## Typed Parameter Helpers

| Proc | Returns | Description |
|------|---------|-------------|
| `getInt(key, source="path")` | `Option[int]` | Parse int from path param or query |
| `getFloat(key, source="path")` | `Option[float]` | Parse float from path param or query |
| `getBool(key, source="query")` | `Option[bool]` | Parse bool from path param or query |

## Response Helpers

| Proc | Description |
|------|-------------|
| `html(body, code=200)` | Respond with `text/html` |
| `text(body, code=200)` | Respond with `text/plain` |
| `json(data, code=200)` | Respond with `application/json` |
| `redirect(url, code=302)` | Respond with `Location` header |
| `respond(code=200)` | Send response with accumulated headers/body |

## Session & Cookie Helpers

| Proc | Description |
|------|-------------|
| `session()` | Get session attached to request |
| `getCookie(name)` | Read cookie value |
| `setCookie(name, value, ...)` | Set response cookie |

## Body Helpers

| Proc | Returns | Description |
|------|---------|-------------|
| `getJsonBody()` | `JsonNode` | Parse request body as JSON |
| `getJsonBody(T)` | `T` | Parse and convert to type `T` |
