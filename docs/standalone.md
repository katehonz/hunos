# Using Hunos as a Standalone HTTP Server

Hunos is a **standalone, general-purpose HTTP/1.1, HTTP/2 and WebSocket server** for Nim. While it serves as the default backend for NimMax, it is designed to be used independently in any project that needs a high-performance multi-threaded web server.

---

## Who Should Use Hunos Directly?

| Use Case | Recommendation |
|----------|---------------|
| You want a **fast, multi-threaded HTTP server** without async/await complexity | ✅ Use Hunos directly |
| You need **WebSocket support** with thread-safe broadcasting | ✅ Use Hunos directly |
| You want **zero runtime dependencies** (stdlib only, optional zippy) | ✅ Use Hunos directly |
| You are building a **microservice or API gateway** | ✅ Use Hunos directly |
| You need **NimMax's template engine, ORM, or admin panel** | Use NimMax (which uses Hunos underneath) |
| You prefer **async/await** style handlers | Use `asynchttpserver` or `httpbeast` |

---

## Architecture Independence

Hunos does **not** depend on NimMax. The reverse is true: NimMax is a framework layer that optionally runs on top of Hunos.

```
┌─────────────────────────────────────────┐
│  NimMax Framework (optional)            │
│  - Templates, ORM, Admin, Validation    │
├─────────────────────────────────────────┤
│  Hunos Server (standalone)              │
│  - HTTP/1.1, HTTP/2, WebSocket          │
│  - Router, Middleware, Sessions         │
│  - Static files, Rate limiting          │
├─────────────────────────────────────────┤
│  stdlib + zippy (optional)              │
└─────────────────────────────────────────┘
```

---

## Minimal Example (Zero Framework)

```nim
import hunos

proc handler(request: Request) =
  var headers: HttpHeaders
  headers["Content-Type"] = "text/plain"
  request.respond(200, headers, "Hello, World!")

let server = newServer(handler)
server.serve(Port(8080))
```

Compile and run:

```bash
nim c --threads:on --mm:orc -d:release -r server.nim
```

---

## When to Choose Hunos Over Alternatives

| Server | Threading | Dependencies | Best For |
|--------|-----------|--------------|----------|
| **Hunos** | Multi-threaded pool | stdlib + optional zippy | CPU-heavy APIs, WebSockets, microservices |
| Mummy | Multi-threaded pool | zippy required | Compatibility with Mummy ecosystem |
| httpbeast | Multi-threaded pool | None | Raw speed, minimal features |
| AsyncHttpServer | Single-threaded async | stdlib only | Simple apps, async I/O |
| Jester | Single-threaded async | stdlib + regex | Small apps, routing convenience |

---

## Standalone Modules Reference

All modules work independently without NimMax:

| Module | Purpose | Standalone Use |
|--------|---------|---------------|
| `hunos` | Core server | Always standalone |
| `hunos/router` | Trie routing | Always standalone |
| `hunos/middleware` | Pipeline middleware | Always standalone |
| `hunos/sessions` | Session store | Always standalone |
| `hunos/csrf` | CSRF tokens | Always standalone |
| `hunos/validation` | Form validators | Always standalone |
| `hunos/testing` | Test helpers | Always standalone |
| `hunos/openapi` | API documentation | Always standalone |
| `hunos/staticfiles` | File serving | Always standalone |
| `hunos/ratelimit` | Rate limiting | Always standalone |
| `hunos/multipart` | File uploads | Always standalone |
| `hunos/context` | Context wrapper | **Also standalone** — not NimMax-specific |

The `context` module provides a convenient wrapper around raw `Request` objects. It was inspired by NimMax's API design, but is **not coupled to NimMax** in any way. You can use `hunos/context` in pure Hunos projects without importing anything from NimMax.

---

## Migrating From Other Servers

### From AsyncHttpServer

```nim
# Before (async)
proc handler(req: Request) {.async.} =
  await req.respond(Http200, "Hello")

# After (Hunos — sync, multi-threaded)
proc handler(req: Request) =
  req.respond(200, body = "Hello")
```

Key differences:
- Handlers are **synchronous** (`{.gcsafe.}` instead of `{.async.}`)
- No `await` needed — responses are sent immediately
- Multiple requests run **in parallel** across worker threads

### From Mummy

Hunos is API-compatible with Mummy for basic usage. The router and middleware systems are enhanced but follow similar patterns.

---

## Production Checklist

When running Hunos standalone in production:

- [ ] Compile with `-d:release --threads:on --mm:orc`
- [ ] Set appropriate `workerThreads` (default: `max(countProcessors() * 10, 1)`)
- [ ] Use `recoveryMiddleware()` to catch panics
- [ ] Add `loggingMiddleware()` for request logging
- [ ] Use `corsMiddleware()` for cross-origin APIs
- [ ] Enable ` RateLimiter` for public endpoints
- [ ] Set `maxBodyLen` and `maxHeadersLen` to reasonable limits
- [ ] Put a reverse proxy (nginx, Caddy, traefik) in front for TLS termination

---

## Getting Help

- **Bug reports & features**: [GitHub Issues](https://github.com/katehonz/hunos/issues)
- **Documentation**: See `docs/` directory and `README.md`
- **Examples**: See `examples/` directory
