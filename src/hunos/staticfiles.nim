import std/os, std/strutils, std/times

type
  StaticConfig* = object
    root*: string          # Filesystem root directory
    urlPrefix*: string     # URL prefix (e.g., "/static")
    indexFile*: string     # Default file for directories (e.g., "index.html")
    maxAge*: int           # Cache-Control max-age in seconds

  FileEntry* = object
    filePath*: string
    contentType*: string
    content*: string
    lastModified*: float

proc newStaticConfig*(
  root: string,
  urlPrefix: string = "/static",
  indexFile: string = "index.html",
  maxAge: int = 3600
): StaticConfig =
  StaticConfig(
    root: root,
    urlPrefix: urlPrefix,
    indexFile: indexFile,
    maxAge: maxAge
  )

proc guessContentType*(ext: string): string =
  case ext.toLowerAscii()
  of ".html", ".htm": "text/html; charset=utf-8"
  of ".css": "text/css; charset=utf-8"
  of ".js": "application/javascript; charset=utf-8"
  of ".json": "application/json; charset=utf-8"
  of ".xml": "application/xml; charset=utf-8"
  of ".png": "image/png"
  of ".jpg", ".jpeg": "image/jpeg"
  of ".gif": "image/gif"
  of ".svg": "image/svg+xml"
  of ".ico": "image/x-icon"
  of ".woff": "font/woff"
  of ".woff2": "font/woff2"
  of ".ttf": "font/ttf"
  of ".txt": "text/plain; charset=utf-8"
  of ".pdf": "application/pdf"
  of ".zip": "application/zip"
  of ".mp4": "video/mp4"
  of ".webm": "video/webm"
  of ".webp": "image/webp"
  of ".wasm": "application/wasm"
  else: "application/octet-stream"

proc serveFile*(config: StaticConfig, urlPath: string): FileEntry =
  # Strip the URL prefix
  var relPath = urlPath
  if config.urlPrefix.len > 0 and relPath.startsWith(config.urlPrefix):
    relPath = relPath[config.urlPrefix.len .. ^1]
  if relPath.len == 0 or relPath[0] != '/':
    relPath = "/" & relPath

  # Security: prevent directory traversal
  if ".." in relPath:
    return FileEntry()

  let filePath = config.root / relPath[1 .. ^1]
  let normalized = filePath.normalizedPath()
  let rootNormalized = config.root.normalizedPath()
  if not normalized.startsWith(rootNormalized):
    return FileEntry()
  if not fileExists(filePath):
    # Try index file for directories
    let indexPath = filePath / config.indexFile
    if fileExists(indexPath):
      let ext = indexPath.splitFile().ext
      return FileEntry(
        filePath: indexPath,
        contentType: guessContentType(ext),
        content: readFile(indexPath),
        lastModified: getLastModificationTime(indexPath).toUnixFloat()
      )
    return FileEntry()

  let ext = filePath.splitFile().ext
  FileEntry(
    filePath: filePath,
    contentType: guessContentType(ext),
    content: readFile(filePath),
    lastModified: getLastModificationTime(filePath).toUnixFloat()
  )
