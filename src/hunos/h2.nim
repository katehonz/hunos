## h2.nim
##
## HTTP/2 (h2c - cleartext) support for Hunos.
## Implements RFC 7540 (HTTP/2) and RFC 7541 (HPACK).
##
## This module provides:
## - HTTP/2 frame parsing and encoding
## - HPACK header compression/decompression
## - Connection and stream state management
## - h2c (cleartext HTTP/2) connection upgrade

import std/tables, std/strutils

# ============================================================
# Frame Types (RFC 7540 Section 6)
# ============================================================

type
  FrameType* = enum
    ftData         = 0x0'u8
    ftHeaders      = 0x1'u8
    ftPriority     = 0x2'u8
    ftRstStream    = 0x3'u8
    ftSettings     = 0x4'u8
    ftPushPromise  = 0x5'u8
    ftPing         = 0x6'u8
    ftGoaway       = 0x7'u8
    ftWindowUpdate = 0x8'u8
    ftContinuation = 0x9'u8

  FrameFlag* = enum
    ffEndStream  = 0x01
    ffEndHeaders = 0x04
    ffPadded     = 0x08
    ffPriority   = 0x20

const
  ffAck* = 0x01'u8  # Same bit as ffEndStream, used for SETTINGS/PING

type
  Frame* = object
    frameType*: FrameType
    flags*: uint8
    streamId*: uint32
    payload*: string

  ErrorCode* = enum
    ecNoError            = 0x0'u32
    ecProtocolError      = 0x1'u32
    ecInternalError      = 0x2'u32
    ecFlowControlError   = 0x3'u32
    ecSettingsTimeout    = 0x4'u32
    ecStreamClosed       = 0x5'u32
    ecFrameSizeError     = 0x6'u32
    ecRefusedStream      = 0x7'u32
    ecCancel             = 0x8'u32
    ecCompressionError   = 0x9'u32
    ecConnectError       = 0xa'u32
    ecEnhanceYourCalm    = 0xb'u32
    ecInadequateSecurity = 0xc'u32
    ecHttp1_1Required    = 0xd'u32

  SettingsParam* = enum
    spHeaderTableSize      = 0x1'u16
    spEnablePush           = 0x2'u16
    spMaxConcurrentStreams = 0x3'u16
    spInitialWindowSize    = 0x4'u16
    spMaxFrameSize         = 0x5'u16
    spMaxHeaderListSize    = 0x6'u16

  H2StreamState* = enum
    ssIdle
    ssReservedLocal
    ssReservedRemote
    ssOpen
    ssHalfClosedLocal
    ssHalfClosedRemote
    ssClosed

  H2Stream* = object
    id*: uint32
    state*: H2StreamState
    headers*: seq[(string, string)]
    body*: string
    endHeaders*: bool
    endStream*: bool
    windowSize*: int32

  H2Connection* = object
    maxFrameSize*: uint32
    headerTableSize*: uint32
    enablePush*: bool
    maxConcurrentStreams*: uint32
    initialWindowSize*: int32
    maxHeaderListSize*: uint32
    streams*: Table[uint32, H2Stream]
    nextStreamId*: uint32
    encoderDynamicTable*: seq[(string, string)]
    encoderDynamicTableSize*: int
    decoderDynamicTable*: seq[(string, string)]
    decoderDynamicTableSize*: int
    lastStreamId*: uint32
    goawaySent*: bool
    goawayReceived*: bool
    sendWindow*: int32
    recvWindow*: int32

const
  connectionPreface* = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
  defaultMaxFrameSize* = 16384'u32
  defaultHeaderTableSize* = 4096'u32
  defaultInitialWindowSize* = 65535'i32
  defaultMaxConcurrentStreams* = 100'u32
  maxFrameSizeLimit* = 16777215'u32

# ============================================================
# HPACK Static Table (RFC 7541 Appendix A)
# ============================================================

