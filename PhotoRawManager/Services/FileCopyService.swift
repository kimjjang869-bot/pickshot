import Foundation
import AppKit

struct CopyResult {
    var totalFiles: Int = 0
    var copiedJPG: Int = 0
    var copiedRAW: Int = 0
    var copiedXMP: Int = 0
    var failedFiles: [String] = []
    var verified: Bool = false
}

struct FileCopyService {

    // MARK: - Standard Export (JPG + RAW folders)

    static func copyPhotos(
        photos: [PhotoItem],
        to destinationURL: URL,
        jpgFolderName: String = "JPG",
        rawFolderName: String = "RAW",
        progress: @escaping (Double) -> Void
    ) -> CopyResult {
        let fileManager = FileManager.default
        var result = CopyResult()

        let jpgName = jpgFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "JPG" : jpgFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawName = rawFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "RAW" : rawFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let jpgFolder = destinationURL.appendingPathComponent(jpgName)
        let rawFolder = destinationURL.appendingPathComponent(rawName)

        do {
            try fileManager.createDirectory(at: jpgFolder, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: rawFolder, withIntermediateDirectories: true)
        } catch {
            result.failedFiles.append("폴더 생성 실패: \(error.localizedDescription)")
            return result
        }

        let photosWithRAW = photos.filter { $0.hasRAW }
        let totalOperations = photos.count + photosWithRAW.count
        result.totalFiles = totalOperations
        var completed = 0

        for photo in photos {
            let destURL = jpgFolder.appendingPathComponent(photo.jpgURL.lastPathComponent)
            do {
                if fileManager.fileExists(atPath: destURL.path) {
                    try fileManager.removeItem(at: destURL)
                }
                try fileManager.copyItem(at: photo.jpgURL, to: destURL)
                result.copiedJPG += 1
            } catch {
                result.failedFiles.append("JPG 복사 실패: \(photo.fileName)")
            }
            completed += 1
            progress(Double(completed) / Double(totalOperations))
        }

        for photo in photosWithRAW {
            guard let rawURL = photo.rawURL else { continue }
            let destURL = rawFolder.appendingPathComponent(rawURL.lastPathComponent)
            do {
                if fileManager.fileExists(atPath: destURL.path) {
                    try fileManager.removeItem(at: destURL)
                }
                try fileManager.copyItem(at: rawURL, to: destURL)
                result.copiedRAW += 1
            } catch {
                result.failedFiles.append("RAW 복사 실패: \(photo.fileName)")
            }
            completed += 1
            progress(Double(completed) / Double(totalOperations))
        }

        result.verified = verify(photos: photos, jpgFolder: jpgFolder, rawFolder: rawFolder)
        return result
    }

    // MARK: - Lightroom Export (RAW + XMP sidecar with ratings)

    static func exportForLightroom(
        photos: [PhotoItem],
        to destinationURL: URL,
        progress: @escaping (Double) -> Void
    ) -> CopyResult {
        let fileManager = FileManager.default
        var result = CopyResult()

        // Lightroom expects RAW + XMP in the same folder
        do {
            try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        } catch {
            result.failedFiles.append("폴더 생성 실패: \(error.localizedDescription)")
            return result
        }

        // RAW + JPG 모두 지원 (JPG only도 XMP 생성)
        let totalOperations = photos.count * 2
        result.totalFiles = totalOperations
        var completed = 0

        for photo in photos {
            // 1. 파일 복사 (RAW 우선, 없으면 JPG)
            let sourceURL = photo.rawURL ?? photo.jpgURL
            let destFile = destinationURL.appendingPathComponent(sourceURL.lastPathComponent)
            do {
                if fileManager.fileExists(atPath: destFile.path) {
                    try fileManager.removeItem(at: destFile)
                }
                try fileManager.copyItem(at: sourceURL, to: destFile)
                if photo.hasRAW { result.copiedRAW += 1 } else { result.copiedJPG += 1 }
            } catch {
                result.failedFiles.append("복사 실패: \(photo.fileName)")
            }

            // JPG도 같이 복사 (RAW+JPG 쌍)
            if photo.hasRAW {
                let jpgDest = destinationURL.appendingPathComponent(photo.jpgURL.lastPathComponent)
                if !fileManager.fileExists(atPath: jpgDest.path) {
                    try? fileManager.copyItem(at: photo.jpgURL, to: jpgDest)
                    result.copiedJPG += 1
                }
            }

            completed += 1
            progress(Double(completed) / Double(totalOperations))

            // 2. XMP sidecar 생성 (RAW 또는 JPG 파일명 기준)
            let xmpFileName = sourceURL.deletingPathExtension().lastPathComponent + ".xmp"
            let xmpDest = destinationURL.appendingPathComponent(xmpFileName)
            do {
                let xmpContent = generateXMP(rating: photo.rating, isSpacePicked: photo.isSpacePicked, fileName: sourceURL.lastPathComponent)
                try xmpContent.write(to: xmpDest, atomically: true, encoding: .utf8)
                result.copiedXMP += 1
            } catch {
                result.failedFiles.append("XMP 생성 실패: \(photo.fileName)")
            }
            completed += 1
            progress(Double(completed) / Double(totalOperations))
        }

        result.verified = result.failedFiles.isEmpty
        return result
    }

