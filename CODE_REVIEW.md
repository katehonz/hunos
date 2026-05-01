# Hunos Code Review

**Reviewer:** Kilo  
**Date:** 2026-05-01  
**Scope:** Full codebase — `src/`, `tests/`, `examples/`  
**Total lines reviewed:** ~3,063 (2,176 src + 747 tests + 140 examples)

---

## Executive Summary

Hunos is a well-structured HTTP/1.1 + WebSocket server that successfully improves on Mummy in several areas (trie router, middleware, zero dependencies). The core architecture — single IO thread with epoll/select + worker thread pool — is sound and proven. The codebase is clean and readable.

However, the review identified **3 bugs** (1 critical), **2 security concerns**, and several performance and correctness issues that should be addressed before production use.

---

## Critical Bugs

### BUG-1: Header value trailing whitespace not trimmed (copy-paste from Mummy)

**File:** `src/hunos.nim:800`  
**Severity:** Critical  
**Origin:** Inherited from Mummy's `afterRecvHttp`

```nim
# Line 799-802
while rightLen > 0 and
  dataEntry.recvBuf[rightStart] in whitespace:    # ← trims left of value (correct)
  inc rightStart
  dec rightLen
while leftLen > 0 and                               # ← BUG: should be rightLen
  dataEntry.recvBuf[rightStart + rightLen - 1] in whitespace:
  dec rightLen
```

Line 800 checks `leftLen > 0` when it should check `rightLen > 0`. This means trailing whitespace on HTTP header values is only trimmed if the header key also has leading whitespace. In practice, this rarely manifests because browsers don't send trailing whitespace, but it's a spec violation (RFC 7230 §3.2.6).

**Fix:** Change `leftLen > 0` to `rightLen > 0`.

---

### BUG-2: CORS middleware modifies request headers instead of response headers

**File:** `src/hunos/middleware.nim:44`  
**Severity:** Critical  

```nim
proc corsMiddleware*(...): MiddlewareProc =
  return proc(request: Request, next: proc()) {.gcsafe.} =
    request.headers["Access-Control-Allow-Origin"] = allowOrigin  # ← Wrong!
```

CORS headers (`Access-Control-Allow-Origin`, etc.) are **response** headers, but the middleware adds them to `request.headers`. When the handler later calls `request.respond(200, handlerHeaders, body)`, the CORS headers are not included in the response because `handlerHeaders` is a separate object.

**Impact:** CORS middleware is non-functional. Cross-origin requests will be blocked by browsers.

**Fix:** The middleware architecture needs a way to inject response headers. Options:
1. Add a `responseHeaders` field to `RequestObj` that gets merged during `respond()`.
2. Use a `Context` object that wraps both request and mutable response state.

---

### BUG-3: `test_core.nim` trie test doesn't test the actual Router

**File:** `tests/test_core.nim:21-93`  
**Severity:** Medium  

The trie router test block creates its own `TestRouter` and `TestTrieNode` types that duplicate the router logic instead of testing the actual `Router` from `hunos/router`. If the real router has a bug, this test won't catch it.

**Fix:** Import and test `hunos/router.Router` directly.

---

## Security Issues

### SEC-1: Weak directory traversal prevention in static file serving

**File:** `src/hunos/staticfiles.nim:62`  
**Severity:** Medium  

```nim
if ".." in relPath:
  return FileEntry()
```

This is a simple substring check. While it catches obvious attacks like `/../etc/passwd`, it's not robust against encoded variants. A more secure approach:

```nim
import std/os

proc isPathSafe(root, relPath: string): bool =
  let resolved = (root / relPath).normalizedPath()
  resolved.startsWith(root.normalizedPath())
```

### SEC-2: Weak request ID generation

**File:** `src/hunos/middleware.nim:74`  
**Severity:** Low  

```nim
request.headers["X-Request-Id"] = $cast[uint64](request)
```

The request ID is just the memory address of the `Request` object. This is:
- Predictable (sequential allocations)
- Not unique across server restarts
- Not a proper UUID

**Fix:** Use a counter or random ID:
```nim
var requestIdCounter: Atomic[uint64]
request.headers["X-Request-Id"] = $requestIdCounter.fetchAdd(1)
```

---

## Performance Issues

### PERF-1: No response compression

**File:** `src/hunos.nim:317-320`  
**Severity:** Medium  

```nim
if body.len > 860 and "Content-Encoding" notin headers:
  # Compression would go here if zippy was available
  # For zero-dependency build, we skip compression
  discard
```

Mummy automatically compresses responses > 860 bytes with gzip/deflate. Hunos has no compression, which means:
- JSON API responses (often 1-10KB) are sent uncompressed
- HTML pages are sent uncompressed
- Bandwidth usage is significantly higher