const
  hpackStaticTable*: array[62, (string, string)] = [
    ("", ""),                                           # 0 (unused)
    (":authority", ""),                                 # 1
    (":method", "GET"),                                 # 2
    (":method", "POST"),                                # 3
    (":path", "/"),                                     # 4
    (":path", "/index.html"),                           # 5
    (":scheme", "http"),                                # 6
    (":scheme", "https"),                               # 7
    (":status", "200"),                                 # 8
    (":status", "204"),                                 # 9
    (":status", "206"),                                 # 10
    (":status", "304"),                                 # 11
    (":status", "400"),                                 # 12
    (":status", "404"),                                 # 13
    (":status", "500"),                                 # 14
    ("accept-charset", ""),                             # 15
    ("accept-encoding", "gzip, deflate"),               # 16
    ("accept-language", ""),                            # 17
    ("accept-ranges", ""),                              # 18
    ("accept", ""),                                     # 19
    ("access-control-allow-origin", ""),                # 20
    ("age", ""),                                        # 21
    ("allow", ""),                                      # 22
    ("authorization", ""),                              # 23
    ("cache-control", ""),                              # 24
    ("content-disposition", ""),                        # 25
    ("content-encoding", ""),                           # 26
    ("content-language", ""),                           # 27
    ("content-length", ""),                             # 28
    ("content-location", ""),                           # 29
    ("content-range", ""),                              # 30
    ("content-type", ""),                               # 31
    ("cookie", ""),                                     # 32
    ("date", ""),                                       # 33
    ("etag", ""),                                       # 34
    ("expect", ""),                                     # 35
    ("expires", ""),                                    # 36
    ("from", ""),                                       # 37
    ("host", ""),                                       # 38
    ("if-match", ""),                                   # 39
    ("if-modified-since", ""),                          # 40
    ("if-none-match", ""),                              # 41
    ("if-range", ""),                                   # 42
    ("if-unmodified-since", ""),                        # 43
    ("last-modified", ""),                              # 44
    ("link", ""),                                       # 45
    ("location", ""),                                   # 46
    ("max-forwards", ""),                               # 47
    ("proxy-authenticate", ""),                         # 48
    ("proxy-authorization", ""),                        # 49
    ("range", ""),                                      # 50
    ("referer", ""),                                    # 51
    ("refresh", ""),                                    # 52
    ("retry-after", ""),                                # 53
    ("server", ""),                                     # 54
    ("set-cookie", ""),                                 # 55
    ("strict-transport-security", ""),                  # 56
    ("transfer-encoding", ""),                          # 57
    ("user-agent", ""),                                 # 58
    ("vary", ""),                                       # 59
    ("via", ""),                                        # 60
    ("www-authenticate", ""),                           # 61
  ]

# ============================================================
# Frame Parsing / Encoding
# ============================================================

const
  frameHeaderLen* = 9

