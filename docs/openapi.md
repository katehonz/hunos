# OpenAPI / Swagger (`hunos/openapi`)

Generate OpenAPI 3.0 specifications and serve Swagger UI from your Hunos application.

## Usage

```nim
import hunos/openapi

var spec = newOpenApiSpec(
  title = "My API",
  description = "Example Hunos API",
  version = "1.0.0"
)

spec.addPath("/users", "get", "List users", tags = @["users"])
spec.addParameter("/users", "limit", "query", false, "integer")
spec.addResponse("/users", 200, "OK", "application/json", "UserList")

# Serve Swagger UI at /docs
stack.use(serveDocs(spec, "/docs"))
```

## API Reference

### `newOpenApiSpec(title, description, version)`

Creates a new OpenAPI 3.0 spec object.

### `addPath(spec, path, method, summary, tags)`

Adds an endpoint to the spec.

| Param | Description |
|-------|-------------|
| `path` | URL path (e.g., `/users`) |
| `method` | HTTP method: `get`, `post`, `put`, `delete`, etc. |
| `summary` | Short description |
| `tags` | Categories for grouping |

### `addParameter(path, name, paramIn, required, schema)`

Adds a parameter to an existing path.

| Param | Description |
|-------|-------------|
| `name` | Parameter name |
| `paramIn` | `query`, `path`, `header`, `cookie` |
| `required` | `true` if required |
| `schema` | Type string: `string`, `integer`, `boolean`, etc. |

### `addResponse(path, statusCode, description, contentType, schema)`

Adds a response definition.

### `serveDocs(spec, path="/docs")`

Returns a middleware that serves Swagger UI at the given path.

```nim
stack.use(serveDocs(spec, "/docs"))
# Visit http://localhost:8080/docs to see Swagger UI
```
