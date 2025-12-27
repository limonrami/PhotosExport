import Foundation
import Photos
import ImageIO
import UniformTypeIdentifiers

actor LineLogger {
  private let handle: FileHandle

  init(handle: FileHandle) {
    self.handle = handle
  }

  init(fileURL: URL) throws {
    if !FileManager.default.fileExists(atPath: fileURL.path) {
      FileManager.default.createFile(atPath: fileURL.path, contents: nil)
    }
    self.handle = try FileHandle(forWritingTo: fileURL)
    try self.handle.seekToEnd()
  }

  func log(_ message: String) {
    let line = "\(isoTimestamp()) \(message)\n"
    if let data = line.data(using: .utf8) {
      do {
        try handle.write(contentsOf: data)
      } catch {
        // Best-effort logging; ignore failures.
      }
    }
  }
}

func isoTimestamp(_ date: Date = Date()) -> String {
  // RFC 3339-ish, good for logs.
  let f = ISO8601DateFormatter()
  f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  return f.string(from: date)
}

func captureTimestampString(_ date: Date) -> String {
  let f = DateFormatter()
  f.locale = Locale(identifier: "en_US_POSIX")
  f.calendar = Calendar(identifier: .gregorian)
  f.timeZone = TimeZone.current
  f.dateFormat = "yyyyMMddHHmmss"
  return f.string(from: date)
}

func fnv1a64(_ s: String) -> UInt64 {
  // Stable, deterministic hash (do not use Swift's hashValue).
  let prime: UInt64 = 1099511628211
  var hash: UInt64 = 14695981039346656037
  for b in s.utf8 {
    hash ^= UInt64(b)
    hash &*= prime
  }
  return hash
}

func alphaLetter(from hash: UInt64, offset: Int = 0) -> Character {
  let idx = Int((hash % 26) + UInt64((offset % 26 + 26) % 26)) % 26
  return Character(UnicodeScalar(97 + idx)!)
}

func exportFilename(
  captureDate: Date,
  originalFilename: String,
  fallbackSeed: String,
  uti: String,
  usedNames: inout Set<String>
) -> String {
  let ts = captureTimestampString(captureDate)

  let preferredExt = UTType(uti)?.preferredFilenameExtension
  let originalExt = (originalFilename as NSString).pathExtension
  let extRaw = !originalExt.isEmpty ? originalExt : (preferredExt ?? "")
  let ext = extRaw.lowercased()

  // First try the plain timestamp name.
  let baseCandidate = ext.isEmpty ? ts : "\(ts).\(ext)"
  if !usedNames.contains(baseCandidate) {
    usedNames.insert(baseCandidate)
    return baseCandidate
  }

  // Collision: add a deterministic letter derived from the resource name + metadata.
  // If Photos provides no filename, fall back to metadata-only.
  let seed = originalFilename.isEmpty ? fallbackSeed : "\(originalFilename)|\(fallbackSeed)"

  // Ensure uniqueness by advancing the letter if needed.
  // Wraps after 'z' back to 'a'. If all 26 letters collide, re-hash with a cycle
  // suffix and try another alphabet cycle (prevents an infinite loop).
  var attempt = 0
  while true {
    let cycle = attempt / 26
    let offset = attempt % 26
    let h = cycle == 0 ? fnv1a64(seed) : fnv1a64("\(seed)#\(cycle)")
    let letter = alphaLetter(from: h, offset: offset)
    let stem = "\(ts)\(letter)"
    let candidate = ext.isEmpty ? stem : "\(stem).\(ext)"
    if !usedNames.contains(candidate) {
      usedNames.insert(candidate)
      return candidate
    }
    attempt += 1
  }
}

struct Settings {
  var logFile: URL? = nil
  var debug: Bool = false
  var incremental: Bool = false
}

func parseSettings(_ args: [String]) -> Settings {
  var settings = Settings()
  var i = 1
  while i < args.count {
    switch args[i] {
    case "--debug":
      settings.debug = true
      i += 1
    case "--incremental":
      settings.incremental = true
      i += 1
    case "--log-file":
      if i + 1 < args.count {
        settings.logFile = URL(fileURLWithPath: args[i + 1]).standardizedFileURL
        i += 2
      } else {
        i += 1
      }
    default:
      i += 1
    }
  }
  return settings
}

