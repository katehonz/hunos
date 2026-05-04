import hunos, hunos/router, hunos/sha, hunos/common, std/options, std/strutils

block: # Test trie router with actual Router type
  var router = newRouter()

  proc handler1(request: Request) =
    var headers: HttpHeaders
    headers["Content-Type"] = "text/plain"
    request.respond(200, headers, "root")

  proc handler2(request: Request) =
    var headers: HttpHeaders
    headers["Content-Type"] = "text/plain"
    request.respond(200, headers, "users_list")

  proc handler3(request: Request) =
    var headers: HttpHeaders
    headers["Content-Type"] = "text/plain"
    request.respond(200, headers, "user_detail")

  proc handler4(request: Request) =
    var headers: HttpHeaders
    headers["Content-Type"] = "text/plain"
    request.respond(200, headers, "user_posts")

  proc handler5(request: Request) =
    var headers: HttpHeaders
    headers["Content-Type"] = "text/plain"
    request.respond(200, headers, "files_wildcard")

  router.get("/", handler1)
  router.get("/users", handler2)
  router.get("/users/@id", handler3)
  router.get("/users/@id/posts", handler4)
  router.get("/files/**", handler5)

  # Test that the router compiles and has routes
  echo "Router created with 5 routes"

block: # Test SHA1
  # Test vector: SHA1("") = da39a3ee5e6b4b0d3255bfef95601890afd80709
  let emptyHash = sha1("")
  assert emptyHash[0] == 0xda'u8
  assert emptyHash[1] == 0x39'u8
  assert emptyHash[2] == 0xa3'u8
  assert emptyHash[3] == 0xee'u8
  assert emptyHash[4] == 0x5e'u8

  # Test vector: SHA1("abc") = a9993e364706816aba3e25717850c26c9cd0d89d
  let abcHash = sha1("abc")
  assert abcHash[0] == 0xa9'u8
  assert abcHash[1] == 0x99'u8
  assert abcHash[2] == 0x3e'u8
  assert abcHash[3] == 0x36'u8
  assert abcHash[4] == 0x47'u8

  # Test Base64
  let encoded = base64Encode(emptyHash)
  assert encoded.len == 28  # 20 bytes -> 28 base64 chars
  assert encoded[^1] == '='  # padding

  # Test vector: Base64(SHA1("")) = "2jmj7l5rSw0yVb/vlWAYkK/YBwk="
  assert encoded == "2jmj7l5rSw0yVb/vlWAYkK/YBwk="

  echo "All SHA1/Base64 tests passed!"

block: # Test HttpHeaders
  var headers: HttpHeaders
  headers["Content-Type"] = "text/html"
  headers["Content-Length"] = "42"

  assert headers["Content-Type"] == "text/html"
  assert headers["Content-Length"] == "42"
  assert headers["Content-Type"] == "text/html"
  assert "Content-Type" in headers
  assert "Missing" notin headers

  # Case-insensitive lookup
  assert headers["content-type"] == "text/html"
  assert headers["CONTENT-TYPE"] == "text/html"

  # Overwrite
  headers["Content-Type"] = "application/json"
  assert headers["Content-Type"] == "application/json"

  echo "All HttpHeaders tests passed!"

block: # Test PathParams
  var params: PathParams
  params.add(("id", "123"))
  params.add(("name", "test"))

  assert params["id"] == "123"
  assert params["name"] == "test"
  assert params["missing"] == ""
  assert "id" in params
  assert "missing" notin params
  assert params.getOrDefault("id", "default") == "123"
  assert params.getOrDefault("missing", "default") == "default"

  echo "All PathParams tests passed!"

block: # Test typed PathParams
  var params: PathParams
  params.add(("id", "42"))
  params.add(("price", "19.99"))
  params.add(("active", "true"))
  params.add(("flag", "1"))
  params.add(("invalid", "abc"))

  assert params.getInt("id") == some(42)
  assert params.getInt("invalid") == none(int)
  assert params.getInt("missing") == none(int)

  assert params.getFloat("price") == some(19.99)
  assert params.getFloat("invalid") == none(float)

  assert params.getBool("active") == some(true)
  assert params.getBool("flag") == some(true)
  assert params.getBool("invalid") == none(bool)
  assert params.getBool("missing") == none(bool)

  echo "All typed PathParams tests passed!"

block: # Test Response object
  var resp: Response
  resp.code = 200
  resp.headers["Content-Type"] = "text/plain"
  resp.body = "hello"

  assert resp.code == 200
  assert resp.headers["Content-Type"] == "text/plain"
  assert resp.body == "hello"

  echo "All Response object tests passed!"

block: # Test Cookie helpers
  var headers: HttpHeaders
  headers.setCookie("session", "abc123", path = "/", maxAge = 3600, httpOnly = true, secure = true, sameSite = "Lax")
  
  assert headers.len == 1
  assert headers[0][0] == "Set-Cookie"
  assert "session=abc123" in headers[0][1]
  assert "Path=/" in headers[0][1]
  assert "Max-Age=3600" in headers[0][1]
  assert "HttpOnly" in headers[0][1]
  assert "Secure" in headers[0][1]
  assert "SameSite=Lax" in headers[0][1]

  echo "All Cookie helper tests passed!"

echo "All tests passed!"
