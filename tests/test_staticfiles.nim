## test_staticfiles.nim
##
## Tests for static file serving and MIME type detection.
##
## Run:
##   nim c --threads:on --mm:orc --path:src -r tests/test_staticfiles.nim

import hunos/staticfiles, hunos, hunos/router, hunos/middleware, std/os, std/tempfiles

block: # Test MIME type detection
  assert guessContentType(".html") == "text/html; charset=utf-8"
  assert guessContentType(".HTML") == "text/html; charset=utf-8"
  assert guessContentType(".css") == "text/css; charset=utf-8"
  assert guessContentType(".js") == "application/javascript; charset=utf-8"
  assert guessContentType(".json") == "application/json; charset=utf-8"
  assert guessContentType(".png") == "image/png"
  assert guessContentType(".jpg") == "image/jpeg"
  assert guessContentType(".jpeg") == "image/jpeg"
  assert guessContentType(".gif") == "image/gif"
  assert guessContentType(".svg") == "image/svg+xml"
  assert guessContentType(".woff2") == "font/woff2"
  assert guessContentType(".pdf") == "application/pdf"
  assert guessContentType(".wasm") == "application/wasm"
  assert guessContentType(".unknown") == "application/octet-stream"
  echo "[OK] MIME type detection for 14+ extensions"

block: # Test StaticConfig creation
  let config = newStaticConfig("/tmp/test", urlPrefix = "/assets", indexFile = "index.html", maxAge = 7200)
  assert config.root == "/tmp/test"
  assert config.urlPrefix == "/assets"
  assert config.indexFile == "index.html"
  assert config.maxAge == 7200
  echo "[OK] StaticConfig creation with custom params"

block: # Test directory traversal prevention
  let tmpDir = getTempDir() / "hunos_test_static"
  createDir(tmpDir)
  writeFile(tmpDir / "secret.txt", "secret data")

block: # Test directory traversal prevention and normal access
  let tmpDir = getTempDir() / "hunos_test_static"
  createDir(tmpDir)
  writeFile(tmpDir / "secret.txt", "secret data")

  let config = newStaticConfig(tmpDir, urlPrefix = "")

  # Basic traversal attempt
  let result1 = serveFile(config, "/../../../etc/passwd")
  assert result1.filePath.len == 0, "Should block basic traversal"
  echo "[OK] Blocks basic directory traversal (..)"

  # URL-encoded traversal attempt
  let result2 = serveFile(config, "/%2e%2e/secret.txt")
  assert result2.filePath.len == 0, "Should block URL-encoded traversal"
  echo "[OK] Blocks URL-encoded directory traversal (%2e%2e)"

  # Normal file access
  let result3 = serveFile(config, "/secret.txt")
  assert result3.content == "secret data"
  assert result3.contentType == "text/plain; charset=utf-8"
  echo "[OK] Normal file access works"

  # Missing file
  let result4 = serveFile(config, "/nonexistent.txt")
  assert result4.filePath.len == 0
  echo "[OK] Missing file returns empty FileEntry"

  removeDir(tmpDir)

block: # Test URL prefix stripping
  let tmpDir = getTempDir() / "hunos_test_prefix"
  createDir(tmpDir)
  writeFile(tmpDir / "test.css", "body{}")

  let config = newStaticConfig(tmpDir, urlPrefix = "/static")

  let result = serveFile(config, "/static/test.css")
  assert result.content == "body{}"
  assert result.contentType == "text/css; charset=utf-8"
  echo "[OK] URL prefix stripping works"

  # Without prefix
  let result2 = serveFile(config, "/test.css")
  assert result2.filePath.len == 0, "Should not serve without prefix"
  echo "[OK] Files outside prefix are not served"

  removeDir(tmpDir)

block: # Test staticFileMiddleware compiles correctly
  let tmpDir = getTempDir() / "hunos_test_middleware"
  createDir(tmpDir)
  writeFile(tmpDir / "test.css", "body{}")

  let config = newStaticConfig(tmpDir, urlPrefix = "/static")

  proc apiHandler(request: Request) {.gcsafe.} =
    request.respond(200, body = "API response")

  var r = newRouter()
  r.get("/api", apiHandler)

  var stack = newMiddlewareStack(r)
  stack.use(staticFileMiddleware(config))

  let handler = stack.toHandler()
  assert handler != nil

  removeDir(tmpDir)
  echo "[OK] staticFileMiddleware compiles and chains correctly"

echo "All staticfiles tests passed!"
