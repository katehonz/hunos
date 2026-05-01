import std/strutils

proc icmp(a, b: string): bool = cmpIgnoreCase(a, b) == 0

type
  MultipartEntry* = object
    name*: string
    filename*: string
    contentType*: string
    headers*: seq[(string, string)]
    body*: string
    bodyStart*: int
    bodyLen*: int

  MultipartData* = object
    entries*: seq[MultipartEntry]
    body*: string

proc extractBoundary(contentType: string): string =
  let parts = contentType.split(';')
  for part in parts:
    let trimmed = part.strip()
    if trimmed.startsWith("boundary="):
      var boundary = trimmed["boundary=".len .. ^1]
      if boundary.len >= 2 and boundary[0] == '"' and boundary[^1] == '"':
        boundary = boundary[1 .. ^2]
      return boundary
  return ""

proc parseContentDisposition(value: string): tuple[name, filename: string] =
  var name, filename: string
  let parts = value.split(';')
  for part in parts:
    let trimmed = part.strip()
    if trimmed.startsWith("name="):
      name = trimmed["name=".len .. ^1]
      if name.len >= 2 and name[0] == '"' and name[^1] == '"':
        name = name[1 .. ^2]
    elif trimmed.startsWith("filename="):
      filename = trimmed["filename=".len .. ^1]
      if filename.len >= 2 and filename[0] == '"' and filename[^1] == '"':
        filename = filename[1 .. ^2]
  return (name, filename)

proc decodeMultipart*(body: string, contentType: string): MultipartData =
  let boundary = extractBoundary(contentType)
  if boundary.len == 0:
    return MultipartData(body: body)

  let delimiter = "--" & boundary

  result.body = body
  result.entries = @[]

  var pos = 0

  # Find the first delimiter
  let firstDelim = body.find(delimiter, pos)
  if firstDelim == -1:
    return

  pos = firstDelim + delimiter.len

  # Skip CRLF after delimiter
  if pos + 1 < body.len and body[pos] == '\r' and body[pos + 1] == '\n':
    pos += 2
  elif pos < body.len and body[pos] == '\n':
    pos += 1

  while pos < body.len:
    # Find the end of headers (double CRLF)
    let headersEnd = body.find("\r\n\r\n", pos)
    if headersEnd == -1:
      break

    var entry: MultipartEntry
    entry.headers = @[]

    # Parse headers
    let headersStr = body[pos ..< headersEnd]
    for line in headersStr.split("\r\n"):
      let colonPos = line.find(':')
      if colonPos == -1:
        continue
      let key = line[0 ..< colonPos].strip()
      let value = line[colonPos + 1 .. ^1].strip()
      entry.headers.add((key, value))

      if icmp(key, "Content-Disposition"):
        let (name, filename) = parseContentDisposition(value)
        entry.name = name
        entry.filename = filename
      elif icmp(key, "Content-Type"):
        entry.contentType = value

    pos = headersEnd + 4  # Skip \r\n\r\n

    # Find the next delimiter
    let nextDelim = body.find("\r\n" & delimiter, pos)
    if nextDelim == -1:
      break

    entry.bodyStart = pos
    entry.bodyLen = nextDelim - pos
    entry.body = body[pos ..< nextDelim]

    result.entries.add(entry)

    pos = nextDelim + 2 + delimiter.len  # Skip \r\n + delimiter

    # Check for end marker
    if pos + 1 < body.len and body[pos .. pos + 1] == "--":
      break

    # Skip CRLF after delimiter
    if pos + 1 < body.len and body[pos] == '\r' and body[pos + 1] == '\n':
      pos += 2
    elif pos < body.len and body[pos] == '\n':
      pos += 1

proc getField*(data: MultipartData, name: string): string =
  for entry in data.entries:
    if entry.name == name and entry.filename.len == 0:
      return entry.body
  return ""

proc getFile*(data: MultipartData, name: string): MultipartEntry =
  for entry in data.entries:
    if entry.name == name and entry.filename.len > 0:
      return entry
  return MultipartEntry()

proc getFields*(data: MultipartData, name: string): seq[string] =
  result = @[]
  for entry in data.entries:
    if entry.name == name and entry.filename.len == 0:
      result.add(entry.body)

proc hasField*(data: MultipartData, name: string): bool =
  for entry in data.entries:
    if entry.name == name:
      return true
  return false
