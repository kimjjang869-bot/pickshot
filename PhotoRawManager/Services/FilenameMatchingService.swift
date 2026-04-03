import Foundation

/// Matches a list of filenames (from text input) against current photos in the folder.
/// Supports exact, fuzzy, and partial matching.
struct FilenameMatchingService {

    struct MatchResult {
        let matched: [(filename: String, photoIndex: Int)]
        let unmatched: [String]
        let totalInput: Int
    }

    /// Parse raw text input into individual filenames.
    /// Supports: comma-separated, newline-separated, space-separated, mixed.
    /// Strips extensions, whitespace, quotes, and common prefixes.
    static func parseFilenames(from text: String) -> [String] {
        // Split by common delimiters
        let separators = CharacterSet.newlines.union(CharacterSet(charactersIn: ",;|"))
        var names = text.components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'\u{201C}\u{201D}\u{2018}\u{2019}")) }
            .filter { !$0.isEmpty }

        // If only one item, try space-separated
        if names.count == 1 {
            let spaceSplit = names[0].components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            if spaceSplit.count > 1 {
                names = spaceSplit
            }
        }

        // Remove extensions if present
        return names.map { name in
            let ext = (name as NSString).pathExtension.lowercased()
            let knownExts = FileMatchingService.jpgExtensions
                .union(FileMatchingService.rawExtensions)
                .union(FileMatchingService.imageExtensions)
            if !ext.isEmpty && knownExts.contains(ext) {
                return (name as NSString).deletingPathExtension
            }
            return name
        }
    }

    /// Match parsed filenames against photos in the current folder.
    /// Returns matched photo indices and unmatched filenames.
    static func match(
        filenames: [String],
        photos: [PhotoItem],
        fuzzyThreshold: Int = 3  // Max Levenshtein distance for fuzzy match
    ) -> MatchResult {
        // Build index: lowercase filename → [array indices]
        var nameToIndices: [String: [Int]] = [:]
        for (i, photo) in photos.enumerated() {
            guard !photo.isFolder && !photo.isParentFolder else { continue }
            let baseName = photo.jpgURL.deletingPathExtension().lastPathComponent.lowercased()
            nameToIndices[baseName, default: []].append(i)
        }

        var matched: [(String, Int)] = []
        var unmatched: [String] = []
        var matchedIndices = Set<Int>()

        for name in filenames {
            let lowerName = name.lowercased()
            var found = false

            // 1차: 정확한 매칭
            if let indices = nameToIndices[lowerName] {
                for idx in indices where !matchedIndices.contains(idx) {
                    matched.append((name, idx))
                    matchedIndices.insert(idx)
                    found = true
                    break
                }
                if found { continue }
            }

            // 2차: 부분 매칭 (입력 파일명이 원본에 포함되거나 반대)
            if !found {
                for (baseName, indices) in nameToIndices {
                    if baseName.contains(lowerName) || lowerName.contains(baseName) {
                        for idx in indices where !matchedIndices.contains(idx) {
                            matched.append((name, idx))
                            matchedIndices.insert(idx)
                            found = true
                            break
                        }
                        if found { break }
                    }
                }
            }

            // 3차: 숫자만 추출해서 매칭 (IMG_1234 ↔ DSC_1234)
            if !found {
                let inputNumbers = extractNumbers(from: lowerName)
                if inputNumbers.count >= 3 {  // At least 3 digits to avoid false positives
                    for (baseName, indices) in nameToIndices {
                        let photoNumbers = extractNumbers(from: baseName)
                        if photoNumbers == inputNumbers {
                            for idx in indices where !matchedIndices.contains(idx) {
                                matched.append((name, idx))
                                matchedIndices.insert(idx)
                                found = true
                                break
                            }
                            if found { break }
                        }
                    }
                }
            }

            // 4차: 퍼지 매칭 (Levenshtein distance)
            if !found && fuzzyThreshold > 0 {
                var bestDist = Int.max
                var bestIdx: Int?
                for (baseName, indices) in nameToIndices {
                    let dist = levenshteinDistance(lowerName, baseName)
                    if dist < bestDist && dist <= fuzzyThreshold {
                        for idx in indices where !matchedIndices.contains(idx) {
                            bestDist = dist
                            bestIdx = idx
                            break
                        }
                    }
                }
                if let idx = bestIdx {
                    matched.append((name, idx))
                    matchedIndices.insert(idx)
                    found = true
                }
            }

            if !found {
                unmatched.append(name)
            }
        }

        return MatchResult(matched: matched, unmatched: unmatched, totalInput: filenames.count)
    }

    // MARK: - Helpers

    /// Extract numeric characters from a string (e.g., "IMG_1234" → "1234")
    private static func extractNumbers(from string: String) -> String {
        return string.filter { $0.isNumber }
    }

    /// Levenshtein distance between two strings
    private static func levenshteinDistance(_ s1: String, _ s2: String) -> Int {
        let a = Array(s1)
        let b = Array(s2)
        let m = a.count
        let n = b.count

        if m == 0 { return n }
        if n == 0 { return m }

        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in 0...m { dp[i][0] = i }
        for j in 0...n { dp[0][j] = j }

        for i in 1...m {
            for j in 1...n {
                let cost = a[i-1] == b[j-1] ? 0 : 1
                dp[i][j] = min(
                    dp[i-1][j] + 1,      // deletion
                    dp[i][j-1] + 1,      // insertion
                    dp[i-1][j-1] + cost  // substitution
                )
            }
        }
        return dp[m][n]
    }
}