func logDebug(_ logger: LineLogger?, _ message: String) async {
  await logger?.log(message)
}

func logWarn(_ message: String) {
  fputs("Warning: \(message)\n", stderr)
}

func logError(_ message: String) {
  fputs("Error: \(message)\n", stderr)
}

func errorDetails(_ error: Error) -> String {
  let ns = error as NSError
  var parts: [String] = ["domain=\(ns.domain)", "code=\(ns.code)"]
  if !ns.localizedDescription.isEmpty {
    parts.append("desc=\(ns.localizedDescription)")
  }
  if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
    parts.append("underlying=\(underlying.domain)(\(underlying.code))")
    if !underlying.localizedDescription.isEmpty {
      parts.append("underDesc=\(underlying.localizedDescription)")
    }
  }
  // Keep userInfo compact but useful.
  if let reason = ns.userInfo[NSLocalizedFailureReasonErrorKey] as? String, !reason.isEmpty {
    parts.append("reason=\(reason)")
  }
  if let recovery = ns.userInfo[NSLocalizedRecoverySuggestionErrorKey] as? String, !recovery.isEmpty {
    parts.append("recovery=\(recovery)")
  }
  return parts.joined(separator: " ")
}

enum PhotosExportErrorInfoKey {
  static let assetIdentifier = "PhotosExportAssetIdentifier"
  static let captureTimestamp = "PhotosExportCaptureTimestamp"
  static let mediaType = "PhotosExportMediaType"
  static let mediaSubtypes = "PhotosExportMediaSubtypes"
  static let pixelSize = "PhotosExportPixelSize"
  static let duration = "PhotosExportDuration"
  static let failedResources = "PhotosExportFailedResources"
}

func appendLine(_ line: String, to url: URL) {
  guard let data = (line + "\n").data(using: .utf8) else { return }
  if FileManager.default.fileExists(atPath: url.path) == false {
    FileManager.default.createFile(atPath: url.path, contents: nil)
  }
  if let handle = try? FileHandle(forWritingTo: url) {
    _ = try? handle.seekToEnd()
    try? handle.write(contentsOf: data)
    try? handle.close()
  }
}

func appendBlock(_ header: String, lines: [String], to url: URL) {
  appendLine(header, to: url)
  for l in lines {
    appendLine("  \(l)", to: url)
  }
}

struct ProgressBar {
  let total: Int
  var current: Int = 0
  let width: Int = 32
  let start = Date()

  mutating func tick(_ label: String) {
    current += 1
    let pct = total == 0 ? 1.0 : Double(current) / Double(total)
    let filled = Int(Double(width) * pct)
    let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: max(0, width - filled))
    let elapsed = Int(Date().timeIntervalSince(start))
    let line = String(format: "\r[%@] %3d%% %d/%d %ds  %@", bar, Int(pct * 100), current, total, elapsed, label)
    FileHandle.standardError.write(Data(line.utf8))
    if current == total {
      FileHandle.standardError.write(Data("\n".utf8))
    }
  }
}

func ensureDir(_ url: URL, logger: LineLogger? = nil) async throws {
  var isDir: ObjCBool = false
  if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
    if isDir.boolValue {
      await logDebug(logger, "fs.dir exists path=\(url.path)")
      return
    }
    throw NSError(domain: "PhotosExport", code: 10, userInfo: [NSLocalizedDescriptionKey: "Path exists but is not a directory: \(url.path)"])
  }

  await logDebug(logger, "fs.dir create path=\(url.path)")
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
}

func sanitize(_ s: String) -> String {
  // Keep it simple: avoid path separators and weirdness.
  return s.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "-")
}

func monthString(_ date: Date) -> String {
  let cal = Calendar(identifier: .gregorian)
  let m = cal.component(.month, from: date)
  return String(format: "%02d", m)
}

func yearString(_ date: Date) -> String {
  let cal = Calendar(identifier: .gregorian)
  return String(cal.component(.year, from: date))
}

