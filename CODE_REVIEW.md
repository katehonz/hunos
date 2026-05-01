# Hunos Code Review

**Reviewer:** Kilo
**Date:** 2026-05-01
**Last Updated:** 2026-05-01
**Scope:** Full codebase — `src/`, `tests/`, `examples/`
**Total lines reviewed:** ~3,063 (2,176 src + 747 tests + 140 examples)

---

## Executive Summary

Hunos is a well-structured HTTP/1.1 + WebSocket server that successfully improves on Mummy in several areas (trie router, middleware, zero dependencies). The core architecture — single IO thread with epoll/select + worker thread pool — is sound and proven. The codebase is clean and readable.

The review identified **3 bugs** (1 critical), **2 security concerns**, and several performance and correctness issues. **2 security/critical issues have been fixed.**

---

## Fixed Issues

### ✅ BUG-2: CORS middleware modifies request headers instead of response headers (FIXED)

**File:** `src/hunos/middleware.nim:43-50`, `src/hunos.nim:57,318-321`

**Problem:** CORS headers were being added to `request.headers` (request object) instead of response headers. When `request.respond()` was called, it used a separate `handlerHeaders` that didn't include the CORS headers.

**Fix:** Added `responseHeaders*: HttpHeaders` field to `RequestObj`. The `respond()` procedure now merges `request.responseHeaders` into the response headers before encoding.

```nim
# src/hunos.nim - RequestObj
RequestObj* = object
  # ... existing fields ...
  responded: bool
  responseHeaders*: HttpHeaders  # NEW

# src/hunos.nim - respond() now merges responseHeaders
for (k, v) in request.responseHeaders:
  if k notin headers:
    headers[k] = v

# src/hunos/middleware.nim - corsMiddleware now uses responseHeaders
proc corsMiddleware*(...): MiddlewareProc =
  return proc(request: Request, next: proc()) {.gcsafe.} =
    request.responseHeaders["Access-Control-Allow-Origin"] = allowOrigin
    request.responseHeaders["Access-Control-Allow-Methods"] = allowMethods
    request.responseHeaders["Access-Control-Allow-Headers"] = allowHeaders
    request.responseHeaders["Access-Control-Max-Age"] = maxAge
    # ...
```

---

### ✅ SEC-2: Weak request ID generation (FIXED)

**File:** `src/hunos/middleware.nim:70-77`

**Problem:** Request ID was using `cast[uint64](request)` - the memory address of the Request object. This is predictable, not unique across restarts, and exposes heap allocation addresses.

**Fix:** Replaced with atomic counter `requestIdCounter.fetchAdd(1)`.

```nim
# src/hunos/middleware.nim
var requestIdCounter*: Atomic[uint64]

proc requestIdMiddleware*: MiddlewareProc =
  return proc(request: Request, next: proc()) {.gcsafe.} =
    let existingId = request.headers["X-Request-Id"]
    if existingId == "":
      let id = requestIdCounter.fetchAdd(1)
      request.headers["X-Request-Id"] = $id
    next()
```

---

## Remaining Issues

### BUG-1: Header value trailing whitespace (CLAIM: NOT A BUG)

**File:** `src/hunos.nim:800`

The code review claimed line 800 had `leftLen > 0` but should have `rightLen > 0`. Upon inspection, the current code already uses `rightLen`:

```nim
while rightLen > 0 and
  dataEntry.recvBuf[rightStart + rightLen - 1] in whitespace:
  dec rightLen
```

This appears correct. The original bug report may have had incorrect line numbers.

**Status:** Not a bug (or already fixed)

---

### BUG-3: `test_core.nim` trie test doesn't test the actual Router

**File:** `tests/test_core.nim:21-93`

The trie router test block creates its own `TestRouter` and `TestTrieNode` types that duplicate the router logic instead of testing the actual `Router` from `hunos/router`. If the real router has a bug, this test won't catch it.

**Status:** Open - needs test rewrite

---

### SEC-1: Weak directory traversal prevention in static file serving

**File:** `src/hunos/staticfiles.nim:62`

```nim
if ".." in relPath:
  return FileEntry()
```

This is a simple substring check. While it catches obvious attacks, it's not robust against encoded variants. The file already uses `normalizedPath()` for the actual file path check (lines 66-69), but the `..` substring check is redundant and incomplete.

**Status:** Open - low priority (redundant with normalizedPath check)

---

## Performance Issues

### PERF-1: No response compression

**File:** `src/hunos.nim:317-320`

