# Testing Utilities (`hunos/testing`)

Test HTTP handlers without running a real server or making network requests.

## Usage

```nim
import hunos/testing

let server = mockServer()
let response = server.runOnce("GET", "/api")
assert response.code == 200
assert response.body == "..."
```

## API Reference

### `mockServer()`

Creates a server instance without binding to a socket. Useful for testing handlers in isolation.

```nim
let server = mockServer()
```

### `runOnce()`

Executes a handler synchronously and returns the response.

```nim
let response = server.runOnce(
  method = "POST",
  path = "/users",
  body = """{"name":"Alice"}""",
  headers = @[("Content-Type", "application/json")]
)
```

### `debugResponse()`

Pretty-prints a response for debugging test failures.

```nim
echo debugResponse(response)
# Output:
# Status: 200 OK
# Headers:
#   Content-Type: application/json
# Body:
#   {"message":"Hello"}
```

## Example: Testing JSON API

```nim
import hunos/testing

proc apiHandler(request: Request) {.gcsafe.} =
  request.respond(200, @[("Content-Type", "application/json")], "{\"ok\":true}")

let server = mockServer()
server.handler = apiHandler
let resp = server.runOnce("GET", "/api")
assert resp.code == 200
assert resp.body == """{"ok":true}"""
```