func currentYearRange() -> (start: Date, end: Date) {
  let cal = Calendar(identifier: .gregorian)
  let now = Date()
  let year = cal.component(.year, from: now)
  let start = cal.date(from: DateComponents(year: year, month: 1, day: 1, hour: 0, minute: 0, second: 0))!
  let end = cal.date(from: DateComponents(year: year, month: 12, day: 31, hour: 23, minute: 59, second: 59))!
  return (start, end)
}

func requestPhotosAccess(logger: LineLogger? = nil) async throws {
  let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
  await logDebug(logger, "photos.auth status=\(status.rawValue)")
  if status == .authorized || status == .limited { return }

  try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
    PHPhotoLibrary.requestAuthorization(for: .readWrite) { newStatus in
      if let logger {
        Task { await logger.log("photos.auth requestAuthorization result=\(newStatus.rawValue)") }
      }
      if newStatus == .authorized || newStatus == .limited {
        cont.resume(returning: ())
      } else {
        cont.resume(throwing: NSError(domain: "PhotosExport", code: 1, userInfo: [NSLocalizedDescriptionKey: "Photos access denied: \(newStatus)"]))
      }
    }
  }
}

func exportOriginalResource(asset: PHAsset, to folder: URL, logger: LineLogger? = nil) async throws -> URL {
  // Pick the "best" original resource for export.
  // For photos: .photo or .fullSizePhoto
  // For videos: .video or .fullSizeVideo
  let resources = PHAssetResource.assetResources(for: asset)

  func score(_ r: PHAssetResource) -> Int {
    switch r.type {
    case .fullSizePhoto, .fullSizeVideo: return 100
    case .photo, .video: return 80
    default: return 10
    }
  }

  guard let chosen = resources.max(by: { score($0) < score($1) }) else {
    throw NSError(domain: "PhotosExport", code: 2, userInfo: [NSLocalizedDescriptionKey: "No exportable resources"])
  }

  await logger?.log("asset.resource chosen asset=\(asset.localIdentifier) type=\(chosen.type.rawValue) uti=\(chosen.uniformTypeIdentifier) name=\(chosen.originalFilename)")

  let originalName = chosen.originalFilename
  let filename = sanitize(originalName.isEmpty ? UUID().uuidString : originalName)
  let destination = folder.appendingPathComponent(filename)

  await logger?.log("asset.export plan asset=\(asset.localIdentifier) mediaType=\(asset.mediaType.rawValue) resourceType=\(chosen.type.rawValue) original=\(originalName) dest=\(destination.path)")

  // If file exists, skip by creating a unique name (simple, safe behavior).
  var finalURL = destination
  if FileManager.default.fileExists(atPath: finalURL.path) {
    let ext = finalURL.pathExtension
    let base = finalURL.deletingPathExtension().lastPathComponent
    finalURL = folder.appendingPathComponent("\(base)-\(UUID().uuidString)").appendingPathExtension(ext)
    await logger?.log("fs.file collision original=\(destination.path) new=\(finalURL.path)")
  }

  let opts = PHAssetResourceRequestOptions()
  opts.isNetworkAccessAllowed = true

  await logger?.log("asset.export writeData begin asset=\(asset.localIdentifier) dest=\(finalURL.path) networkAllowed=\(opts.isNetworkAccessAllowed)")

  do {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
      PHAssetResourceManager.default().writeData(for: chosen, toFile: finalURL, options: opts) { err in
        if let err = err {
          cont.resume(throwing: err)
        } else {
          cont.resume(returning: ())
        }
      }
    }
  } catch {
    await logger?.log("asset.export writeData failed asset=\(asset.localIdentifier) dest=\(finalURL.path) error=\(error)")
    throw error
  }

  if let attrs = try? FileManager.default.attributesOfItem(atPath: finalURL.path),
     let size = attrs[.size] as? NSNumber {
    await logger?.log("asset.export done asset=\(asset.localIdentifier) path=\(finalURL.path) bytes=\(size.int64Value)")
  } else {
    await logger?.log("asset.export done asset=\(asset.localIdentifier) path=\(finalURL.path)")
  }

  return finalURL
}

