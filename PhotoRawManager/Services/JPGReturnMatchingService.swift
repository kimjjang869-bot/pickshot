import Foundation

/// Matches returned JPG files from a client folder against RAW files in the current folder.
/// Client returns edited JPGs → find corresponding original RAW files.
struct JPGReturnMatchingService {

    struct MatchResult {
        let matched: [(jpgURL: URL, photoIndex: Int, matchType: MatchType)]
        let unmatched: [URL]
        let totalInput: Int
    }

    enum MatchType: String {
        case exact = "정확"
        case fuzzy = "유사"
        case numberPattern = "번호"
    }

    /// Scan a folder for JPG files
    static func scanJPGs(in folderURL: URL) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return [] }

        var jpgs: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            let ext = url.pathExtension.lowercased()
            if FileMatchingService.jpgExtensions.contains(ext) ||
               FileMatchingService.imageExtensions.contains(ext) {
                jpgs.append(url)
            }
        }
        return jpgs
    }

    /// Match returned JPGs against current photos (RAW files in folder)
    static func match(
        returnedJPGs: [URL],
        photos: [PhotoItem],
        fuzzyThreshold: Int = 3
    ) -> MatchResult {
        // Build index from current photos
        var nameToIndices: [String: [Int]] = [:]
        var numberToIndices: [String: [Int]] = [:]

        for (i, photo) in photos.enumerated() {
            guard !photo.isFolder && !photo.isParentFolder else { continue }
            let baseName = photo.jpgURL.deletingPathExtension().lastPathComponent.lowercased()
            nameToIndices[baseName, default: []].append(i)

            let numbers = baseName.filter { $0.isNumber }
            if numbers.count >= 3 {
                numberToIndices[numbers, default: []].append(i)
            }
        }

        var matched: [(URL, Int, MatchType)] = []
        var unmatched: [URL] = []
        var matchedIndices = Set<Int>()

        for jpgURL in returnedJPGs {
            let jpgName = jpgURL.deletingPathExtension().lastPathComponent.lowercased()
            var found = false

            // 1차: 정확한 파일명 매칭
            if let indices = nameToIndices[jpgName] {
                for idx in indices where !matchedIndices.contains(idx) {
                    matched.append((jpgURL, idx, .exact))
                    matchedIndices.insert(idx)
                    found = true
                    break
                }
            }

            // 2차: 부분 매칭
            if !found {
                for (baseName, indices) in nameToIndices {
                    if baseName.contains(jpgName) || jpgName.contains(baseName) {
                        for idx in indices where !matchedIndices.contains(idx) {
                            matched.append((jpgURL, idx, .fuzzy))
                            matchedIndices.insert(idx)
                            found = true
                            break
                        }
                        if found { break }
                    }
                }
            }

            // 3차: 숫자 패턴 매칭
            if !found {
                let jpgNumbers = jpgName.filter { $0.isNumber }
                if jpgNumbers.count >= 3, let indices = numberToIndices[jpgNumbers] {
                    for idx in indices where !matchedIndices.contains(idx) {
                        matched.append((jpgURL, idx, .numberPattern))
                        matchedIndices.insert(idx)
                        found = true
                        break
                    }
                }
            }

            // 4차: 퍼지 매칭 (Levenshtein)
            if !found && fuzzyThreshold > 0 {
                var bestDist = Int.max
                var bestIdx: Int?
                for (baseName, indices) in nameToIndices {
                    let dist = levenshteinDistance(jpgName, baseName)
                    if dist < bestDist && dist <= fuzzyThreshold {
                        for idx in indices where !matchedIndices.contains(idx) {
                            bestDist = dist
                            bestIdx = idx
                            break
                        }
                    }
                }
                if let idx = bestIdx {
                    matched.append((jpgURL, idx, .fuzzy))
                    matchedIndices.insert(idx)
                    found = true
                }
            }

            if !found {
                unmatched.append(jpgURL)
            }
        }

        return MatchResult(matched: matched, unmatched: unmatched, totalInput: returnedJPGs.count)
    }

    // MARK: - Helpers

    private static func levenshteinDistance(_ s1: String, _ s2: String) -> Int {
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
