import Foundation

enum SettingsError: Error, LocalizedError {
  case missingValue(String)
  case invalidYear(String)
  case invalidYearRange(startYear: Int, endYear: Int)
  case missingStartYearForEndYear
  case exportDirectoryNotADirectory(String)
  case exportDirectoryDoesNotExist(String)

  var errorDescription: String? {
    switch self {
    case .missingValue(let flag):
      return "Missing value for \(flag)"
    case .invalidYear(let raw):
      return "Invalid year '\(raw)'. Expected a valid integer."
    case .invalidYearRange(let startYear, let endYear):
      return "Invalid year range: start year (\(startYear)) is after end year (\(endYear))."
    case .missingStartYearForEndYear:
      return "--end-year requires --year to also be specified."
    case .exportDirectoryNotADirectory(let path):
      return "--export-directory must be a directory: \(path)"
    case .exportDirectoryDoesNotExist(let path):
      return "--export-directory does not exist: \(path)"
    }
  }
}

struct Settings {
  // Base directory under which exports are written (as YYYY/MM subfolders).
  // If nil, defaults to ~/Pictures/Exports
  var exportDirectory: URL? = nil
  var logFile: URL? = nil
  var debug: Bool = false
  var incremental: Bool = false
  var metadata: Bool = false
  var yearOverride: Int? = nil
  // If specified, exports from startYear through endYear (inclusive).
  var endYear: Int? = nil
}

func parseSettings(_ args: [String]) throws -> Settings {
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
    case "--metadata":
      settings.metadata = true
      i += 1
    case "--year":
      guard i + 1 < args.count else {
        throw SettingsError.missingValue("--year")
      }
      let raw = args[i + 1]
      guard let year = Int(raw) else {
        throw SettingsError.invalidYear(raw)
      }
      settings.yearOverride = year
      i += 2
    case "--end-year":
      guard i + 1 < args.count else {
        throw SettingsError.missingValue("--end-year")
      }
      let raw = args[i + 1]
      guard let year = Int(raw) else {
        throw SettingsError.invalidYear(raw)
      }
      settings.endYear = year
      i += 2
    case "--log-file":
      if i + 1 < args.count {
        settings.logFile = URL(fileURLWithPath: args[i + 1]).standardizedFileURL
        i += 2
      } else {
        throw SettingsError.missingValue("--log-file")
      }
    case "--export-directory":
      guard i + 1 < args.count else {
        throw SettingsError.missingValue("--export-directory")
      }
      let url = URL(fileURLWithPath: args[i + 1]).standardizedFileURL
      var isDir: ObjCBool = false
      if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
        if !isDir.boolValue {
          throw SettingsError.exportDirectoryNotADirectory(url.path)
        }
      } else {
        throw SettingsError.exportDirectoryDoesNotExist(url.path)
      }
      settings.exportDirectory = url
      i += 2
    default:
      i += 1
    }
  }

  // Validate year range if applicable.
  if let endYear = settings.endYear {
    guard let startYear = settings.yearOverride else {
      throw SettingsError.missingStartYearForEndYear
    }
    if startYear > endYear {
      throw SettingsError.invalidYearRange(startYear: startYear, endYear: endYear)
    }
  }
  return settings
}