func resourceTypeLabel(_ type: PHAssetResourceType) -> String {
  switch type {
  case .photo: return "photo"
  case .video: return "video"
  case .audio: return "audio"
  case .alternatePhoto: return "alternatePhoto"
  case .fullSizePhoto: return "fullSizePhoto"
  case .fullSizeVideo: return "fullSizeVideo"
  case .adjustmentData: return "adjustmentData"
  default: return "type\(type.rawValue)"
  }
}

func filenameForResource(asset: PHAsset, resource: PHAssetResource, captureDate: Date, usedNames: inout Set<String>) -> String {
  // Seed for deterministic collision suffix: include resource name + stable metadata.
  let metaSeed = [
    "asset=\(asset.localIdentifier)",
    "mediaType=\(asset.mediaType.rawValue)",
    "subtypes=\(asset.mediaSubtypes.rawValue)",
    "px=\(asset.pixelWidth)x\(asset.pixelHeight)",
    "dur=\(asset.duration)",
    "resType=\(resource.type.rawValue)",
    "uti=\(resource.uniformTypeIdentifier)",
  ].joined(separator: "|")

  return exportFilename(
    captureDate: captureDate,
    originalFilename: resource.originalFilename,
    fallbackSeed: metaSeed,
    uti: resource.uniformTypeIdentifier,
    usedNames: &usedNames
  )
}

