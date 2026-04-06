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
        "webp",                     // WebP
    ]
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
        guard let enumerator = fileManager.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey, .contentTypeKey],
            options: enumOptions
        ) else {
            return []
        }

        var jpgFiles: [String: URL] = [:]
        var rawFiles: [String: URL] = [:]
        var imageFiles: [String: URL] = [:]  // HEIC, PSD, TIFF
        var videoFiles: [String: URL] = [:]  // MOV, MP4, etc.
        var otherFiles: [String: URL] = [:]  // Non-image files

        while let fileURL = enumerator.nextObject() as? URL {
            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                  resourceValues.isRegularFile == true else {
                continue
            }

            let baseName = fileURL.deletingPathExtension().lastPathComponent.lowercased()

            switch classifyFile(fileURL) {
            case .jpg:
                jpgFiles[baseName] = fileURL
            case .raw:
                rawFiles[baseName] = fileURL
            case .image:
                imageFiles[baseName] = fileURL
            case .video:
                videoFiles[baseName] = fileURL
            case .other:
                // Track other files in case folder has no images
                otherFiles[baseName] = fileURL
            }
        }

        // Add subfolders as folder items in the grid (no recursive scanning)
        let subFolders = (try? fileManager.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]))?.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        } ?? []

        // JPG가 있는 파일: JPG를 미리보기로, RAW를 매칭
        var result: [PhotoItem] = jpgFiles
            .sorted { $0.key < $1.key }
            .map { baseName, jpgURL in
                var item = PhotoItem(
                    jpgURL: jpgURL,
                    rawURL: rawFiles[baseName]
                )
                let jpgAttrs = try? fileManager.attributesOfItem(atPath: jpgURL.path)
                item.fileModDate = (jpgAttrs?[.modificationDate] as? Date) ?? .distantPast
                item.jpgFileSize = (jpgAttrs?[.size] as? Int64) ?? 0
                if let rawURL = rawFiles[baseName] {
                    item.rawFileSize = (try? fileManager.attributesOfItem(atPath: rawURL.path)[.size] as? Int64) ?? 0
                }
                return item
            }

        // RAW만 있는 파일 (매칭되는 JPG가 없는 경우): RAW를 미리보기로도 사용
        let rawOnly = rawFiles.filter { jpgFiles[$0.key] == nil }
        let rawOnlyItems = rawOnly
            .sorted { $0.key < $1.key }
            .map { baseName, rawURL in
                var item = PhotoItem(
                    jpgURL: rawURL,
                    rawURL: rawURL
                )
                let rawAttrs = try? fileManager.attributesOfItem(atPath: rawURL.path)
                item.fileModDate = (rawAttrs?[.modificationDate] as? Date) ?? .distantPast
                item.rawFileSize = (rawAttrs?[.size] as? Int64) ?? 0
                return item
            }
        result.append(contentsOf: rawOnlyItems)

        // HEIC/PSD/TIFF: standalone image files (not matched to JPG/RAW)
        let imageOnly = imageFiles.filter { jpgFiles[$0.key] == nil && rawFiles[$0.key] == nil }
        let imageOnlyItems = imageOnly
            .sorted { $0.key < $1.key }
            .map { baseName, imageURL in
                var item = PhotoItem(
                    jpgURL: imageURL,
                    rawURL: nil
                )
                let imgAttrs = try? fileManager.attributesOfItem(atPath: imageURL.path)
                item.fileModDate = (imgAttrs?[.modificationDate] as? Date) ?? .distantPast
                item.jpgFileSize = (imgAttrs?[.size] as? Int64) ?? 0
                return item
            }
        result.append(contentsOf: imageOnlyItems)

        // Video files: standalone (thumbnail generated on demand)
        let videoItems = videoFiles
            .sorted { $0.key < $1.key }
            .map { baseName, videoURL in
                PhotoItem(
                    jpgURL: videoURL,   // Video URL used for thumbnail generation
                    rawURL: nil
                )
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
