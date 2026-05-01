## test_multipart.nim
##
## Tests for multipart/form-data parsing.
##
## Run:
##   nim c --threads:on --mm:orc --path:src -r tests/test_multipart.nim

import hunos/multipart, std/strutils

block: # Test basic multipart parsing
  let body = """
------WebKitFormBoundary7MA4YWxkTrZu0gW
Content-Disposition: form-data; name="field1"

hello world
------WebKitFormBoundary7MA4YWxkTrZu0gW
Content-Disposition: form-data; name="field2"

goodbye
------WebKitFormBoundary7MA4YWxkTrZu0gW--""".strip(chars = {'\n'})

  # Normalize line endings
  let normalizedBody = body.replace("\n", "\r\n")
  let contentType = "multipart/form-data; boundary=----WebKitFormBoundary7MA4YWxkTrZu0gW"

  let data = decodeMultipart(normalizedBody, contentType)
  assert data.entries.len == 2, "Expected 2 entries, got " & $data.entries.len
  assert data.entries[0].name == "field1"
  assert data.entries[0].body == "hello world"
  assert data.entries[1].name == "field2"
  assert data.entries[1].body == "goodbye"
  echo "[OK] Basic multipart parsing with 2 text fields"

block: # Test file upload parsing
  let body = "----boundary\r\n" &
    "Content-Disposition: form-data; name=\"file\"; filename=\"test.txt\"\r\n" &
    "Content-Type: text/plain\r\n" &
    "\r\n" &
    "file content here\r\n" &
    "----boundary--"

  let contentType = "multipart/form-data; boundary=--boundary"
  let data = decodeMultipart(body, contentType)

  assert data.entries.len == 1
  assert data.entries[0].name == "file"
  assert data.entries[0].filename == "test.txt"
  assert data.entries[0].contentType == "text/plain"
  assert data.entries[0].body == "file content here"
  echo "[OK] File upload parsing with filename and content-type"

block: # Test getField helper
  let body = "----b\r\n" &
    "Content-Disposition: form-data; name=\"username\"\r\n" &
    "\r\n" &
    "john\r\n" &
    "----b\r\n" &
    "Content-Disposition: form-data; name=\"email\"\r\n" &
    "\r\n" &
    "john@example.com\r\n" &
    "----b--"

  let data = decodeMultipart(body, "multipart/form-data; boundary=--b")
  assert data.getField("username") == "john"
  assert data.getField("email") == "john@example.com"
  assert data.getField("missing") == ""
  assert data.hasField("username") == true
  assert data.hasField("missing") == false
  echo "[OK] getField and hasField helpers work"

block: # Test getFields for multiple values
  let body = "----b\r\n" &
    "Content-Disposition: form-data; name=\"tag\"\r\n" &
    "\r\n" &
    "nim\r\n" &
    "----b\r\n" &
    "Content-Disposition: form-data; name=\"tag\"\r\n" &
    "\r\n" &
    "programming\r\n" &
    "----b\r\n" &
    "Content-Disposition: form-data; name=\"tag\"\r\n" &
    "\r\n" &
    "web\r\n" &
    "----b--"

  let data = decodeMultipart(body, "multipart/form-data; boundary=--b")
  let tags = data.getFields("tag")
  assert tags.len == 3
  assert tags[0] == "nim"
  assert tags[1] == "programming"
  assert tags[2] == "web"
  echo "[OK] getFields returns multiple values for same name"

block: # Test getFile helper
  let body = "----b\r\n" &
    "Content-Disposition: form-data; name=\"text_field\"\r\n" &
    "\r\n" &
    "not a file\r\n" &
    "----b\r\n" &
    "Content-Disposition: form-data; name=\"avatar\"; filename=\"pic.png\"\r\n" &
    "Content-Type: image/png\r\n" &
    "\r\n" &
    "PNG_DATA\r\n" &
    "----b--"

  let data = decodeMultipart(body, "multipart/form-data; boundary=--b")
  let file = data.getFile("avatar")
  assert file.filename == "pic.png"
  assert file.contentType == "image/png"
  assert file.body == "PNG_DATA"

  let noFile = data.getFile("text_field")
  assert noFile.filename.len == 0
  echo "[OK] getFile distinguishes files from text fields"

block: # Test empty/invalid boundary
  let data = decodeMultipart("some body", "multipart/form-data")
  assert data.entries.len == 0
  echo "[OK] Empty boundary returns no entries"

block: # Test quoted boundary
  let body = "----b\r\n" &
    "Content-Disposition: form-data; name=\"q\"\r\n" &
    "\r\n" &
    "test\r\n" &
    "----b--"

  let data = decodeMultipart(body, """multipart/form-data; boundary="--b"""")
  assert data.entries.len == 1
  assert data.getField("q") == "test"
  echo "[OK] Quoted boundary handled correctly"

echo "All multipart tests passed!"
