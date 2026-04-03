import Foundation
import AppKit

// MARK: - Pickshot Selection File (.pickshot)

struct PickshotFile: Codable {
    let version: Int
    let appVersion: String
    let exportDate: String
    let sourceFolderName: String
    let totalPhotos: Int
    let selectedPhotos: Int
    var files: [PickshotEntry]
}

struct PickshotEntry: Codable {
    let name: String          // Filename without extension (e.g., "SP3_5081")
    let rating: Int           // 0-5
    let spacePick: Bool       // SP select
    let gSelect: Bool         // G select
    let colorLabel: String?   // Color label
    var comments: [String]?   // Client comments for this photo
}

struct PickshotImportResult {
    var matched: [(name: String, rating: Int, spacePick: Bool)]
    var unmatched: [String]
    var totalInFile: Int
    var commentsCount: Int    // Total comments imported
}

class PickshotFileService {

    // MARK: - Export

    static func exportSelection(photos: [PhotoItem], folderName: String) -> URL? {
        let selected = photos.filter { $0.rating > 0 || $0.isSpacePicked || $0.isGSelected || !$0.comments.isEmpty }
        guard !selected.isEmpty else { return nil }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        let entries = selected.map { photo -> PickshotEntry in
            let name = photo.jpgURL.deletingPathExtension().lastPathComponent
            return PickshotEntry(
                name: name,
                rating: photo.rating,
                spacePick: photo.isSpacePicked,
                gSelect: photo.isGSelected,
                colorLabel: photo.colorLabel != .none ? photo.colorLabel.rawValue : nil,
                comments: photo.comments.isEmpty ? nil : photo.comments
            )
        }

        let file = PickshotFile(
            version: 2,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "3.2",
            exportDate: dateFormatter.string(from: Date()),
            sourceFolderName: folderName,
            totalPhotos: photos.filter { !$0.isFolder && !$0.isParentFolder }.count,
            selectedPhotos: entries.count,
            files: entries
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        guard let data = try? encoder.encode(file) else { return nil }

        // Save dialog
        let panel = NSSavePanel()
        panel.title = "셀렉 내보내기"
        panel.message = "셀렉 파일을 저장합니다"
        panel.allowedContentTypes = [.init(filenameExtension: "pickshot")!]
        panel.nameFieldStringValue = "\(folderName)_셀렉.pickshot"
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        do {
            try data.write(to: url)
            AppLogger.log(.export, "Exported \(entries.count) selections to \(url.lastPathComponent)")
            return url
        } catch {
            AppLogger.log(.error, "Failed to export pickshot: \(error)")
            return nil
        }
    }

    // MARK: - Import

    static func importSelection(to photos: inout [PhotoItem], photoIndex: [UUID: Int]) -> PickshotImportResult? {
        // Open dialog
        let panel = NSOpenPanel()
        panel.title = "셀렉 가져오기"
        panel.message = ".pickshot 파일을 선택하세요"
        panel.allowedContentTypes = [.init(filenameExtension: "pickshot")!]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        return applyPickshotFile(url: url, to: &photos, photoIndex: photoIndex)
    }

    static func applyPickshotFile(url: URL, to photos: inout [PhotoItem], photoIndex: [UUID: Int]) -> PickshotImportResult? {
        guard let data = try? Data(contentsOf: url) else {
            AppLogger.log(.error, "Failed to read pickshot file")
            return nil
        }

        guard let file = try? JSONDecoder().decode(PickshotFile.self, from: data) else {
            AppLogger.log(.error, "Failed to decode pickshot file")
            return nil
        }

        // Build name → index mapping for current photos
        var nameToIndices: [String: [Int]] = [:]
        for (i, photo) in photos.enumerated() {
            guard !photo.isFolder && !photo.isParentFolder else { continue }
            let name = photo.jpgURL.deletingPathExtension().lastPathComponent
            nameToIndices[name, default: []].append(i)
        }

        var matched: [(name: String, rating: Int, spacePick: Bool)] = []
        var unmatched: [String] = []

        var commentsCount = 0
        for entry in file.files {
            if let indices = nameToIndices[entry.name] {
                for idx in indices {
                    photos[idx].rating = entry.rating
                    photos[idx].isSpacePicked = entry.spacePick
                    photos[idx].isGSelected = entry.gSelect
                    if let label = entry.colorLabel {
                        photos[idx].colorLabel = ColorLabel(rawValue: label) ?? .none
                    }
                    if let comments = entry.comments, !comments.isEmpty {
                        photos[idx].comments = comments
                        commentsCount += comments.count
                    }
                }
                matched.append((name: entry.name, rating: entry.rating, spacePick: entry.spacePick))
            } else {
                unmatched.append(entry.name)
            }
        }

        AppLogger.log(.export, "Imported pickshot: \(matched.count) matched, \(unmatched.count) unmatched, \(commentsCount) comments from \(url.lastPathComponent)")

        return PickshotImportResult(
            matched: matched,
            unmatched: unmatched,
            totalInFile: file.files.count,
            commentsCount: commentsCount
        )
    }

    // MARK: - Handle file open (double-click .pickshot)

    static func handleOpenFile(url: URL, store: PhotoStore) {
        // Ask user to select the folder containing their RAW/JPG files
        let panel = NSOpenPanel()
        panel.title = "원본 폴더 선택"
        panel.message = "셀렉을 적용할 RAW/JPG 폴더를 선택하세요"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let folderURL = panel.url else { return }

        // Load the folder first
        store.loadFolder(folderURL, restoreRatings: true)

        // Wait for folder to load, then apply selections
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let result = applyPickshotFile(url: url, to: &store.photos, photoIndex: store._photoIndex)
            if let result = result {
                store.photosVersion += 1
                store.lastImportResult = result
                store.showImportResult = true
            }
        }
    }
}