**Recommendation:** Either:
1. Add an optional `zippy` dependency behind a compile flag
2. Implement DEFLATE from scratch (it's ~200 lines)
3. At minimum, document this limitation

### PERF-2: Rate limiter copies timestamp array on every request

**File:** `src/hunos/ratelimit.nim:22`  
**Severity:** Low  

```nim
var timestamps = limiter.clients[clientIP]  # ← copies the seq
```

This creates a full copy of the timestamp sequence, filters it, then assigns it back. For high-traffic IPs with many timestamps, this is O(n) per request with allocation.

**Fix:** Use `limiter.clients[clientIP]` directly with in-place filtering, or use a circular buffer.

### PERF-3: Rate limiter has no automatic cleanup

**File:** `src/hunos/ratelimit.nim`  
**Severity:** Low  

The `cleanup()` proc exists but must be called manually. Without periodic cleanup, the `clients` table grows unboundedly as new IPs connect.

**Fix:** Add a background cleanup thread or integrate cleanup into the main loop.

### PERF-4: Static file serving reads entire file into memory

**File:** `src/hunos/staticfiles.nim:74`  
**Severity:** Low  

```nim
content = readFile(indexPath)
```

For large files, this blocks the worker thread and allocates memory for the entire file. Mummy has the same limitation (documented). A production server should use `sendfile()` on Linux or memory-mapped files.

---

## Code Quality Issues

### QUAL-1: Dead code in router.nim

**File:** `src/hunos/router.nim:79-114`  
**Severity:** Low  

`isPartialWildcard` and `partialWildcardMatches` are defined but never called. These were copied from Mummy's linear router but the trie implementation doesn't support partial wildcards (`*.json`, `/page_*`).

**Fix:** Either implement partial wildcard support in the trie, or remove the dead code.

### QUAL-2: `WarnLevel` defined but never used

**File:** `src/hunos/common.nim:10`  
**Severity:** Info  

`WarnLevel` is in the `LogLevel` enum but no code ever logs at this level.

### QUAL-3: `sha1Block` parameter name shadows `block` keyword

**File:** `src/hunos/sha.nim:1`  
**Severity:** Info  

```nim
proc sha1Block(state: var array[5, uint32], block: array[16, uint32]) =
```

The parameter `block` shadows Nim's `block` keyword. While Nim allows this, it can cause confusion. Rename to `blockData` or `chunk`.

### QUAL-4: `base64Encode` is hardcoded for 20-byte input

**File:** `src/hunos/sha.nim:88`  
**Severity:** Info  

```nim
proc base64Encode*(data: array[20, uint8]): string =
```

This only works for SHA1 output. A generic `base64Encode(data: openArray[uint8])` would be more reusable.

### QUAL-5: Benchmark comments in Bulgarian

**Files:** `tests/bench_scaling.nim`, `tests/bench_latency.nim`, `tests/bench_memory.nim`  
**Severity:** Info  

Comments and output messages are in Bulgarian. For an open-source project, English is preferred.

---

## Missing Features (Compared to Mummy)

| Feature | Mummy | Hunos | Impact |
|---------|-------|-------|--------|
| Gzip/deflate compression | ✅ | ❌ | High bandwidth overhead |
| Multipart form parsing | ✅ | ❌ | Can't handle file uploads |
| Partial wildcards (`*.json`) | ✅ | ❌ | Less flexible routing |
| File logger (thread-safe) | ✅ | ❌ | No production logging |
| HTTP pipelining detection | ✅ | ⚠️ (logs warning) | Low |

---

## Test Coverage Assessment

| Component | Unit Tests | Integration Tests |
|-----------|-----------|-------------------|
| SHA1 / Base64 | ✅ (test vectors) | — |
| Trie router | ⚠️ (tests copy, not real) | — |
| HTTP parsing | ❌ | ⚠️ (via bench_latency) |
| WebSocket | ❌ | ⚠️ (via example) |
| Middleware | ❌ | — |
| Rate limiter | ❌ | — |
| Static files | ❌ | — |
| Concurrency | — | ✅ (test_concurrent) |
| Scaling | — | ✅ (bench_scaling) |

**Verdict:** Test coverage is low. The trie router test is particularly misleading because it tests a duplicate implementation, not the real one.

---

## Recommendations (Priority Order)

1. **Fix BUG-1** (header whitespace) — one-line fix
2. **Fix BUG-2** (CORS middleware) — requires architecture change (add response headers to Request or introduce Context type)
3. **Fix BUG-3** (test the real Router) — rewrite test_core.nim trie block
4. **Fix SEC-1** (directory traversal) — use `normalizedPath()` check
5. **Add compression** — either optional zippy dep or built-in deflate
6. **Add multipart parsing** — required for form file uploads
7. **Improve test coverage** — unit tests for HTTP parsing, middleware, rate limiter
8. **Remove dead code** — partial wildcard procs in router.nim
9. **Add automatic rate limiter cleanup** — background thread or periodic task
10. **Translate comments to English** — for broader adoption

---

## Positive Observations

- **Clean architecture.** The separation into modules (common, internal, router, middleware, sha, ratelimit, staticfiles) is well-organized.
- **Zero dependencies.** Implementing SHA1, Base64, HTTP headers, and URL parsing internally eliminates supply chain risk.
- **Proven IO model.** The epoll + worker pool pattern is the same as Mummy, which has been production-tested with 100k+ concurrent WebSocket connections.
- **Trie router is correct.** The backtracking logic for path parameters is properly implemented.
- **Good error handling in worker proc.** Uncaught handler exceptions result in a 500 response instead of crashing the server.
- **Thread-safe WebSocket send/close.** The send queue with lock + event trigger pattern is correct and efficient.
