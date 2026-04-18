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
    var commentDetails: [(filename: String, comments: [String])] = []  // 파일별 코멘트 상세
    var sourceFolderName: String = ""
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

        // 기존 앱 형식 시도
        if let file = try? JSONDecoder().decode(PickshotFile.self, from: data) {
            return applyNativePickshot(file: file, to: &photos, photoIndex: photoIndex)
        }

        // 웹 뷰어 형식 시도 (version: String, photos 배열 포함)
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let photosArray = json["photos"] as? [[String: Any]] {
            fputs("[PICKSHOT] 웹 뷰어 형식 감지\n", stderr)
            return applyWebViewerPickshot(json: json, photosArray: photosArray, to: &photos, photoIndex: photoIndex)
        }

        AppLogger.log(.error, "Failed to decode pickshot file")
        return nil
    }

    // 웹 뷰어에서 생성된 .pickshot 파일 처리 (고객 피드백 — clientSelected/clientComments/clientName)
    private static func applyWebViewerPickshot(json: [String: Any], photosArray: [[String: Any]], to photos: inout [PhotoItem], photoIndex: [UUID: Int]) -> PickshotImportResult? {
        let sessionName = (json["session"] as? [String: Any])?["name"] as? String ?? json["sessionName"] as? String ?? ""
        // 고객 이름 — 최상위 clientName / client / session.client 등 여러 위치 탐색
        let clientName: String? = (json["clientName"] as? String)
            ?? (json["client"] as? String)
            ?? ((json["session"] as? [String: Any])?["clientName"] as? String)
            ?? ((json["session"] as? [String: Any])?["client"] as? String)

        var matched: [(name: String, rating: Int, spacePick: Bool)] = []
        var unmatched: [String] = []
        var commentsCount = 0
        var commentDetails: [(String, [String])] = []

        for photoInfo in photosArray {
            let filename = photoInfo["filename"] as? String ?? ""
            let originalFilename = photoInfo["originalFilename"] as? String ?? filename
            let selected = photoInfo["selected"] as? Bool ?? false
            let comment = photoInfo["comment"] as? String ?? ""
            let rating = (photoInfo["rating"] as? Int) ?? ((photoInfo["rating"] as? NSNumber)?.intValue ?? 0)
            // 펜 그림 (있을 때만) — JSON 통째로 보관 후 필요 시 파싱
            // 빈 배열([])은 저장하지 않음 — 펜 안 그린 사진에도 보더가 뜨는 문제 방지
            var penJSON: String? = nil
            if let pen = photoInfo["penDrawings"], !(pen is NSNull) {
                if let penArr = pen as? [Any], !penArr.isEmpty,
                   let penData = try? JSONSerialization.data(withJSONObject: pen) {
                    penJSON = String(data: penData, encoding: .utf8)
                    fputs("[PICKSHOT] 🎨 펜 데이터 감지: \(filename) — \(penArr.count)개 stroke, JSON \(penJSON?.count ?? 0)자\n", stderr)
                } else if let penArr = pen as? [Any], penArr.isEmpty {
                    fputs("[PICKSHOT] penDrawings 빈 배열: \(filename) (스킵)\n", stderr)
                }
            }

            // 원본 파일명으로 매칭 (확장자 무시)
            let baseName = (originalFilename as NSString).deletingPathExtension.lowercased()
            var didMatch = false

            for i in 0..<photos.count {
                let photoBase = (photos[i].jpgURL.lastPathComponent as NSString).deletingPathExtension.lowercased()
                if photoBase == baseName {
                    // 고객 셀렉은 clientSelected 로 저장 (내 SP 와 분리)
                    if selected {
                        photos[i].clientSelected = true
                        photos[i].clientName = clientName
                    }
                    // 코멘트도 고객 코멘트로 분리 저장
                    if !comment.isEmpty {
                        photos[i].clientComments.append(comment)
                        if let name = clientName, !name.isEmpty, photos[i].clientName == nil {
                            photos[i].clientName = name
                        }
                        commentsCount += 1
                        commentDetails.append((originalFilename, [comment]))
                    }
                    // 펜 그림 저장
                    if let pen = penJSON {
                        photos[i].clientPenDrawingsJSON = pen
                    }
                    // 고객 별점 저장 (0 이면 덮어쓰지 않음 — 여러 pickshot merge 대비)
                    if rating > 0 {
                        photos[i].clientRating = rating
                        if let name = clientName, !name.isEmpty, photos[i].clientName == nil {
                            photos[i].clientName = name
                        }
                    }
                    matched.append((name: originalFilename, rating: rating, spacePick: selected))
                    didMatch = true
                    break
                }
            }
            if !didMatch { unmatched.append(originalFilename) }
        }

        return PickshotImportResult(
            matched: matched,
            unmatched: unmatched,
            totalInFile: photosArray.count,
            commentsCount: commentsCount,
            commentDetails: commentDetails,
            sourceFolderName: sessionName
        )
    }

    // 기존 네이티브 .pickshot 파일 처리
    private static func applyNativePickshot(file: PickshotFile, to photos: inout [PhotoItem], photoIndex: [UUID: Int]) -> PickshotImportResult {

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
        var commentDetails: [(filename: String, comments: [String])] = []
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
                // 코멘트 상세 수집
                if let comments = entry.comments, !comments.isEmpty {
                    commentDetails.append((filename: entry.name, comments: comments))
                }
            } else {
                unmatched.append(entry.name)
            }
        }

        AppLogger.log(.export, "Imported pickshot: \(matched.count) matched, \(unmatched.count) unmatched, \(commentsCount) comments from \(file.sourceFolderName)")

        return PickshotImportResult(
            matched: matched,
            unmatched: unmatched,
            totalInFile: file.files.count,
            commentsCount: commentsCount,
            commentDetails: commentDetails,
            sourceFolderName: file.sourceFolderName
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
