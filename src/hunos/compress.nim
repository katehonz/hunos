when not defined(hunosNoCompression):
  import zippy, std/strutils

const
  compressMinLen* = 860

proc canCompress*(acceptEncoding: string): bool =
  when defined(hunosNoCompression):
    return false
  else:
    return "gzip" in acceptEncoding or "deflate" in acceptEncoding

proc compressBody*(body: string, acceptEncoding: string): tuple[data: string, encoding: string] =
  when defined(hunosNoCompression):
    return (body, "")
  else:
    if body.len < compressMinLen:
      return (body, "")
    if "gzip" in acceptEncoding:
      try:
        return (compress(body, dataFormat = dfGzip), "gzip")
      except ZippyError:
        return (body, "")
    elif "deflate" in acceptEncoding:
      try:
        return (compress(body, dataFormat = dfDeflate), "deflate")
      except ZippyError:
        return (body, "")
    return (body, "")
