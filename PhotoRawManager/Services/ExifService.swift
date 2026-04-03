import Foundation
import ImageIO

struct ExifService {
    // MARK: - EXIF Cache (Carpaccio-style optimization)

    private static let cacheLock = NSLock()
    private static var exifCache: [URL: ExifData] = [:]

    /// Shared DateFormatter (expensive to create, reuse)
    private static let exifDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f
    }()

    /// Optimized single-file EXIF extraction.
    /// Uses kCGImageSourceShouldCache: false to avoid loading image data.
    /// Results are cached in memory.
    static func extractExif(from url: URL) -> ExifData? {
        // Check cache first
        cacheLock.lock()
        if let cached = exifCache[url] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        // I/O work outside the lock
        let sourceOptions: [NSString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            return nil
        }

        let data = parseProperties(properties)

        // Store in cache
        cacheLock.lock()
        exifCache[url] = data
        cacheLock.unlock()

        return data
    }

    /// Batch EXIF extraction with concurrent dispatch (Carpaccio-style).
    /// Processes multiple files in parallel for maximum throughput.
    static func extractExifBatch(
        from urls: [URL],
        progress: ((Int) -> Void)? = nil
    ) -> [URL: ExifData] {
        var results: [URL: ExifData] = [:]
        let resultsLock = NSLock()
        let totalCount = urls.count

        // Filter out already-cached URLs
        cacheLock.lock()
        let uncachedURLs = urls.filter { exifCache[$0] == nil }
        for url in urls {
            if let cached = exifCache[url] {
                results[url] = cached
            }
        }
        cacheLock.unlock()

        if uncachedURLs.isEmpty {
            progress?(totalCount)
            return results
        }

        // Concurrent dispatch with limited parallelism
        let concurrency = min(ProcessInfo.processInfo.activeProcessorCount, 8)
        let queue = DispatchQueue(label: "exif.batch", attributes: .concurrent)
        let group = DispatchGroup()
        let semaphore = DispatchSemaphore(value: concurrency)
        var completed = results.count

        for url in uncachedURLs {
            group.enter()
            semaphore.wait()
            queue.async {
                defer {
                    semaphore.signal()
                    group.leave()
                }

                let sourceOptions: [NSString: Any] = [
                    kCGImageSourceShouldCache: false
                ]
                guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
                    resultsLock.lock()
                    completed += 1
                    let c = completed
                    resultsLock.unlock()
                    progress?(c)
                    return
                }

                let data = parseProperties(properties)

                // Cache and store result
                cacheLock.lock()
                exifCache[url] = data
                cacheLock.unlock()

                resultsLock.lock()
                results[url] = data
                completed += 1
                let c = completed
                resultsLock.unlock()

                progress?(c)
            }
        }

        group.wait()
        return results
    }

    /// Clear the EXIF cache (e.g. when folder changes)
    static func clearCache() {
        cacheLock.lock()
        exifCache.removeAll()
        cacheLock.unlock()
    }

    // MARK: - Property Parsing (shared between single and batch)

    private static func parseProperties(_ properties: [String: Any]) -> ExifData {
        let exifDict = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let tiffDict = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let exifAuxDict = properties[kCGImagePropertyExifAuxDictionary as String] as? [String: Any] ?? [:]

        var data = ExifData()

        // Camera info
        data.cameraMake = tiffDict[kCGImagePropertyTIFFMake as String] as? String
        data.cameraModel = tiffDict[kCGImagePropertyTIFFModel as String] as? String

        // Lens
        data.lensModel = exifDict[kCGImagePropertyExifLensModel as String] as? String
            ?? exifAuxDict[kCGImagePropertyExifAuxLensModel as String] as? String

        // ISO
        if let isoArray = exifDict[kCGImagePropertyExifISOSpeedRatings as String] as? [Int],
           let iso = isoArray.first {
            data.iso = iso
        }

        // Shutter speed
        if let exposureTime = exifDict[kCGImagePropertyExifExposureTime as String] as? Double {
            data.exposureTime = exposureTime
            if exposureTime >= 1.0 {
                data.shutterSpeed = String(format: "%.1fs", exposureTime)
            } else {
                let denominator = Int(round(1.0 / exposureTime))
                data.shutterSpeed = "1/\(denominator)s"
            }
        }

        // Exposure bias
        data.exposureBias = exifDict[kCGImagePropertyExifExposureBiasValue as String] as? Double

        // Aperture
        data.aperture = exifDict[kCGImagePropertyExifFNumber as String] as? Double

        // Focal length
        data.focalLength = exifDict[kCGImagePropertyExifFocalLength as String] as? Double

        // Date taken
        if let dateString = exifDict[kCGImagePropertyExifDateTimeOriginal as String] as? String {
            data.dateTaken = exifDateFormatter.date(from: dateString)
        }

        // Image dimensions
        data.imageWidth = properties[kCGImagePropertyPixelWidth as String] as? Int
        data.imageHeight = properties[kCGImagePropertyPixelHeight as String] as? Int

        // Bit depth
        if let d = properties[kCGImagePropertyDepth as String] as? Int {
            data.bitDepth = d
        } else if let d = properties[kCGImagePropertyDepth as String] as? Double {
            data.bitDepth = Int(d)
        }

        // DPI
        if let d = properties[kCGImagePropertyDPIWidth as String] as? Double {
            data.dpiX = Int(d)
        } else if let d = properties[kCGImagePropertyDPIWidth as String] as? Int {
            data.dpiX = d
        }
        if let d = properties[kCGImagePropertyDPIHeight as String] as? Double {
            data.dpiY = Int(d)
        } else if let d = properties[kCGImagePropertyDPIHeight as String] as? Int {
            data.dpiY = d
        }

        // GPS
        let gpsDict = properties[kCGImagePropertyGPSDictionary as String] as? [String: Any] ?? [:]
        if let lat = gpsDict[kCGImagePropertyGPSLatitude as String] as? Double,
           let latRef = gpsDict[kCGImagePropertyGPSLatitudeRef as String] as? String,
           let lon = gpsDict[kCGImagePropertyGPSLongitude as String] as? Double,
           let lonRef = gpsDict[kCGImagePropertyGPSLongitudeRef as String] as? String {
            data.latitude = latRef == "S" ? -lat : lat
            data.longitude = lonRef == "W" ? -lon : lon
        }

        // AF Point (SubjectArea from EXIF)
        let imgW = CGFloat(data.imageWidth ?? 1)
        let imgH = CGFloat(data.imageHeight ?? 1)

        if let subjectArea = exifDict[kCGImagePropertyExifSubjectArea as String] as? [Int] {
            // SubjectArea can be: [x, y] point, [x, y, diameter] circle, [x, y, w, h] rectangle
            if subjectArea.count >= 2 {
                var af = AFPoint(
                    x: CGFloat(subjectArea[0]) / imgW,
                    y: CGFloat(subjectArea[1]) / imgH
                )
                if subjectArea.count == 3 {
                    // Circle: diameter
                    let d = CGFloat(subjectArea[2])
                    af.width = d / imgW
                    af.height = d / imgH
                } else if subjectArea.count >= 4 {
                    // Rectangle: w, h
                    af.width = CGFloat(subjectArea[2]) / imgW
                    af.height = CGFloat(subjectArea[3]) / imgH
                } else {
                    // Point only: use default small box
                    af.width = 0.05
                    af.height = 0.05
                }
                data.afPoint = af
            }
        }

        // Picture Style / Creative Look / Film Simulation
        data.pictureStyle = extractPictureStyle(properties: properties, make: data.cameraMake)

        // Also check MakerNote AF info via SubjectDistRange or other tags
        if data.afPoint == nil {
            // Try SubjectLocation (older tag)
            if let subjectLoc = exifDict["SubjectLocation"] as? [Int], subjectLoc.count >= 2 {
                data.afPoint = AFPoint(
                    x: CGFloat(subjectLoc[0]) / imgW,
                    y: CGFloat(subjectLoc[1]) / imgH,
                    width: 0.05,
                    height: 0.05
                )
            }
        }

        return data
    }

    // MARK: - Picture Style Extraction

    private static func extractPictureStyle(properties: [String: Any], make: String?) -> String? {
        let make = (make ?? "").lowercased()

        // Sony: {PictureStyle}.ColorMode or {PictureStyle}.SceneMode
        if let ps = properties["{PictureStyle}"] as? [String: Any] {
            if let colorMode = ps["ColorMode"] as? [Any], let name = colorMode.first as? String, !name.isEmpty {
                return mapSonyCreativeLook(name)
            }
            if let sceneMode = ps["SceneMode"] as? [Any], let name = sceneMode.first as? String, !name.isEmpty {
                return name
            }
        }

        // Canon: {MakerCanon} - PictureStyle info
        if make.contains("canon"), let maker = properties["{MakerCanon}"] as? [String: Any] {
            if let style = maker["PictureStyle"] as? String { return style }
            if let style = maker["PictureStyleName"] as? String { return style }
            // Canon stores style as numeric ID sometimes
            if let styleID = maker["PictureStyleID"] as? Int {
                return mapCanonPictureStyle(styleID)
            }
        }

        // Nikon: {MakerNikon} - Picture Control
        if make.contains("nikon"), let maker = properties["{MakerNikon}"] as? [String: Any] {
            if let control = maker["PictureControlName"] as? String { return control }
            if let control = maker["PictureControl"] as? String { return control }
            if let activeDP = maker["ActiveD-Lighting"] as? String { return "ADL: \(activeDP)" }
        }

        // Fujifilm: FilmMode in MakerFuji
        if make.contains("fuji"), let maker = properties["{MakerFujifilm}"] as? [String: Any] {
            if let sim = maker["FilmMode"] as? String { return mapFujiFilmSimulation(sim) }
            if let simID = maker["FilmMode"] as? Int { return mapFujiFilmSimulationID(simID) }
        }

        return nil
    }

    private static func mapSonyCreativeLook(_ name: String) -> String {
        let map: [String: String] = [
            "Standard": "Standard (ST)", "Vivid": "Vivid (VV)", "Neutral": "Neutral (NT)",
            "Portrait": "Portrait (PT)", "Landscape": "Landscape", "Sunset": "Sunset",
            "Night Scene": "Night Scene", "B&W": "B&W (BW)", "Sepia": "Sepia (SE)",
            "FL": "FL", "IN": "IN", "SH": "SH", "VV2": "VV2",
        ]
        return map[name] ?? name
    }

    private static func mapCanonPictureStyle(_ id: Int) -> String {
        let map: [Int: String] = [
            0x81: "Standard", 0x82: "Portrait", 0x83: "Landscape",
            0x84: "Neutral", 0x85: "Faithful", 0x86: "Monochrome",
            0x87: "Auto", 0x88: "Fine Detail",
        ]
        return map[id] ?? "Style \(id)"
    }

    private static func mapFujiFilmSimulation(_ name: String) -> String {
        let map: [String: String] = [
            "PROVIA": "PROVIA/Standard", "Velvia": "Velvia/Vivid", "ASTIA": "ASTIA/Soft",
            "PRO Neg.Std": "PRO Neg.Std", "PRO Neg.Hi": "PRO Neg.Hi",
            "Classic Chrome": "Classic Chrome", "ETERNA": "ETERNA/Cinema",
            "ETERNA BLEACH BYPASS": "ETERNA Bleach Bypass",
            "Classic Neg.": "Classic Neg.", "NOSTALGIC Neg.": "Nostalgic Neg.",
            "REALA ACE": "REALA ACE", "ACROS": "ACROS",
        ]
        return map[name] ?? name
    }

    private static func mapFujiFilmSimulationID(_ id: Int) -> String {
        let map: [Int: String] = [
            0x0: "PROVIA", 0x100: "Standard", 0x200: "Velvia", 0x300: "ASTIA",
            0x400: "PRO Neg.Hi", 0x500: "PRO Neg.Std",
            0x600: "Classic Chrome", 0x700: "ETERNA",
        ]
        return map[id] ?? "Film \(id)"
    }
}
