import common, std/nativesockets, std/endians, std/strutils

template currentExceptionAsHunosError*(): untyped =
  let e = getCurrentException()
  newException(HunosError, e.getStackTrace & e.msg, e)

type
  HttpHeaders* = seq[(string, string)]

  Response* = object
    code*: int
    headers*: HttpHeaders
    body*: string

proc `[]`*(headers: HttpHeaders, key: string): string =
  for (k, v) in headers:
    if cmpIgnoreCase(k, key) == 0:
      return v

proc `[]=`*(headers: var HttpHeaders, key, value: string) =
  for pair in headers.mitems:
    if cmpIgnoreCase(pair[0], key) == 0:
      pair[1] = value
      return
  headers.add((key, value))

proc contains*(headers: HttpHeaders, key: string): bool =
  for (k, v) in headers:
    if cmpIgnoreCase(k, key) == 0:
      return true

proc headerContainsToken*(headers: HttpHeaders, key, token: string): bool =
  for (k, v) in headers:
    if cmpIgnoreCase(k, key) == 0:
      var first = 0
      while first < v.len:
        var comma = v.find(',', start = first)
        if comma == -1:
          comma = v.len
        var len = comma - first
        while len > 0 and v[first] in {' ', '\t'}:
          inc first
          dec len
        while len > 0 and v[first + len - 1] in {' ', '\t'}:
          dec len
        if len > 0 and len == token.len:
          var matches = true
          for i in 0 ..< len:
            if ord(toLowerAscii(v[first + i])) != ord(toLowerAscii(token[i])):
              matches = false
              break
          if matches:
            return true
        first = comma + 1

proc encodeHeaders*(
  statusCode: int,
  headers: HttpHeaders,
  httpVersion: HttpVersion = Http11
): string {.raises: [], gcsafe.} =
  let
    status =
      case statusCode:
      of 200: "200 OK"
      of 201: "201 Created"
      of 204: "204 No Content"
      of 301: "301 Moved Permanently"
      of 302: "302 Found"
      of 304: "304 Not Modified"
      of 400: "400 Bad Request"
      of 401: "401 Unauthorized"
      of 403: "403 Forbidden"
      of 404: "404 Not Found"
      of 405: "405 Method Not Allowed"
      of 413: "413 Payload Too Large"
      of 429: "429 Too Many Requests"
      of 500: "500 Internal Server Error"
      of 502: "502 Bad Gateway"
      of 503: "503 Service Unavailable"
      else: $statusCode
    statusLineLen = 9 + status.len + 2

  var headersLen = statusLineLen
  for (k, v) in headers:
    headersLen += k.len + 2 + v.len + 2
  headersLen += 2

  result = newString(headersLen)
  if httpVersion == Http10:
    result[0] = 'H'
    result[1] = 'T'
    result[2] = 'T'
    result[3] = 'P'
    result[4] = '/'
    result[5] = '1'
    result[6] = '.'
    result[7] = '0'
  else:
    result[0] = 'H'
    result[1] = 'T'
    result[2] = 'T'
    result[3] = 'P'
    result[4] = '/'
    result[5] = '1'
    result[6] = '.'
    result[7] = '1'
  result[8] = ' '

  var pos = 9
  copyMem(result[pos].addr, status[0].unsafeAddr, status.len)
  pos += status.len

  result[pos + 0] = '\r'
  result[pos + 1] = '\n'
  pos += 2

  for (k, v) in headers:
    copyMem(result[pos].addr, k.cstring, k.len)
    pos += k.len
    result[pos + 0] = ':'
    result[pos + 1] = ' '
    pos += 2
    copyMem(result[pos].addr, v.cstring, v.len)
    pos += v.len
    result[pos + 0] = '\r'
    result[pos + 1] = '\n'
    pos += 2

  result[pos + 0] = '\r'
  result[pos + 1] = '\n'
  pos += 2

proc encodeFrameHeader*(
  opcode: uint8,
  payloadLen: int
): string {.raises: [], gcsafe.} =
  let opcode = opcode and 0b00001111'u8

  var frameHeaderLen = 2
  if payloadLen <= 125:
    discard
  elif payloadLen <= uint16.high.int:
    frameHeaderLen += 2
  else:
    frameHeaderLen += 8

  result = newStringOfCap(frameHeaderLen)
  result.add cast[char](0b10000000 or opcode)

  if payloadLen <= 125:
    result.add payloadLen.char
  elif payloadLen <= uint16.high.int:
    result.add 126.char
    var l = cast[uint16](payloadLen).htons
    result.setLen(result.len + 2)
    copyMem(result[result.len - 2].addr, l.addr, 2)
  else:
    result.add 127.char
    var l: uint64
    bigEndian64(l.addr, payloadLen.unsafeAddr)
    result.setLen(result.len + 8)
    copyMem(result[result.len - 8].addr, l.addr, 8)

template integerOutOfRangeError*() =
  raise newException(ValueError, "Parsed integer outside of valid range")

template invalidIntegerError*() =
  raise newException(ValueError, "Invalid integer string")

template invalidHexError*() =
  raise newException(ValueError, "Invalid hex string")

proc strictParseInt*(s: openarray[char]): int =
  var
    sign = -1
    i = 0

  if i < s.len and s[i] == '-':
    inc i
    sign = 1

  if i == s.len:
    invalidIntegerError()

  if i < s.len:
    if (i == 0 and s.len - i == 1 and s[i] == '0') or s[i] in {'1'..'9'}:
      result = 0
      while i < s.len and s[i] in {'0'..'9'}:
        let c = ord(s[i]) - ord('0')
        if result >= (int.low + c) div 10:
          result = result * 10 - c
        else:
          integerOutOfRangeError()
        inc i
      if sign == -1 and result == int.low:
        integerOutOfRangeError()
      else:
        result = result * sign

  if i == 0 or i != s.len:
    invalidIntegerError()

proc strictParseHex*(s: openarray[char]): int =
  var
    i = 0
    bits: uint

  if s.len > 16:
    integerOutOfRangeError()

  while i < s.len:
    case s[i]
    of '0'..'9':
      bits = bits shl 4 or ord(s[i]).uint - ord('0').uint
    of 'a'..'f':
      bits = bits shl 4 or ord(s[i]).uint - ord('a').uint + 10.uint
    of 'A'..'F':
      bits = bits shl 4 or ord(s[i]).uint - ord('A').uint + 10.uint
    else:
      break
    inc i

  if i == 0 or i != s.len:
    invalidHexError()

  if bits > int.high.uint:
    integerOutOfRangeError()

  result = bits.int