func exportAllResources(
  asset: PHAsset,
  captureDate: Date,
  to folder: URL,
  incremental: Bool,
  errorLogURL: URL,
  logger: LineLogger? = nil
) async throws -> [URL] {
  let resources = PHAssetResource.assetResources(for: asset)
  await logDebug(logger, "asset.resources count=\(resources.count) asset=\(asset.localIdentifier)")

  var usedNames = Set<String>()
  var exported: [URL] = []
  exported.reserveCapacity(resources.count)

  var failures: [String] = []

  let opts = PHAssetResourceRequestOptions()
  opts.isNetworkAccessAllowed = true

  for (idx, r) in resources.enumerated() {
    let typeLabel = resourceTypeLabel(r.type)
    let filename = filenameForResource(asset: asset, resource: r, captureDate: captureDate, usedNames: &usedNames)
    let finalURL = folder.appendingPathComponent(filename)

    if incremental && FileManager.default.fileExists(atPath: finalURL.path) {
      await logDebug(logger, "asset.resource.skip existing asset=\(asset.localIdentifier) type=\(typeLabel) dest=\(finalURL.path)")
      exported.append(finalURL)
      continue
    }

    // Default behavior: overwrite any existing file at the destination.
    if !incremental && FileManager.default.fileExists(atPath: finalURL.path) {
      do {
        await logDebug(logger, "asset.resource.overwrite remove dest=\(finalURL.path)")
        try FileManager.default.removeItem(at: finalURL)
      } catch {
        let line = "\(Date()) asset=\(asset.localIdentifier) capture=\(captureTimestampString(captureDate)) resourceType=\(typeLabel) uti=\(r.uniformTypeIdentifier) name=\(r.originalFilename) dest=\(finalURL.path) removeExistingFailed \(errorDetails(error))"
        logError(line)
        await logDebug(logger, "asset.resource.overwrite failed \(line)")

        if let data = (line + "\n").data(using: .utf8) {
          if FileManager.default.fileExists(atPath: errorLogURL.path) == false {
            FileManager.default.createFile(atPath: errorLogURL.path, contents: nil)
          }
          if let handle = try? FileHandle(forWritingTo: errorLogURL) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
          }
        }
        // Cannot safely export to this destination.
        continue
      }
    }

    await logDebug(logger, "asset.resource.start asset=\(asset.localIdentifier) index=\(idx + 1)/\(resources.count) type=\(typeLabel) uti=\(r.uniformTypeIdentifier) name=\(r.originalFilename) dest=\(finalURL.path)")

    do {
      try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
        PHAssetResourceManager.default().writeData(for: r, toFile: finalURL, options: opts) { err in
          if let err = err {
            cont.resume(throwing: err)
          } else {
            cont.resume(returning: ())
          }
        }
      }
    } catch {
      let detail = errorDetails(error)
      let line = "\(Date()) asset=\(asset.localIdentifier) capture=\(captureTimestampString(captureDate)) resourceType=\(typeLabel) uti=\(r.uniformTypeIdentifier) name=\(r.originalFilename) dest=\(finalURL.path) \(detail)"
      failures.append("type=\(typeLabel) uti=\(r.uniformTypeIdentifier) name=\(r.originalFilename) dest=\(finalURL.lastPathComponent) \(detail)")

      logError(line)
      await logDebug(logger, "asset.resource.failed \(line)")

      // Best-effort append; do not fail the whole run on log writing.
      appendLine(line, to: errorLogURL)

      // Continue exporting other resources for this asset.
      continue
    }

    if let attrs = try? FileManager.default.attributesOfItem(atPath: finalURL.path),
       let size = attrs[.size] as? NSNumber {
      await logDebug(logger, "asset.resource.done asset=\(asset.localIdentifier) type=\(typeLabel) path=\(finalURL.path) bytes=\(size.int64Value)")
    } else {
      await logDebug(logger, "asset.resource.done asset=\(asset.localIdentifier) type=\(typeLabel) path=\(finalURL.path)")
    }

    exported.append(finalURL)
  }

  if !failures.isEmpty {
    // Surface an error to mark this asset as failed (caller will keep going).
    let capture = captureTimestampString(captureDate)
    let meta = "asset=\(asset.localIdentifier) capture=\(capture) mediaType=\(asset.mediaType.rawValue) subtypes=\(asset.mediaSubtypes.rawValue) px=\(asset.pixelWidth)x\(asset.pixelHeight) dur=\(asset.duration)"
    let failureSummary = failures.joined(separator: "; ")

    // Write a detailed block to the error log so it's useful even without --debug.
    appendBlock(
      "\(Date()) asset.failed \(meta) failures=\(failures.count)/\(resources.count)",
      lines: failures,
      to: errorLogURL
    )

    throw NSError(
      domain: "PhotosExport",
      code: 20,
      userInfo: [
        NSLocalizedDescriptionKey: "One or more resources failed to export (\(failures.count)/\(resources.count)) \(meta). Failed: \(failureSummary)",
        PhotosExportErrorInfoKey.assetIdentifier: asset.localIdentifier,
        PhotosExportErrorInfoKey.captureTimestamp: capture,
        PhotosExportErrorInfoKey.mediaType: asset.mediaType.rawValue,
        PhotosExportErrorInfoKey.mediaSubtypes: asset.mediaSubtypes.rawValue,
        PhotosExportErrorInfoKey.pixelSize: "\(asset.pixelWidth)x\(asset.pixelHeight)",
        PhotosExportErrorInfoKey.duration: asset.duration,
        PhotosExportErrorInfoKey.failedResources: failures,
      ]
    )
  }

  return exported
}

