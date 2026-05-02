import std/bitops

proc sha1Block(state: var array[5, uint32], chunk: array[16, uint32]) =
  var w: array[80, uint32]
  for i in 0 ..< 16:
    w[i] = chunk[i]
  for i in 16 ..< 80:
    w[i] = rotateLeftBits(w[i-3] xor w[i-8] xor w[i-14] xor w[i-16], 1)

  var
    a = state[0]
    b = state[1]
    c = state[2]
    d = state[3]
    e = state[4]

  for i in 0 ..< 80:
    var f, k: uint32
    if i < 20:
      f = (b and c) or ((not b) and d)
      k = 0x5A827999'u32
    elif i < 40:
      f = b xor c xor d
      k = 0x6ED9EBA1'u32
    elif i < 60:
      f = (b and c) or (b and d) or (c and d)
      k = 0x8F1BBCDC'u32
    else:
      f = b xor c xor d
      k = 0xCA62C1D6'u32

    let temp = rotateLeftBits(a, 5) + f + e + k + w[i]
    e = d
    d = c
    c = rotateLeftBits(b, 30)
    b = a
    a = temp

  state[0] += a
  state[1] += b
  state[2] += c
  state[3] += d
  state[4] += e

proc sha1*(data: string): array[20, uint8] =
  var state: array[5, uint32]
  state[0] = 0x67452301'u32
  state[1] = 0xEFCDAB89'u32
  state[2] = 0x98BADCFE'u32
  state[3] = 0x10325476'u32
  state[4] = 0xC3D2E1F0'u32

  let msgLen = data.len
  let bitLen = msgLen.uint64 * 8

  var paddedLen = msgLen + 1 # +1 for 0x80
  while paddedLen mod 64 != 56:
    inc paddedLen

  var padded = newString(paddedLen + 8)
  for i in 0 ..< msgLen:
    padded[i] = data[i]
  padded[msgLen] = cast[char](0x80)
  for i in msgLen + 1 ..< paddedLen:
    padded[i] = cast[char](0)

  # Big-endian 64-bit length
  for i in 0 ..< 8:
    padded[paddedLen + i] = cast[char]((bitLen shr (56 - i * 8)) and 0xFF)

  # Process 64-byte blocks
  var offset = 0
  while offset < padded.len:
    var chunk: array[16, uint32]
    for i in 0 ..< 16:
      let base = offset + i * 4
      chunk[i] = (cast[uint8](padded[base]).uint32 shl 24) or
                  (cast[uint8](padded[base + 1]).uint32 shl 16) or
                  (cast[uint8](padded[base + 2]).uint32 shl 8) or
                  cast[uint8](padded[base + 3]).uint32
    sha1Block(state, chunk)
    offset += 64

  for i in 0 ..< 5:
    result[i * 4] = ((state[i] shr 24) and 0xFF).uint8
    result[i * 4 + 1] = ((state[i] shr 16) and 0xFF).uint8
    result[i * 4 + 2] = ((state[i] shr 8) and 0xFF).uint8
    result[i * 4 + 3] = (state[i] and 0xFF).uint8

proc base64Encode*(data: openArray[uint8]): string =
  const chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  let inLen = data.len
  let outLen = ((inLen + 2) div 3) * 4
  result = newString(outLen)
  var j = 0
  var i = 0
  while i < inLen:
    let b0 = data[i].uint32
    let b1 = if i + 1 < inLen: data[i + 1].uint32 else: 0'u32
    let b2 = if i + 2 < inLen: data[i + 2].uint32 else: 0'u32

    result[j] = chars[((b0 shr 2) and 0x3F).int]
    result[j + 1] = chars[(((b0 shl 4) or (b1 shr 4)) and 0x3F).int]

    if i + 1 < inLen:
      result[j + 2] = chars[(((b1 shl 2) or (b2 shr 6)) and 0x3F).int]
    else:
      result[j + 2] = '='

    if i + 2 < inLen:
      result[j + 3] = chars[(b2 and 0x3F).int]
    else:
      result[j + 3] = '='

    i += 3
    j += 4
