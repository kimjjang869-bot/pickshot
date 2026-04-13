import Foundation
import UniformTypeIdentifiers
import AVFoundation
import AppKit

struct FileMatchingService {
    static let jpgExtensions: Set<String> = ["jpg", "jpeg"]
    static let imageExtensions: Set<String> = [
        "png",                      // PNG
        "heic", "heif",             // Apple HEIC/HEIF
        "psd",                      // Adobe Photoshop
        "tif", "tiff",              // TIFF
        "bmp",                      // BMP
        "gif",                      // GIF
        "webp",                     // WebP (macOS 14+)
        "avif",                     // AVIF (AV1 기반 차세대 포맷)
        "jxl",                      // JPEG XL (차세대 JPEG)
        "jp2", "j2k", "jpx",       // JPEG 2000
        "tga",                      // Truevision TGA
        "exr",                      // OpenEXR (HDR)
        "ico",                      // Windows Icon
        "icns",                     // macOS Icon
        "sgi",                      // Silicon Graphics
        "pbm", "pgm", "ppm",       // Netpbm
        "dds",                      // DirectDraw Surface
        "ktx", "ktx2",             // Khronos Texture
        "astc",                     // Adaptive Scalable Texture Compression
        "hdr",                      // Radiance HDR
    ]

    /// 모든 지원 이미지 확장자 (JPG + RAW + Image + Video)
    static let allImageExtensions: Set<String> = jpgExtensions
        .union(rawExtensions)
        .union(imageExtensions)

    static let allMediaExtensions: Set<String> = allImageExtensions
        .union(videoExtensions)
    static let videoExtensions: Set<String> = [
        "mov", "mp4", "avi", "m4v"  // Video files
    ]
    static let rawExtensions: Set<String> = [
        "cr2", "cr3", "crw",       // Canon
        "arw", "sr2", "srf",       // Sony
        "nef", "nrw",              // Nikon (NEF + Coolpix NRW)
        "raf",                      // Fujifilm
        "dng",                      // Adobe DNG
        "orf", "ori",               // Olympus/OM System
        "rw2", "rwl",               // Panasonic / Leica
        "pef",                      // Pentax
        "srw",                      // Samsung
        "3fr", "fff",               // Hasselblad
        "iiq",                      // Phase One
        "mos",                      // Leaf
        "erf",                      // Epson
        "kdc", "dcr",               // Kodak
        "rwz",                      // Rawzor
        "x3f",                      // Sigma
        "gpr",                      // GoPro
    ]

    /// Classifies a file URL using UTType for accurate type detection.
    /// Falls back to extension-based matching if UTType cannot determine the type.
    private static func classifyFile(_ fileURL: URL) -> FileCategory {
        let ext = fileURL.pathExtension.lowercased()

        // Check video first (UTType won't help distinguish our intent)
        if videoExtensions.contains(ext) { return .video }

        // Try UTType-based detection first
        if let utType = try? fileURL.resourceValues(forKeys: [.contentTypeKey]).contentType {
            if utType.conforms(to: .jpeg) {
                return .jpg
            }
            if utType.conforms(to: .rawImage) {
                return .raw
            }
            // Check DNG specifically (conforms to both rawImage and public.camera-raw-image)
            if utType.conforms(to: UTType("com.adobe.raw-image") ?? .rawImage) {
                return .raw
            }
            // HEIC, PSD, TIFF conform to UTType.image
            if utType.conforms(to: .image) && imageExtensions.contains(ext) {
                return .image
            }
        }

        // Fallback to extension-based matching for edge cases
        if jpgExtensions.contains(ext) { return .jpg }
        if rawExtensions.contains(ext) { return .raw }
        if imageExtensions.contains(ext) { return .image }

        return .other
    }

    private enum FileCategory {
        case jpg, raw, image, video, other
    }

