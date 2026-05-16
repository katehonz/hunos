# Hunos Documentation

Hunos is a **standalone, high-performance, multi-threaded HTTP/1.1, HTTP/2 and WebSocket server** for Nim. It can be used independently or as a backend for higher-level frameworks like NimMax.

---

## Getting Started

- [Using Hunos Standalone](standalone.md) — when and how to use Hunos without any framework
- [README](../README.md) — installation, quick start, API reference, benchmarks
- [CHANGELOG](../CHANGELOG.md) — version history and release notes

---

## Module Reference

| Module | Description | Import |
|--------|-------------|--------|
| [Context API](context.md) | Typed parameter helpers and ergonomic response methods | `hunos/context` |
| [Sessions](sessions.md) | Thread-safe in-memory sessions + flash messages + signed cookies | `hunos/sessions` |
| [CSRF Protection](csrf.md) | Token-based CSRF middleware for HTML forms | `hunos/csrf` |
| [Form Validation](validation.md) | 15+ form validators with `Option[T]` return | `hunos/validation` |
| [Testing Utilities](testing.md) | `mockServer()`, `runOnce()`, `debugResponse()` | `hunos/testing` |
| [OpenAPI / Swagger](openapi.md) | OpenAPI 3.0 spec generator with Swagger UI | `hunos/openapi` |
| [HTTP/2](h2.md) | Experimental h2c support | `hunos/h2` |
| [Basic Auth](auth.md) | HTTP Basic Authentication middleware | `hunos/middleware` |
| [JSON Body](jsonbody.md) | Automatic JSON body parsing middleware | `hunos/middleware` |

---

## Architecture

```
┌─────────────────────────────────────────┐
│  Your Application                       │
│  - Handlers, Router, Middleware         │
├─────────────────────────────────────────┤
│  Hunos Server (standalone)              │
│  - HTTP/1.1, HTTP/2, WebSocket          │
│  - Trie router, Middleware pipeline     │
│  - Sessions, Static files, Rate limit   │
├─────────────────────────────────────────┤
│  stdlib + zippy (optional)              │
└─────────────────────────────────────────┘
```

---

## Project Links

- [CODE_REVIEW.md](../CODE_REVIEW.md) — known issues and fixes
- [ROADMAP_NIMMAX_INTEGRATION.md](../ROADMAP_NIMMAX_INTEGRATION.md) — NimMax integration history
- [HUNOS_DEFICIENCIES.md](../HUNOS_DEFICIENCIES.md) — resolved migration issues (archived)
