import XCTest
@testable import PhotosExport

final class PhotosExportTests: XCTestCase {
  func testParseSettingsIncrementalFlag() {
    let s = parseSettings(["PhotosExport", "--incremental"])
    XCTAssertTrue(s.incremental)
    XCTAssertFalse(s.debug)
  }

  func testParseSettingsMetadataFlag() {
    let s = parseSettings(["PhotosExport", "--metadata"])
    XCTAssertTrue(s.metadata)
    XCTAssertFalse(s.incremental)
  }

  func testCaptureTimestampStringFormat() {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(secondsFromGMT: 0)!
    let date = cal.date(from: DateComponents(year: 2025, month: 12, day: 27, hour: 13, minute: 56, second: 27))!

    // This function uses TimeZone.current, so we can only assert the shape here.
    let s = captureTimestampString(date)
    XCTAssertEqual(s.count, 14)
    XCTAssertTrue(s.allSatisfy({ $0 >= "0" && $0 <= "9" }))
  }

  func testFNV1a64IsDeterministic() {
    XCTAssertEqual(fnv1a64("IMG_0001.JPG"), fnv1a64("IMG_0001.JPG"))
    XCTAssertNotEqual(fnv1a64("IMG_0001.JPG"), fnv1a64("IMG_0002.JPG"))
  }

  func testAlphaLetterMapsToLowercase() {
    let c0 = alphaLetter(from: 0)
    XCTAssertTrue(("a"..."z").contains(String(c0)))

    let c1 = alphaLetter(from: 123456789)
    XCTAssertTrue(("a"..."z").contains(String(c1)))
  }

  func testExportFilenameUsesHashedLetterAndIsStable() {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(secondsFromGMT: 0)!
    let date = cal.date(from: DateComponents(year: 2025, month: 1, day: 2, hour: 3, minute: 4, second: 5))!

    var usedA = Set<String>()
    let a = exportFilename(
      captureDate: date,
      originalFilename: "IMG_0001.JPG",
      fallbackSeed: "assetid",
      uti: "public.jpeg",
      usedNames: &usedA
    )

    var usedB = Set<String>()
    let b = exportFilename(
      captureDate: date,
      originalFilename: "IMG_0001.JPG",
      fallbackSeed: "assetid",
      uti: "public.jpeg",
      usedNames: &usedB
    )

    XCTAssertEqual(a, b)
    XCTAssertTrue(a.hasSuffix(".jpg"))
    XCTAssertEqual(a.count, 14 + 4) // YYYYMMDDHHMMSS + .ext
  }

  func testExportFilenameCollisionAdvancesLetter() {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(secondsFromGMT: 0)!
    let date = cal.date(from: DateComponents(year: 2025, month: 1, day: 2, hour: 3, minute: 4, second: 5))!

    var used = Set<String>()
    let base = exportFilename(
      captureDate: date,
      originalFilename: "IMG_0001.JPG",
      fallbackSeed: "assetid",
      uti: "public.jpeg",
      usedNames: &used
    )

    // Force a collision for the same timestamp.
    let b = exportFilename(
      captureDate: date,
      originalFilename: "IMG_0002.JPG",
      fallbackSeed: "assetid",
      uti: "public.jpeg",
      usedNames: &used
    )

    let c = exportFilename(
      captureDate: date,
      originalFilename: "IMG_0002.JPG",
      fallbackSeed: "assetid",
      uti: "public.jpeg",
      usedNames: &used
    )

    XCTAssertNotEqual(base, b)
    XCTAssertNotEqual(b, c)

    // Base has no letter; collisions do.
    XCTAssertEqual(base.count, 14 + 4)
    XCTAssertEqual(b.count, 14 + 1 + 4)
    XCTAssertEqual(c.count, 14 + 1 + 4)

    // Letter is deterministic from original filename (then advanced for further collisions).
    // Seed now includes name + metadata.
    let metaSeed = [
      "asset=assetid",
      "mediaType=0",
      "subtypes=0",
      "px=0x0",
      "dur=0.0",
      "resType=0",
      "uti=public.jpeg",
    ].joined(separator: "|")
    let h = fnv1a64("IMG_0002.JPG|\(metaSeed)")
    let expectedLetter = alphaLetter(from: h, offset: 0)
    XCTAssertEqual(b.dropLast(4).dropFirst(14).first, expectedLetter)
  }

  func testExportFilenameWrapsAfterZToA() {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(secondsFromGMT: 0)!
    let date = cal.date(from: DateComponents(year: 2025, month: 1, day: 2, hour: 3, minute: 4, second: 5))!

    let ts = captureTimestampString(date)
    let metaSeed = "meta"

    // Find an originalFilename whose collision-seed hashes to a 'z' (mod 26 == 25).
    var nameForZ: String? = nil
    for i in 0..<50_000 {
      let candidate = "name_\(i).JPG"
      let seed = "\(candidate)|\(metaSeed)"
      if fnv1a64(seed) % 26 == 25 {
        nameForZ = candidate
        break
      }
    }
    guard let nameForZ else {
      XCTFail("Failed to find seed mapping to z")
      return
    }

    var used = Set<String>()
    // Force base collision first.
    _ = exportFilename(
      captureDate: date,
      originalFilename: nameForZ,
      fallbackSeed: metaSeed,
      uti: "public.jpeg",
      usedNames: &used
    )

    // Force 'z' collision next, so it must wrap to 'a'.
    used.insert("\(ts)z.jpg")

    let wrapped = exportFilename(
      captureDate: date,
      originalFilename: nameForZ,
      fallbackSeed: metaSeed,
      uti: "public.jpeg",
      usedNames: &used
    )

    XCTAssertEqual(wrapped, "\(ts)a.jpg")
  }
}
