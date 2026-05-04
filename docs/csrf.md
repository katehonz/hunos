# CSRF Protection (`hunos/csrf`)

Token-based CSRF middleware for form submissions.

## Usage

```nim
import hunos/csrf

var stack = newMiddlewareStack(router)
stack.use(sessionMiddleware(store))
stack.use(csrfMiddleware())
```

**Requirements:** Session middleware must be installed before CSRF middleware.

## In HTML Forms

```nim
proc formHandler(request: Request) {.gcsafe.} =
  let tokenInput = request.csrfTokenInput()
  # Returns: <input type="hidden" name="csrf_token" value="..." />
  request.respond(200, body = "<form>" & tokenInput & "...</form>")
```

## Validation

Unsafe HTTP methods are automatically protected:
- `POST`
- `PUT`
- `DELETE`
- `PATCH`

Requests without a valid `csrf_token` parameter receive `403 Forbidden`.

## Security Notes

- Tokens are per-session and rotated periodically
- Safe methods (`GET`, `HEAD`, `OPTIONS`) are not validated
- Token is stored in session and validated against form submission