    /// Generate a thumbnail from the first frame of a video file
    static func generateVideoThumbnail(url: URL) -> NSImage? {
        let asset = AVAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 400, height: 400)
        do {
            let cgImage = try generator.copyCGImage(at: .zero, actualTime: nil)
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        } catch {
            return nil
        }
    }

    /// Extract video duration in seconds (lightweight, no full decode)
    static func videoDuration(url: URL) -> Double? {
        let asset = AVURLAsset(url: url, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: false
        ])
        let dur = asset.duration
        guard dur.isNumeric, dur != .zero else { return nil }
        let seconds = CMTimeGetSeconds(dur)
        return seconds > 0 ? seconds : nil
    }

    /// Scans a folder and its subdirectories for JPG/RAW/image/video files and matches them by filename.
    /// Uses UTType for accurate file type detection with extension-based fallback.
    /// Supports structures like:
    ///   - All files in one folder
    ///   - Separate jpg/ and raw/ subfolders
    ///   - Any nested structure
    static func scanAndMatch(folderURL: URL, recursive: Bool = false) -> [PhotoItem] {
        let fileManager = FileManager.default

        // Only scan current folder (not subfolders) for speed
        var enumOptions: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles]
        if !recursive {
            enumOptions.insert(.skipsSubdirectoryDescendants)
        }
        // 파일 크기/날짜를 enumerator에서 한번에 가져와 stat() 중복 제거
        let prefetchKeys: Set<URLResourceKey> = [.isRegularFileKey, .contentTypeKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = fileManager.enumerator(
            at: folderURL,
            includingPropertiesForKeys: Array(prefetchKeys),
            options: enumOptions
        ) else {
            return []
        }

        struct FileInfo {
            let url: URL
            let size: Int64
            let modDate: Date
        }

        var jpgFiles: [String: FileInfo] = [:]
        var rawFiles: [String: FileInfo] = [:]
        var imageFiles: [String: FileInfo] = [:]
        var videoFiles: [String: FileInfo] = [:]
        var otherFiles: [String: URL] = [:]

        while let fileURL = enumerator.nextObject() as? URL {
            guard let rv = try? fileURL.resourceValues(forKeys: prefetchKeys),
                  rv.isRegularFile == true else { continue }

            let baseName = fileURL.deletingPathExtension().lastPathComponent.lowercased()
            let info = FileInfo(
                url: fileURL,
                size: Int64(rv.fileSize ?? 0),
                modDate: rv.contentModificationDate ?? .distantPast
            )

            switch classifyFile(fileURL) {
            case .jpg:   jpgFiles[baseName] = info
            case .raw:   rawFiles[baseName] = info
            case .image: imageFiles[baseName] = info
            case .video: videoFiles[baseName] = info
            case .other: otherFiles[baseName] = fileURL
            }
        }

        // Add subfolders as folder items in the grid (no recursive scanning)
        let subFolders = (try? fileManager.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]))?.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        } ?? []

        // JPG가 있는 파일: JPG를 미리보기로, RAW를 매칭 (stat() 불필요 — enumerator에서 이미 로드)
        var result: [PhotoItem] = jpgFiles
            .sorted { $0.key < $1.key }
            .map { baseName, jpgInfo in
                var item = PhotoItem(
                    jpgURL: jpgInfo.url,
                    rawURL: rawFiles[baseName]?.url
                )
                item.fileModDate = jpgInfo.modDate
                item.jpgFileSize = jpgInfo.size
                if let rawInfo = rawFiles[baseName] {
                    item.rawFileSize = rawInfo.size
                }
                return item
            }

        // RAW만 있는 파일
        let rawOnly = rawFiles.filter { jpgFiles[$0.key] == nil }
        let rawOnlyItems = rawOnly
            .sorted { $0.key < $1.key }
            .map { baseName, rawInfo in
                var item = PhotoItem(
                    jpgURL: rawInfo.url,
                    rawURL: rawInfo.url
                )
                item.fileModDate = rawInfo.modDate
                item.rawFileSize = rawInfo.size
                return item
            }
        result.append(contentsOf: rawOnlyItems)

        // HEIC/PSD/TIFF
        let imageOnly = imageFiles.filter { jpgFiles[$0.key] == nil && rawFiles[$0.key] == nil }
        let imageOnlyItems = imageOnly
            .sorted { $0.key < $1.key }
            .map { baseName, imgInfo in
                var item = PhotoItem(
                    jpgURL: imgInfo.url,
                    rawURL: nil
                )
                item.fileModDate = imgInfo.modDate
                item.jpgFileSize = imgInfo.size
                return item
            }
        result.append(contentsOf: imageOnlyItems)

        // Video files (duration extracted lightweight)
        let videoItems = videoFiles
            .sorted { $0.key < $1.key }
            .map { baseName, vidInfo in
                var item = PhotoItem(
                    jpgURL: vidInfo.url,
                    rawURL: nil
                )
                item.fileModDate = vidInfo.modDate
                item.jpgFileSize = vidInfo.size
                item.videoDuration = videoDuration(url: vidInfo.url)
                return item
            }
        result.append(contentsOf: videoItems)

        // Add subfolder items at the beginning (folder icons in thumbnail grid)
        let folderItems = subFolders
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { folderURL in
                PhotoItem(
                    jpgURL: folderURL,
                    rawURL: nil,
                    isFolder: true
                )
            }
        result.insert(contentsOf: folderItems, at: 0)

        return result
    }
}

// MARK: - 문자열 거리 계산 (매칭 서비스 공통)
enum StringDistance {
    static func levenshtein(_ s1: String, _ s2: String) -> Int {
        let a = Array(s1), b = Array(s2)
        let m = a.count, n = b.count
        if m == 0 { return n }
        if n == 0 { return m }
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in 0...m { dp[i][0] = i }
        for j in 0...n { dp[0][j] = j }
        for i in 1...m {
            for j in 1...n {
                let cost = a[i-1] == b[j-1] ? 0 : 1
                dp[i][j] = min(dp[i-1][j] + 1, dp[i][j-1] + 1, dp[i-1][j-1] + cost)
            }
        }
        return dp[m][n]
    }
}