Mummy automatically compresses responses > 860 bytes with gzip/deflate. Hunos has no compression.

**Status:** Open - known limitation, documented in code

### PERF-2: Rate limiter copies timestamp array on every request

**File:** `src/hunos/ratelimit.nim:22`

```nim
var timestamps = limiter.clients[clientIP]  # ← copies the seq
```

**Status:** Open - low priority

### PERF-3: Rate limiter has no automatic cleanup

**File:** `src/hunos/ratelimit.nim`

`cleanup()` proc exists but must be called manually.

**Status:** Open

### PERF-4: Static file serving reads entire file into memory

**File:** `src/hunos/staticfiles.nim:74`

**Status:** Open - known limitation

---

## Code Quality Issues

### QUAL-1: Dead code in router.nim (NOT FOUND)

**Status:** The `isPartialWildcard` and `partialWildcardMatches` procs mentioned in the original review do not exist in the codebase. No action needed.

### QUAL-2: `WarnLevel` defined but never used

**File:** `src/hunos/common.nim:10`

**Status:** Open - info level

### QUAL-3: `sha1Block` parameter name shadows `block` keyword

**File:** `src/hunos/sha.nim:1`

**Status:** Open - info level

### QUAL-4: `base64Encode` is hardcoded for 20-byte input

**File:** `src/hunos/sha.nim:88`

**Status:** Open - info level

### QUAL-5: Benchmark comments in Bulgarian

**Files:** `tests/bench_*.nim`

**Status:** Open - info level

---

## Missing Features (Compared to Mummy)

| Feature | Mummy | Hunos | Status | Notes |
|---------|-------|-------|--------|-------|
| Gzip/deflate compression | ✅ | ❌ | Open | Mummy auto-compresses responses > 860 bytes via `zippy`. Hunos has placeholder comment (`src/hunos.nim:317-320`) but no implementation. |
| Multipart form parsing | ✅ | ❌ | Open | Mummy has `mummy/multipart.nim` with `decodeMultipart()`. Hunos has no equivalent. |
| Partial wildcards (`*.json`) | ✅ | ❌ | Open | Mummy router supports `*`, `/*`, `/page_*`, `/*_something_*`. Hunos only supports `@param` and `**`. |
| Named path parameters | ✅ | ✅ | — | Both support `@id` style params. Hunos uses trie, Mummy uses linear scan. |
| HTTP pipelining detection | ✅ | ✅ | — | Both log a debug warning when data arrives before previous response is sent. Identical behavior. |
| File logger | ❌ | ❌ | — | Neither has a built-in file logger. Both only expose a `LogHandler` callback. Can be added externally. |

### Details

**Compression:** Adding gzip/deflate would require either adding `zippy` as an optional dependency or implementing deflate internally. The placeholder in `respond()` is ready for integration.

**Multipart:** Mummy's `decodeMultipart()` returns `seq[MultipartEntry]` with lazy `(start, last)` slices into the request body. A Hunos equivalent could live in `hunos/multipart.nim` and avoid copying large uploads.

**Router wildcards:** Mummy's `*` wildcard matches 0+ characters excluding `/`. Valid patterns: `/api/*.json`, `/page_*`, `/*_something_*`. Hunos router only has exact segment matches, `@param` (single segment), and `**` (multi-segment). Adding `*` would require updating `addRoute()` and `matchNode()` in `router.nim`.

---

## Recommendations (Priority Order)

1. **Fix BUG-3** (test the real Router) — rewrite test_core.nim trie block
2. **Add compression** — optional zippy dep or built-in deflate
3. **Add multipart parsing** — required for form file uploads
4. **Improve test coverage** — unit tests for middleware, rate limiter, static files
5. **Add automatic rate limiter cleanup** — background thread or periodic task
6. **Optional: translate comments to English** — for broader adoption

---

## Positive Observations

- **Clean architecture.** The separation into modules (common, internal, router, middleware, sha, ratelimit, staticfiles) is well-organized.
- **Zero dependencies.** Implementing SHA1, Base64, HTTP headers, and URL parsing internally eliminates supply chain risk.
- **Proven IO model.** The epoll + worker pool pattern is the same as Mummy, which has been production-tested with 100k+ concurrent WebSocket connections.
- **Trie router is correct.** The backtracking logic for path parameters is properly implemented.
- **Good error handling in worker proc.** Uncaught handler exceptions result in a 500 response instead of crashing the server.
- **Thread-safe WebSocket send/close.** The send queue with lock + event trigger pattern is correct and efficient.