@main
enum Main {
  static func main() async {
    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser
    let exportBase = home.appendingPathComponent("Pictures/Exports", isDirectory: true)
    let errorLog = exportBase.appendingPathComponent("export_errors.log")
    let settings = parseSettings(CommandLine.arguments)

    do {
      // Debug logging is opt-in.
      let debugLogger: LineLogger?
      if let logFile = settings.logFile {
        // If a log file was requested, enable debug logging to that file (even without --debug).
        try await ensureDir(logFile.deletingLastPathComponent(), logger: nil)
        debugLogger = try? LineLogger(fileURL: logFile)
      } else if settings.debug {
        debugLogger = LineLogger(handle: .standardError)
      } else {
        debugLogger = nil
      }

      // Ensure base folder exists before exporting.
      // (Only logged when debug is enabled.)
      try await ensureDir(exportBase, logger: debugLogger)

      if settings.debug {
        fputs("Export base: \(exportBase.path)\n", stderr)
        fputs("Errors log:  \(errorLog.path)\n", stderr)
        if let logFile = settings.logFile {
          fputs("Debug log:   \(logFile.path)\n", stderr)
        }
      }

      await logDebug(debugLogger, "run.start cwd=\(fm.currentDirectoryPath) exportBase=\(exportBase.path)")

      try await requestPhotosAccess(logger: debugLogger)

      let (start, end) = currentYearRange()
      await logDebug(debugLogger, "fetch.range start=\(isoTimestamp(start)) end=\(isoTimestamp(end))")

      let opts = PHFetchOptions()
      opts.predicate = NSPredicate(format: "creationDate >= %@ AND creationDate <= %@", start as NSDate, end as NSDate)
      // Includes photos and videos by default with PHAsset.fetchAssets(with: opts)
      let assets = PHAsset.fetchAssets(with: opts)

      let total = assets.count
      var exported = 0
      var bar = ProgressBar(total: max(1, total))

      await logDebug(debugLogger, "fetch.done total=\(total)")

      if total == 0 {
        print("No assets found for current year.")
        return
      }

      // Iterate sequentially (safe in async context; avoids deadlocks).
      await logDebug(debugLogger, "iterate.begin total=\(total)")
      for idx in 0..<total {
        let asset = assets.object(at: idx)
        let label = "\(idx + 1)/\(total) \(asset.mediaType == .video ? "video" : "photo")"
        do {
          await logDebug(debugLogger, "asset.start index=\(idx + 1) total=\(total) id=\(asset.localIdentifier) mediaType=\(asset.mediaType.rawValue)")
          guard let date = asset.creationDate else {
            logWarn("asset=\(asset.localIdentifier) missing creationDate")
            throw NSError(domain: "PhotosExport", code: 3, userInfo: [NSLocalizedDescriptionKey: "Missing creationDate"])
          }

          let y = yearString(date)
          let m = monthString(date)

          let folder = exportBase.appendingPathComponent(y, isDirectory: true).appendingPathComponent(m, isDirectory: true)
          try await ensureDir(folder, logger: debugLogger)
          await logDebug(debugLogger, "asset.folder asset=\(asset.localIdentifier) folder=\(folder.path)")

          _ = try await exportAllResources(
            asset: asset,
            captureDate: date,
            to: folder,
            incremental: settings.incremental,
            errorLogURL: errorLog,
            logger: debugLogger
          )
          exported += 1
          bar.tick(label + " ✓")
        } catch {
          let ns = error as NSError
          var line = "\(Date()) asset=\(asset.localIdentifier) index=\(idx + 1)/\(total) \(errorDetails(error))"
          if ns.domain == "PhotosExport", ns.code == 20 {
            if let capture = ns.userInfo[PhotosExportErrorInfoKey.captureTimestamp] as? String {
              line += " capture=\(capture)"
            }
            if let px = ns.userInfo[PhotosExportErrorInfoKey.pixelSize] as? String {
              line += " px=\(px)"
            }
            if let failed = ns.userInfo[PhotosExportErrorInfoKey.failedResources] as? [String], !failed.isEmpty {
              // Keep stderr concise, but write a detailed block to the log.
              line += " failedCount=\(failed.count)"
              appendBlock(
                "\(Date()) asset.failed.details asset=\(asset.localIdentifier) index=\(idx + 1)/\(total)",
                lines: failed,
                to: errorLog
              )
            }
          }

          appendLine(line, to: errorLog)
          logError("asset.error \(line)")
          await logDebug(debugLogger, "asset.error \(line)")
          bar.tick(label + " ✗")
        }
      }

      await logDebug(debugLogger, "run.done exported=\(exported) total=\(total)")
      print("Export complete: \(exported) of \(total) assets exported to \(exportBase.path)")
      if fm.fileExists(atPath: errorLog.path) {
        print("Errors logged to: \(errorLog.path)")
      }
    } catch {
      fputs("Fatal: \(error)\n", stderr)
      if (error as NSError).domain == "PhotosExport", (error as NSError).code == 1 {
        fputs("Hint: macOS Photos permission is denied. Enable Photos access for the launching app (often Terminal) in System Settings → Privacy & Security → Photos, then re-run.\n", stderr)
      }
      exit(1)
    }
  }
}

