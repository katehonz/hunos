## test_h2.nim
##
## Tests for HTTP/2 (h2c) frame parsing, HPACK, and connection management.

import hunos/h2, std/tables

proc testFrameRoundtrip() =
  echo "[TEST] Frame parse/encode roundtrip"

  let original = Frame(
    frameType: ftSettings,
    flags: 0,
    streamId: 0,
    payload: ""
  )
  let encoded = encodeFrame(original)
  assert encoded.len == 9, "Empty settings frame should be 9 bytes"

  let (decoded, consumed) = parseFrame(encoded)
  assert consumed == 9, "Should consume 9 bytes"
  assert decoded.frameType == ftSettings
  assert decoded.streamId == 0
  assert decoded.payload.len == 0

  echo "[OK] Frame roundtrip works"

proc testSettingsFrame() =
  echo "[TEST] Settings frame with parameters"

  var settings: seq[(SettingsParam, uint32)] = @[]
  settings.add((spHeaderTableSize, 8192'u32))
  settings.add((spMaxConcurrentStreams, 100'u32))
  settings.add((spInitialWindowSize, 65535'u32))

  let payload = encodeSettingsPayload(settings)
  assert payload.len == 18, "3 settings * 6 bytes = 18"

  let decoded = parseSettingsPayload(payload)
  assert decoded.len == 3
  assert decoded[0] == (spHeaderTableSize, 8192'u32)
  assert decoded[1] == (spMaxConcurrentStreams, 100'u32)
  assert decoded[2] == (spInitialWindowSize, 65535'u32)

  echo "[OK] Settings frame encoding/parsing works"

proc testHpackIntEncoding() =
  echo "[TEST] HPACK integer encoding"

  # RFC 7541 Section 5.1 examples
  let v1 = encodeHpackInt(10, 5)
  assert v1.len == 1
  assert v1[0].uint8 == 10

  let v2 = encodeHpackInt(1337, 5)
  assert v2.len == 3
  assert v2[0].uint8 == 31  # maxPrefix for 5 bits = 31
  assert v2[1].uint8 == 154  # (1337-31) mod 128 + 128 = 154
  assert v2[2].uint8 == 10   # (1337-31) shr 7 = 10

  let v3 = encodeHpackInt(42, 8)
  assert v3.len == 1
  assert v3[0].uint8 == 42

  echo "[OK] HPACK integer encoding works"

proc testHpackIntDecoding() =
  echo "[TEST] HPACK integer decoding"

  let data1 = [char(10)]
  let (v1, p1) = decodeHpackInt(data1, 0, 5)
  assert v1 == 10'u32
  assert p1 == 1

  let data2 = [char(31), char(154), char(10)]
  let (v2, p2) = decodeHpackInt(data2, 0, 5)
  assert v2 == 1337'u32
  assert p2 == 3

  echo "[OK] HPACK integer decoding works"

proc testHpackStringEncoding() =
  echo "[TEST] HPACK string encoding/decoding"

  let encoded = encodeHpackString("hello", false)
  assert encoded.len == 6  # 1 byte length + 5 chars
  assert encoded[0].uint8 == 5  # length, no huffman bit

  let (decoded, pos) = decodeHpackString(encoded, 0)
  assert decoded == "hello"
  assert pos == 6

  echo "[OK] HPACK string encoding/decoding works"

proc testHpackStaticTableLookup() =
  echo "[TEST] HPACK static table lookup"

  assert findInStaticTable(":method", "GET") == 2
  assert findInStaticTable(":method", "POST") == 3
  assert findInStaticTable(":path", "/") == 4
  assert findInStaticTable(":status", "200") == 8
  assert findInStaticTable(":status", "404") == 13
  assert findNameInStaticTable(":authority") == 1
  assert findNameInStaticTable("content-type") == 31
  assert findInStaticTable("nonexistent", "value") == 0

  echo "[OK] Static table lookup works"

proc testHpackHeaderDecode() =
  echo "[TEST] HPACK header block decoding"

  var conn = newH2Connection()

  # Encode a simple indexed header (:method = GET → index 2)
  var headerBlock = ""
  headerBlock &= encodeHpackInt(2, 7)
  headerBlock[0] = char(headerBlock[0].uint8 or 0x80)

  let headers = decodeHpackHeaders(conn, headerBlock)
  assert headers.len == 1
  assert headers[0] == (":method", "GET")

  echo "[OK] Indexed header decoding works"

proc testHpackLiteralHeader() =
  echo "[TEST] HPACK literal header with incremental indexing"

  var conn = newH2Connection()

  # Literal with name index (:path = 4 → index, value "literal")
  var headerBlock = ""
  # Index 4, 6-bit prefix, literal indexing (0x40)
  headerBlock &= encodeHpackInt(4, 6)
  headerBlock[^1] = char(headerBlock[^1].uint8 or 0x40)
  # Name is indexed (4 = :path), value is literal
  headerBlock &= encodeHpackString("literal", false)

  let headers = decodeHpackHeaders(conn, headerBlock)
  assert headers.len == 1
  assert headers[0] == (":path", "literal")

  echo "[OK] Literal header with incremental indexing works"

proc testConnectionInit() =
  echo "[TEST] H2Connection initialization"

  let conn = newH2Connection()
  assert conn.maxFrameSize == defaultMaxFrameSize
  assert conn.headerTableSize == defaultHeaderTableSize
  assert conn.enablePush == false
  assert conn.initialWindowSize == defaultInitialWindowSize
  assert conn.sendWindow == defaultInitialWindowSize
  assert conn.recvWindow == defaultInitialWindowSize

  echo "[OK] Connection initialization works"

proc testStreamManagement() =
  echo "[TEST] Stream state management"

  var conn = newH2Connection()

  conn.getOrCreateStream(1)
  assert conn.streamRef(1).state == ssIdle
  assert conn.streamRef(1).id == 1

  conn.streamRef(1).state = ssOpen
  assert conn.streams[1].state == ssOpen

  conn.closeStream(1)
  assert conn.streams[1].state == ssClosed

  echo "[OK] Stream state management works"

proc testSettingsApply() =
  echo "[TEST] Apply settings to connection"

  var conn = newH2Connection()

  var settings: seq[(SettingsParam, uint32)] = @[]
  settings.add((spHeaderTableSize, 16384'u32))
  settings.add((spMaxConcurrentStreams, 50'u32))
  settings.add((spInitialWindowSize, 131072'u32))
  settings.add((spMaxFrameSize, 32768'u32))

  conn.applySettings(settings)
  assert conn.headerTableSize == 16384'u32
  assert conn.maxConcurrentStreams == 50'u32
  assert conn.initialWindowSize == 131072'i32
  assert conn.maxFrameSize == 32768'u32

  echo "[OK] Settings application works"

proc testFrameTypes() =
  echo "[TEST] Various frame types encoding"

  let ping = makePingFrame(0x1234567890ABCDEF'u64, ack = true)
  assert ping.frameType == ftPing
  assert (ping.flags and uint8(ffAck)) != 0
  assert ping.payload.len == 8

  let goaway = makeGoawayFrame(5, ecNoError)
  assert goaway.frameType == ftGoaway
  assert goaway.payload.len == 8

  let rst = makeRstStreamFrame(3, ecProtocolError)
  assert rst.frameType == ftRstStream
  assert rst.streamId == 3
  assert rst.payload.len == 4

  let wu = makeWindowUpdateFrame(0, 65535)
  assert wu.frameType == ftWindowUpdate
  assert wu.payload.len == 4

  echo "[OK] Frame type encoding works"

proc testHeadersRoundtrip() =
  echo "[TEST] Full headers encode/decode roundtrip"

  var conn = newH2Connection()

  var headers: seq[(string, string)] = @[]
  headers.add((":method", "GET"))
  headers.add((":path", "/test"))
  headers.add((":scheme", "http"))
  headers.add((":authority", "localhost"))
  headers.add(("accept", "text/html"))

  let encoded = encodeHpackHeaders(conn, headers)

  var conn2 = newH2Connection()
  let decoded = decodeHpackHeaders(conn2, encoded)

  assert decoded.len == headers.len
  for i in 0 ..< headers.len:
    assert decoded[i] == headers[i], "Header mismatch at " & $i & ": " &
      decoded[i][0] & "=" & decoded[i][1] & " vs " & headers[i][0] & "=" & headers[i][1]

  echo "[OK] Headers roundtrip works"

proc testResponseEncoding() =
  echo "[TEST] Response frames encoding"

  var conn = newH2Connection()

  var respHeaders: seq[(string, string)] = @[]
  respHeaders.add(("content-type", "text/plain"))

  let frames = encodeResponseFrames(conn, 1, 200, respHeaders, "Hello")
  assert frames.len == 2, "Should produce HEADERS + DATA frames"

  # Parse the headers frame
  let (headersFrame, hLen) = parseFrame(frames[0])
  assert hLen > 0
  assert headersFrame.frameType == ftHeaders
  assert headersFrame.streamId == 1

  # Parse the data frame
  let (dataFrame, dLen) = parseFrame(frames[1])
  assert dLen > 0
  assert dataFrame.frameType == ftData
  assert dataFrame.streamId == 1
  assert dataFrame.payload == "Hello"

  echo "[OK] Response frames encoding works"

proc testEmptyBodyResponse() =
  echo "[TEST] Response with empty body"

  var conn = newH2Connection()
  let frames = encodeResponseFrames(conn, 1, 204, @[], "")
  assert frames.len == 1, "Should produce only HEADERS frame for empty body"

  let (headersFrame, _) = parseFrame(frames[0])
  assert headersFrame.frameType == ftHeaders
  assert (headersFrame.flags and uint8(ffEndStream)) != 0, "Should have END_STREAM flag"

  echo "[OK] Empty body response has END_STREAM"

proc testFrameSizeValidation() =
  echo "[TEST] Frame size validation"

  # Too short
  let (f1, c1) = parseFrame([char(0), char(0)])
  assert c1 == 0, "Should need more data"

  # Normal frame
  let data = [char(0), char(0), char(0), char(4), char(0), char(0), char(0), char(0), char(0)]
  let (f2, c2) = parseFrame(data)
  assert c2 == 9
  assert f2.frameType == ftSettings

  echo "[OK] Frame size validation works"

proc main() =
  testFrameRoundtrip()
  testSettingsFrame()
  testHpackIntEncoding()
  testHpackIntDecoding()
  testHpackStringEncoding()
  testHpackStaticTableLookup()
  testHpackHeaderDecode()
  testHpackLiteralHeader()
  testConnectionInit()
  testStreamManagement()
  testSettingsApply()
  testFrameTypes()
  testHeadersRoundtrip()
  testResponseEncoding()
  testEmptyBodyResponse()
  testFrameSizeValidation()
  echo ""
  echo "All HTTP/2 tests passed!"

when isMainModule:
  main()
