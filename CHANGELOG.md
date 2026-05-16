# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [1.3.0] - 2026-05-16

### Added

- **NimMax-style Context API** (`hunos/context`) — typed parameter helpers (`getInt`, `getFloat`, `getBool`) and ergonomic response methods (`json`, `html`, `text`, `redirect`).
- **Session management** (`hunos/sessions`) — thread-safe in-memory session store with flash messages and signed-cookie backend (HMAC-SHA256).
- **CSRF protection** (`hunos/csrf`) — token middleware with `csrfTokenInput()` helper for HTML forms.
- **Form validation** (`hunos/validation`) — 15+ validators: `required`, `isEmail`, `isInt`, `isFloat`, `minLength`, `maxLength`, `minValue`, `maxValue`, `matchPattern`, `oneOf`, `isAlpha`, `isAlphanumeric`, `isHex`, `isUUID`, `isDate`, `isIP`.
- **Testing utilities** (`hunos/testing`) — `mockServer()`, `runOnce()`, `debugResponse()` for unit testing handlers without a live server.
- **OpenAPI / Swagger** (`hunos/openapi`) — spec generator with built-in Swagger UI middleware (`serveDocs`).
- **HTTP/2 (h2c)** (`hunos/h2`) — frame parser, HPACK header compression, stream multiplexing, and server push (experimental).
- **Basic auth middleware** (`hunos/middleware`) — `basicAuthMiddleware()` with custom verify handler.
- **JSON body middleware** (`hunos/middleware`) — automatic JSON parsing with `getJsonBody()`.
- **Compression** (`hunos/compress`) — gzip/deflate auto-compression for responses > 860 bytes (optional, disable with `-d:hunosNoCompression`).
- **Static files v2** (`hunos/staticfiles`) — ETag, Range requests, `If-None-Match`, `If-Modified-Since`, URL decoding, and directory traversal protection.
- **Graceful shutdown** — `shutdown(server, timeout)` with connection draining.
- **Cookie API** — `getCookie()` and `setCookie()` for request/response cookie handling.
- **Typed path parameters** — `getInt`, `getFloat`, `getBool` in `hunos/common` returning `Option[T]`.
- **Response object** — `Response` type with `respond(request, response)` overload.
- **`request.userData`** — `pointer` field for middleware-attached data.

### Changed

- **Router algorithm** — switched from linear scan to trie-based O(k) matching where k = path segments.
- **Partial wildcards** — `*` now supports prefix (`page_*`), suffix (`*.json`), and contains (`*something*`) patterns.
- **Rate limiter** — in-place filtering with automatic cleanup every 10k requests; added `close()` for lock cleanup.
- **Request ID generation** — replaced predictable memory-address based IDs with atomic counter.
- **`encodeHeaders`** — now respects client HTTP version (`HTTP/1.0` vs `HTTP/1.1`).
- **CORS middleware** — fixed to modify `responseHeaders` instead of request headers.
- **`loggingMiddleware`** — uses `WarnLevel` for requests taking longer than 1 second.
- **`base64Encode`** — now generic for any byte sequence, not just SHA1 output.
- **`strictParseHex`** — fixed to accept valid hex with leading zeros (e.g., `0a`).

### Fixed

- **SIGSEGV in `bench_scaling`** — stable at 16/32 workers under ORC after fixing race condition in server destroy.
- **WebSocket `encodeFrameHeader`** — replaced `assert` with runtime masking to prevent corrupt frames in release builds.
- **Directory traversal bypass** — URL-encoded `%2e%2e` sequences are now decoded before security checks in static file serving.
- **`requestIdMiddleware`** — now sets `X-Request-Id` on both request headers (for handlers) and response headers (for client).
- **`test_core.nim`** — fixed uninitialized Router (`var router = newRouter()` instead of `var router: Router`).
- **Nim 2.2.10 compatibility** — fixed `parseUrl` tuple parsing, added missing `std/bitops` and `split` imports, renamed `block` keyword variable to `chunk`.

---

## [1.2.0] - 2026-04-20

### Added

- Trie-based router with named parameters (`@id`) and multi-segment wildcards (`**`).
- Middleware pipeline with `corsMiddleware`, `loggingMiddleware`, `requestIdMiddleware`, `recoveryMiddleware`.
- WebSocket support with thread-safe `send()` and `close()`.
- Rate limiter with sliding-window algorithm.
- Static file serving with MIME detection and directory traversal protection.
- SHA1 and Base64 implementations with zero external dependencies.
- Multipart form parsing (`hunos/multipart`).

---

## [1.1.0] - 2026-04-01

### Added

- Initial public release based on Mummy architecture.
- Single IO thread + worker thread pool architecture.
- HTTP/1.1 request parsing and response generation.
- `HttpHeaders` with case-insensitive key lookup.
- `PathParams` for router-populated parameters.

---

## [1.0.0] - 2026-03-15

### Added

- Initial development release.
- Core server loop with epoll (Linux) and select (cross-platform) backends.
- Basic request/response cycle.

[1.3.0]: https://github.com/katehonz/hunos/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/katehonz/hunos/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/katehonz/hunos/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/katehonz/hunos/releases/tag/v1.0.0
