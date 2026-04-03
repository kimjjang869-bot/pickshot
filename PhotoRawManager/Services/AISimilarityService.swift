import AppKit
import CoreImage

/// AI-powered image similarity matching using perceptual hashing (pHash).
/// Used when client sends photos via KakaoTalk with completely different filenames.
/// No API cost — runs entirely on-device.
struct AISimilarityService {

    struct SimilarityMatch {
        let clientPhotoURL: URL
        let matchedPhotoIndex: Int
        let similarity: Double  // 0.0 - 1.0
        let matchMethod: String  // "pHash", "EXIF시간", "pHash+EXIF"
    }

    struct MatchResult {
        let matched: [SimilarityMatch]
        let unmatched: [URL]
        let totalInput: Int
    }

    /// Scan folder for image files (JPG, PNG, HEIC, etc.)
    static func scanImages(in folderURL: URL) -> [URL] {
        let fm = FileManager.default
        let imageExts = FileMatchingService.jpgExtensions
            .union(FileMatchingService.imageExtensions)
            .union(Set(["png"]))
        guard let enumerator = fm.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return [] }

        var images: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            if imageExts.contains(url.pathExtension.lowercased()) {
                images.append(url)
            }
        }
        return images
    }

    /// Match client photos against original photos using multi-stage approach
    static func match(
        clientPhotos: [URL],
        photos: [PhotoItem],
        similarityThreshold: Double = 0.85,
        progress: ((Int, Int) -> Void)? = nil
    ) -> MatchResult {
        // Pre-compute hashes for original photos
        let originalHashes: [(index: Int, hash: UInt64, exifDate: Date?)] = photos.enumerated().compactMap { (i, photo) in
            guard !photo.isFolder && !photo.isParentFolder else { return nil }
            let hash = computePHash(url: photo.jpgURL)
            let exifDate = extractEXIFDate(url: photo.jpgURL)
            return (i, hash, exifDate)
        }

        var matched: [SimilarityMatch] = []
        var unmatched: [URL] = []
        var matchedIndices = Set<Int>()

        for (ci, clientURL) in clientPhotos.enumerated() {
            progress?(ci + 1, clientPhotos.count)

            let clientHash = computePHash(url: clientURL)
            let clientExifDate = extractEXIFDate(url: clientURL)

            var bestMatch: (index: Int, similarity: Double, method: String)?

            for orig in originalHashes {
                guard !matchedIndices.contains(orig.index) else { continue }

                // Stage 1: EXIF date filter (if available)
                var dateBonus: Double = 0
                if let cd = clientExifDate, let od = orig.exifDate {
                    let timeDiff = abs(cd.timeIntervalSince(od))
                    if timeDiff < 2 {  // Within 2 seconds = likely same shot
                        dateBonus = 0.15
                    } else if timeDiff < 60 {  // Within 1 minute
                        dateBonus = 0.05
                    }
                }

                // Stage 2: pHash similarity
                let hashSimilarity = hammingSimilarity(clientHash, orig.hash)
                let totalSimilarity = min(1.0, hashSimilarity + dateBonus)

                let method: String
                if dateBonus > 0.1 && hashSimilarity > 0.7 {
                    method = "pHash+EXIF"
                } else if dateBonus > 0.1 {
                    method = "EXIF시간"
                } else {
                    method = "pHash"
                }

                if totalSimilarity > (bestMatch?.similarity ?? 0) {
                    bestMatch = (orig.index, totalSimilarity, method)
                }
            }

            if let best = bestMatch, best.similarity >= similarityThreshold {
                matched.append(SimilarityMatch(
                    clientPhotoURL: clientURL,
                    matchedPhotoIndex: best.index,
                    similarity: best.similarity,
                    matchMethod: best.method
                ))
                matchedIndices.insert(best.index)
            } else {
                unmatched.append(clientURL)
            }
        }

        return MatchResult(matched: matched, unmatched: unmatched, totalInput: clientPhotos.count)
    }

    // MARK: - Perceptual Hash (pHash)

    /// Compute 64-bit perceptual hash of an image.
    /// Resizes to 8x8 grayscale, applies DCT-like comparison to mean.
    static func computePHash(url: URL) -> UInt64 {
        // Load and resize to 8x8 grayscale
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceThumbnailMaxPixelSize: 32,
                kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else {
            return 0
        }

        // Convert to 8x8 grayscale
        let size = 8
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
            data: nil, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: size,
            space: colorSpace, bitmapInfo: 0
        ) else { return 0 }

        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))

        guard let data = context.data else { return 0 }
        let pixels = data.bindMemory(to: UInt8.self, capacity: size * size)

        // Compute mean
        var sum: Int = 0
        for i in 0..<(size * size) {
            sum += Int(pixels[i])
        }
        let mean = sum / (size * size)

        // Build hash: 1 if pixel > mean, 0 otherwise
        var hash: UInt64 = 0
        for i in 0..<(size * size) {
            if Int(pixels[i]) > mean {
                hash |= (1 << i)
            }
        }

        return hash
    }

    /// Hamming similarity between two hashes (0.0 = completely different, 1.0 = identical)
    static func hammingSimilarity(_ h1: UInt64, _ h2: UInt64) -> Double {
        let xor = h1 ^ h2
        let differentBits = xor.nonzeroBitCount
        return 1.0 - (Double(differentBits) / 64.0)
    }

    // MARK: - EXIF Date Extraction

    /// Extract EXIF DateTimeOriginal from an image
    static func extractEXIFDate(url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let exifDict = props[kCGImagePropertyExifDictionary as String] as? [String: Any],
              let dateStr = exifDict[kCGImagePropertyExifDateTimeOriginal as String] as? String else {
            return nil
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: dateStr)
    }
}