proc parseFrame*(data: openArray[char]): (Frame, int) =
  if data.len < frameHeaderLen:
    return (Frame(), 0)

  let length = (data[0].uint32 shl 16) or (data[1].uint32 shl 8) or data[2].uint32
  if length > maxFrameSizeLimit:
    return (Frame(), -1)

  let totalLen = frameHeaderLen + length.int
  if data.len < totalLen:
    return (Frame(), 0)

  let frameType = FrameType(data[3])
  let flags = data[4].uint8
  let streamId = ((data[5].uint32 and 0x7F'u32) shl 24) or
                 (data[6].uint32 shl 16) or
                 (data[7].uint32 shl 8) or
                 data[8].uint32

  var payload = newString(length.int)
  if length > 0:
    for i in 0 ..< length.int:
      payload[i] = data[frameHeaderLen + i]

  result = (Frame(
    frameType: frameType,
    flags: flags,
    streamId: streamId,
    payload: payload
  ), totalLen)

proc encodeFrame*(frame: Frame): string =
  let length = frame.payload.len
  result = newString(frameHeaderLen + length)

  result[0] = char((length shr 16) and 0xFF)
  result[1] = char((length shr 8) and 0xFF)
  result[2] = char(length and 0xFF)
  result[3] = char(frame.frameType.uint8)
  result[4] = char(frame.flags)
  result[5] = char((frame.streamId shr 24) and 0x7F)
  result[6] = char((frame.streamId shr 16) and 0xFF)
  result[7] = char((frame.streamId shr 8) and 0xFF)
  result[8] = char(frame.streamId and 0xFF)

  for i in 0 ..< length:
    result[frameHeaderLen + i] = frame.payload[i]

proc makeDataFrame*(streamId: uint32, data: string, endStream: bool = true): Frame =
  result.frameType = ftData
  result.flags = if endStream: uint8(ffEndStream) else: 0'u8
  result.streamId = streamId
  result.payload = data

proc makeSettingsFrame*(ack: bool = false): Frame =
  result.frameType = ftSettings
  result.flags = if ack: uint8(ffAck) else: 0'u8
  result.streamId = 0
  result.payload = ""

proc makeGoawayFrame*(lastStreamId: uint32, errorCode: ErrorCode): Frame =
  result.frameType = ftGoaway
  result.flags = 0
  result.streamId = 0
  result.payload = newString(8)
  result.payload[0] = char((lastStreamId shr 24) and 0x7F)
  result.payload[1] = char((lastStreamId shr 16) and 0xFF)
  result.payload[2] = char((lastStreamId shr 8) and 0xFF)
  result.payload[3] = char(lastStreamId and 0xFF)
  let code = errorCode.uint32
  result.payload[4] = char((code shr 24) and 0xFF)
  result.payload[5] = char((code shr 16) and 0xFF)
  result.payload[6] = char((code shr 8) and 0xFF)
  result.payload[7] = char(code and 0xFF)

proc makePingFrame*(opaque: uint64, ack: bool = false): Frame =
  result.frameType = ftPing
  result.flags = if ack: uint8(ffAck) else: 0'u8
  result.streamId = 0
  result.payload = newString(8)
  for i in 0 ..< 8:
    result.payload[i] = char((opaque shr (56 - i * 8)) and 0xFF)

proc makeWindowUpdateFrame*(streamId: uint32, increment: uint32): Frame =
  result.frameType = ftWindowUpdate
  result.flags = 0
  result.streamId = streamId
  result.payload = newString(4)
  result.payload[0] = char((increment shr 24) and 0x7F)
  result.payload[1] = char((increment shr 16) and 0xFF)
  result.payload[2] = char((increment shr 8) and 0xFF)
  result.payload[3] = char(increment and 0xFF)

proc makeRstStreamFrame*(streamId: uint32, errorCode: ErrorCode): Frame =
  result.frameType = ftRstStream
  result.flags = 0
  result.streamId = streamId
  let code = errorCode.uint32
  result.payload = newString(4)
  result.payload[0] = char((code shr 24) and 0xFF)
  result.payload[1] = char((code shr 16) and 0xFF)
  result.payload[2] = char((code shr 8) and 0xFF)
  result.payload[3] = char(code and 0xFF)

# ============================================================
# HPACK Integer Encoding (RFC 7541 Section 5.1)
# ============================================================

proc encodeHpackInt*(value: uint32, prefixBits: uint8): string =
  let maxPrefix = (1'u32 shl prefixBits) - 1
  if value < maxPrefix:
    result = newString(1)
    result[0] = char(value)
  else:
    result = newString(1)
    result[0] = char(maxPrefix)
    var remaining = value - maxPrefix
    while remaining >= 128:
      result.add(char((remaining mod 128) + 128))
      remaining = remaining shr 7
    result.add(char(remaining))

proc decodeHpackInt*(data: openArray[char], offset: int, prefixBits: uint8): (uint32, int) =
  let maxPrefix = (1'u8 shl prefixBits) - 1
  if offset >= data.len:
    return (0'u32, offset)

  var value = (data[offset].uint8 and maxPrefix).uint32
  var pos = offset + 1

  if value < maxPrefix.uint32:
    return (value, pos)

  var shift = 0
  while pos < data.len:
    let b = data[pos].uint8
    value += (b and 0x7F).uint32 shl shift
    pos += 1
    shift += 7
    if (b and 0x80) == 0:
      break

  result = (value, pos)

# ============================================================
# HPACK String Encoding (RFC 7541 Section 5.2)
# ============================================================

proc encodeHpackString*(s: string, huffman: bool = false): string =
  if not huffman:
    result = encodeHpackInt(s.len.uint32, 7)
    result[0] = char(result[0].uint8 and 0x7F'u8)  # Huffman bit = 0
    result &= s
  else:
    # Simple huffman not implemented, fall back to no-huffman
    result = encodeHpackInt(s.len.uint32, 7)
    result[0] = char(result[0].uint8 and 0x7F'u8)
    result &= s

proc decodeHpackString*(data: openArray[char], offset: int): (string, int) =
  if offset >= data.len:
    return ("", offset)

  let huffman = (data[offset].uint8 and 0x80) != 0
  let (strLen, pos) = decodeHpackInt(data, offset, 7)

  if pos + strLen.int > data.len:
    return ("", offset)

  result = (newString(strLen.int), pos + strLen.int)
  for i in 0 ..< strLen.int:
    result[0][i] = data[pos + i]

  # Huffman decoding not implemented; treat as raw (valid for no-huffman)
  discard huffman

# ============================================================
# HPACK Header Table (RFC 7541 Section 2.3.2)
# ============================================================

proc findInStaticTable*(name, value: string): int =
  for i in 1 ..< hpackStaticTable.len:
    if hpackStaticTable[i][0] == name and hpackStaticTable[i][1] == value:
      return i
  return 0

proc findNameInStaticTable*(name: string): int =
  for i in 1 ..< hpackStaticTable.len:
    if hpackStaticTable[i][0] == name:
      return i
  return 0

proc findInDynamicTable*(conn: H2Connection, name, value: string): int =
  for i, entry in conn.decoderDynamicTable:
    if entry[0] == name and entry[1] == value:
      return hpackStaticTable.len + i
  return 0

proc findNameInDynamicTable*(conn: H2Connection, name: string): int =
  for i, entry in conn.decoderDynamicTable:
    if entry[0] == name:
      return hpackStaticTable.len + i
  return 0

proc addToDynamicTable*(conn: var H2Connection, name, value: string) =
  let entrySize = name.len + value.len + 32
  while conn.decoderDynamicTableSize + entrySize > conn.headerTableSize.int and
        conn.decoderDynamicTable.len > 0:
    let removed = conn.decoderDynamicTable.pop()
    conn.decoderDynamicTableSize -= removed[0].len + removed[1].len + 32
  if entrySize <= conn.headerTableSize.int:
    conn.decoderDynamicTable.insert((name, value), 0)
    conn.decoderDynamicTableSize += entrySize

# ============================================================
# HPACK Decoder (RFC 7541 Section 4)
# ============================================================

proc decodeHpackHeaders*(conn: var H2Connection, data: string): seq[(string, string)] =
  result = @[]
  var pos = 0

  while pos < data.len:
    let firstByte = data[pos].uint8

    if (firstByte and 0x80) != 0:
      # Indexed Header Field (Section 6.1)
      let (index, newPos) = decodeHpackInt(data, pos, 7)
      pos = newPos

      if index == 0:
        break

      if index < hpackStaticTable.len.uint32:
        result.add(hpackStaticTable[index.int])
      else:
        let dynIdx = index.int - hpackStaticTable.len
        if dynIdx < conn.decoderDynamicTable.len:
          result.add(conn.decoderDynamicTable[dynIdx])

    elif (firstByte and 0xE0) == 0x20:
      # Dynamic Table Size Update (Section 6.3)
      let (newSize, newPos) = decodeHpackInt(data, pos, 5)
      pos = newPos
      conn.headerTableSize = newSize
      conn.decoderDynamicTableSize = 0
      conn.decoderDynamicTable.setLen(0)

    elif (firstByte and 0x40) != 0:
      # Literal Header Field with Incremental Indexing (Section 6.2.1)
      let (index, midPos) = decodeHpackInt(data, pos, 6)
      pos = midPos
      var name: string
      if index == 0:
        (name, pos) = decodeHpackString(data, pos)
      elif index < hpackStaticTable.len.uint32:
        name = hpackStaticTable[index.int][0]
      else:
        let dynIdx = index.int - hpackStaticTable.len
        if dynIdx < conn.decoderDynamicTable.len:
          name = conn.decoderDynamicTable[dynIdx][0]

      var value: string
      (value, pos) = decodeHpackString(data, pos)
      result.add((name, value))
      addToDynamicTable(conn, name, value)

    elif (firstByte and 0xF0) == 0x00:
      # Literal Header Field without Indexing (Section 6.2.2)
      let (index, midPos) = decodeHpackInt(data, pos, 4)
      pos = midPos
      var name: string
      if index == 0:
        (name, pos) = decodeHpackString(data, pos)
      elif index < hpackStaticTable.len.uint32:
        name = hpackStaticTable[index.int][0]
      else:
        let dynIdx = index.int - hpackStaticTable.len
        if dynIdx < conn.decoderDynamicTable.len:
          name = conn.decoderDynamicTable[dynIdx][0]

      var value: string
      (value, pos) = decodeHpackString(data, pos)
      result.add((name, value))

    elif (firstByte and 0xF0) == 0x10:
      # Literal Header Field never indexed (Section 6.2.3)
      let (index, midPos) = decodeHpackInt(data, pos, 4)
      pos = midPos
      var name: string
      if index == 0:
        (name, pos) = decodeHpackString(data, pos)
      elif index < hpackStaticTable.len.uint32:
        name = hpackStaticTable[index.int][0]
      else:
        let dynIdx = index.int - hpackStaticTable.len
        if dynIdx < conn.decoderDynamicTable.len:
          name = conn.decoderDynamicTable[dynIdx][0]

      var value: string
      (value, pos) = decodeHpackString(data, pos)
      result.add((name, value))

    else:
      break

# ============================================================
# HPACK Encoder
# ============================================================

proc encodeHpackHeaders*(conn: var H2Connection, headers: seq[(string, string)]): string =
  result = ""
  for (name, value) in headers:
    let fullMatch = findInStaticTable(name, value)
    if fullMatch > 0:
      var encoded = encodeHpackInt(fullMatch.uint32, 7)
      encoded[0] = char(encoded[0].uint8 or 0x80)
      result &= encoded
    else:
      let nameMatch = findNameInStaticTable(name)
      if nameMatch > 0:
        # Name is indexed, value is literal
        var encoded = encodeHpackInt(nameMatch.uint32, 6)
        encoded[^1] = char(encoded[^1].uint8 or 0x40)
        encoded &= encodeHpackString(value, false)
        result &= encoded
      else:
        # Both name and value are literal
        var encoded = encodeHpackInt(0'u32, 6)
        encoded[^1] = char(encoded[^1].uint8 or 0x40)
        encoded &= encodeHpackString(name, false)
        encoded &= encodeHpackString(value, false)
        result &= encoded

proc encodeHpackHeadersStandalone*(headers: seq[(string, string)]): string =
  result = ""
  for (name, value) in headers:
    let fullMatch = findInStaticTable(name, value)
    if fullMatch > 0:
      var encoded = encodeHpackInt(fullMatch.uint32, 7)
      encoded[0] = char(encoded[0].uint8 or 0x80)
      result &= encoded
    else:
      let nameMatch = findNameInStaticTable(name)
      if nameMatch > 0:
        var encoded = encodeHpackInt(nameMatch.uint32, 6)
        encoded[^1] = char(encoded[^1].uint8 or 0x40)
        encoded &= encodeHpackString(value, false)
        result &= encoded
      else:
        var encoded = encodeHpackInt(0'u32, 6)
        encoded[^1] = char(encoded[^1].uint8 or 0x40)
        encoded &= encodeHpackString(name, false)
        encoded &= encodeHpackString(value, false)
        result &= encoded

# ============================================================
# Connection Management
# ============================================================

proc newH2Connection*(): H2Connection =
  result.maxFrameSize = defaultMaxFrameSize
  result.headerTableSize = defaultHeaderTableSize
  result.enablePush = false
  result.maxConcurrentStreams = defaultMaxConcurrentStreams
  result.initialWindowSize = defaultInitialWindowSize
  result.maxHeaderListSize = 16384'u32
  result.streams = initTable[uint32, H2Stream]()
  result.nextStreamId = 2'u32
  result.decoderDynamicTable = @[]
  result.decoderDynamicTableSize = 0
  result.sendWindow = defaultInitialWindowSize
  result.recvWindow = defaultInitialWindowSize

proc getOrCreateStream*(conn: var H2Connection, streamId: uint32) =
  if streamId notin conn.streams:
    conn.streams[streamId] = H2Stream(
      id: streamId,
      state: ssIdle,
      headers: @[],
      body: "",
      endHeaders: false,
      endStream: false,
      windowSize: conn.initialWindowSize
    )
  conn.lastStreamId = max(conn.lastStreamId, streamId)

proc streamRef*(conn: var H2Connection, streamId: uint32): var H2Stream =
  conn.streams.mgetOrPut(streamId, H2Stream())

proc closeStream*(conn: var H2Connection, streamId: uint32) =
  if streamId in conn.streams:
    conn.streams.mgetOrPut(streamId, H2Stream()).state = ssClosed

proc parseSettingsPayload*(payload: string): seq[(SettingsParam, uint32)] =
  result = @[]
  var i = 0
  while i + 5 < payload.len:
    let id = (payload[i].uint16 shl 8) or payload[i + 1].uint16
    let value = (payload[i + 2].uint32 shl 24) or (payload[i + 3].uint32 shl 16) or
                (payload[i + 4].uint32 shl 8) or payload[i + 5].uint32
    result.add((SettingsParam(id), value))
    i += 6

proc applySettings*(conn: var H2Connection, settings: seq[(SettingsParam, uint32)]) =
  for (param, value) in settings:
    case param
    of spHeaderTableSize:
      conn.headerTableSize = value
    of spEnablePush:
      conn.enablePush = value == 1
    of spMaxConcurrentStreams:
      conn.maxConcurrentStreams = value
    of spInitialWindowSize:
      let delta = value.int32 - conn.initialWindowSize
      conn.initialWindowSize = value.int32
      for sid, stream in conn.streams.mpairs:
        stream.windowSize += delta
    of spMaxFrameSize:
      if value >= 16384 and value <= maxFrameSizeLimit:
        conn.maxFrameSize = value
    of spMaxHeaderListSize:
      conn.maxHeaderListSize = value

proc encodeSettingsPayload*(settings: seq[(SettingsParam, uint32)]): string =
  result = newString(settings.len * 6)
  for i, (param, value) in settings:
    let offset = i * 6
    result[offset]     = char((param.uint32 shr 8) and 0xFF)
    result[offset + 1] = char(param.uint32 and 0xFF)
    result[offset + 2] = char((value shr 24) and 0xFF)
    result[offset + 3] = char((value shr 16) and 0xFF)
    result[offset + 4] = char((value shr 8) and 0xFF)
    result[offset + 5] = char(value and 0xFF)

# ============================================================
# Headers Frame Parsing (RFC 7540 Section 6.2)
# ============================================================

proc parseHeadersPayload*(conn: var H2Connection, frame: Frame): seq[(string, string)] =
  var payload = frame.payload
  var pos = 0

  if (frame.flags and uint8(ffPadded)) != 0:
    let padLength = payload[pos].uint8
    pos += 1
    payload = payload[0 ..< payload.len - padLength.int]

  if (frame.flags and uint8(ffPriority)) != 0:
    pos += 5  # skip stream dep (4) + weight (1)

  let headerBlockFragment = payload[pos ..< payload.len]
  result = decodeHpackHeaders(conn, headerBlockFragment)

# ============================================================
# Response Encoding
# ============================================================

proc encodeResponseFrames*(
  conn: var H2Connection,
  streamId: uint32,
  statusCode: int,
  headers: seq[(string, string)],
  body: string
): seq[string] =
  result = @[]

  var responseHeaders: seq[(string, string)] = @[(":status", $statusCode)]
  for (k, v) in headers:
    if k != ":status":
      responseHeaders.add((k.toLowerAscii, v))

  let headerBlock = encodeHpackHeaders(conn, responseHeaders)
  var headersFrame = Frame(
    frameType: ftHeaders,
    flags: uint8(ffEndHeaders),
    streamId: streamId,
    payload: headerBlock
  )

  if body.len == 0:
    headersFrame.flags = headersFrame.flags or uint8(ffEndStream)

  result.add(encodeFrame(headersFrame))

  if body.len > 0:
    let dataFrame = makeDataFrame(streamId, body, endStream = true)
    result.add(encodeFrame(dataFrame))

proc encodeResponseFramesStandalone*(
  streamId: uint32,
  statusCode: int,
  headers: seq[(string, string)],
  body: string
): seq[string] =
  result = @[]

  var responseHeaders: seq[(string, string)] = @[(":status", $statusCode)]
  for (k, v) in headers:
    if k != ":status":
      responseHeaders.add((k.toLowerAscii, v))

  let headerBlock = encodeHpackHeadersStandalone(responseHeaders)
  var headersFrame = Frame(
    frameType: ftHeaders,
    flags: uint8(ffEndHeaders),
    streamId: streamId,
    payload: headerBlock
  )

  if body.len == 0:
    headersFrame.flags = headersFrame.flags or uint8(ffEndStream)

  result.add(encodeFrame(headersFrame))

  if body.len > 0:
    let dataFrame = makeDataFrame(streamId, body, endStream = true)
    result.add(encodeFrame(dataFrame))