    // MARK: - XMP Sidecar Generation

    private static func generateXMP(rating: Int, isSpacePicked: Bool = false, fileName: String) -> String {
        let ratingValue = max(0, min(5, rating))
        // Space Pick → Red label for Lightroom filtering; otherwise use rating-based label
        let label: String
        if isSpacePicked {
            label = "Red"
        } else {
            switch ratingValue {
            case 5: label = "Winner"
            case 4: label = "Winner"
            case 3: label = "Approved"
            case 2: label = "Review"
            case 1: label = "To Do"
            default: label = ""
            }
        }

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="PickShot v6.0">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about=""
              xmlns:xmp="http://ns.adobe.com/xap/1.0/"
              xmlns:xmpMM="http://ns.adobe.com/xap/1.0/mm/"
              xmlns:dc="http://purl.org/dc/elements/1.1/"
              xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
              xmp:Rating="\(ratingValue)"
              xmp:Label="\(label)"
              xmp:CreatorTool="PickShot v6.0"
              crs:RawFileName="\(fileName)">
            </rdf:Description>
          </rdf:RDF>
        </x:xmpmeta>
        """
    }

    // MARK: - Open Lightroom

    static func openLightroom(folderURL: URL) {
        let lightroomPaths = [
            "/Applications/Adobe Lightroom Classic/Adobe Lightroom Classic.app",
            "/Applications/Adobe Lightroom Classic.app",
            "/Applications/Adobe Lightroom.app"
        ]

        for path in lightroomPaths {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: path) {
                NSWorkspace.shared.open(
                    [folderURL],
                    withApplicationAt: url,
                    configuration: NSWorkspace.OpenConfiguration()
                )
                return
            }
        }

        // Lightroom not found - just open folder in Finder
        NSWorkspace.shared.open(folderURL)
    }

    // MARK: - Verify

    private static func verify(
        photos: [PhotoItem],
        jpgFolder: URL,
        rawFolder: URL
    ) -> Bool {
        let fileManager = FileManager.default

        for photo in photos {
            let jpgDest = jpgFolder.appendingPathComponent(photo.jpgURL.lastPathComponent)
            guard fileManager.fileExists(atPath: jpgDest.path) else { return false }

            guard let srcSize = try? fileManager.attributesOfItem(atPath: photo.jpgURL.path)[.size] as? Int,
                  let dstSize = try? fileManager.attributesOfItem(atPath: jpgDest.path)[.size] as? Int,
                  srcSize == dstSize else {
                return false
            }

            if let rawURL = photo.rawURL {
                let rawDest = rawFolder.appendingPathComponent(rawURL.lastPathComponent)
                guard fileManager.fileExists(atPath: rawDest.path) else { return false }

                guard let srcRawSize = try? fileManager.attributesOfItem(atPath: rawURL.path)[.size] as? Int,
                      let dstRawSize = try? fileManager.attributesOfItem(atPath: rawDest.path)[.size] as? Int,
                      srcRawSize == dstRawSize else {
                    return false
                }
            }
        }
        return true
    }
}
