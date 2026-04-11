import Foundation
import AppKit
import ImageIO

struct XMPService {

    // MARK: - JPG EXIF Rating 직접 쓰기 (XMP 사이드카 없이 라이트룸 인식)

    /// JPG 파일에 EXIF Rating + Label 직접 쓰기 (재압축 없음)
    static func writeRatingToJPG(url: URL, rating: Int, label: String? = nil) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard ["jpg", "jpeg"].contains(ext) else { return false }

        guard let source = CGImageSourceCreateWithData(try! Data(contentsOf: url) as CFData, nil) else { return false }
        guard let uti = CGImageSourceGetType(source) else { return false }

        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(mutableData, uti, 1, nil) else { return false }

        // 기존 메타데이터 복사
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return false }
        var newProps = properties

        // EXIF Rating 설정
        // Microsoft Rating (0-5) — Lightroom이 읽는 표준
        newProps[kCGImagePropertyExifDictionary as String] = {
            var exif = (properties[kCGImagePropertyExifDictionary as String] as? [String: Any]) ?? [:]
            // UserComment에 Rating 저장 (일부 앱 호환)
            return exif
        }()

        // XMP에 Rating + Label 임베딩
        var xmpDict = (properties["{http://ns.adobe.com/xap/1.0/}"] as? [String: Any]) ?? [:]
        xmpDict["Rating"] = rating
        if let label = label, !label.isEmpty {
            xmpDict["Label"] = label
        }
        newProps["{http://ns.adobe.com/xap/1.0/}"] = xmpDict

        // IPTC에도 Urgency로 매핑 (Lightroom 호환)
        var iptc = (properties[kCGImagePropertyIPTCDictionary as String] as? [String: Any]) ?? [:]
        iptc[kCGImagePropertyIPTCStarRating as String] = rating
        newProps[kCGImagePropertyIPTCDictionary as String] = iptc

        // 재압축 없이 메타데이터만 복사
        CGImageDestinationAddImageFromSource(dest, source, 0, newProps as CFDictionary)

        guard CGImageDestinationFinalize(dest) else { return false }

        // 원본 파일에 덮어쓰기
        do {
            try (mutableData as Data).write(to: url, options: .atomic)
            return true
        } catch {
            fputs("[XMP] JPG EXIF 쓰기 실패: \(error.localizedDescription)\n", stderr)
            return false
        }
    }

    /// 내보내기 시 JPG에 별점/라벨 임베딩 (배치)
    static func embedRatingsToJPGs(photos: [PhotoItem]) -> Int {
        var count = 0
        for photo in photos {
            guard !photo.isFolder, !photo.isParentFolder else { continue }
            let ext = photo.jpgURL.pathExtension.lowercased()
            guard ["jpg", "jpeg"].contains(ext) else { continue }
            guard photo.rating > 0 || photo.isSpacePicked else { continue }

            let label = photo.colorLabel != .none ? photo.colorLabel.rawValue : (photo.isSpacePicked ? "Red" : nil)
            if writeRatingToJPG(url: photo.jpgURL, rating: photo.rating, label: label) {
                count += 1
            }
        }
        return count
    }

    // MARK: - XMP File URL

    /// Find .xmp sidecar file URL for a given image URL
    static func xmpURL(for imageURL: URL) -> URL {
        imageURL.deletingPathExtension().appendingPathExtension("xmp")
    }

    // MARK: - Read

    /// Read rating and label from XMP sidecar file
    static func readRating(for imageURL: URL) -> (rating: Int, label: String?)? {
        let url = xmpURL(for: imageURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url),
              let content = String(data: data, encoding: .utf8) else { return nil }

        var rating: Int?
        var label: String?

        // Parse xmp:Rating="N"
        if let range = content.range(of: #"xmp:Rating="(\d)"#, options: .regularExpression) {
            let match = content[range]
            if let digitRange = match.range(of: #"\d"#, options: .regularExpression) {
                if let r = Int(match[digitRange]), r >= 0, r <= 5 {
                    rating = r
                }
            }
        }

        // Parse xmp:Label="..."
        if let range = content.range(of: #"xmp:Label="([^"]*)"#, options: .regularExpression) {
            let match = String(content[range])
            if let start = match.range(of: "=\"") {
                let value = String(match[start.upperBound...])
                if !value.isEmpty {
                    label = value
                }
            }
        }

        guard let r = rating, r > 0 else { return nil }
        return (rating: r, label: label)
    }

    // MARK: - Write

    /// Write XMP sidecar file with rating, label, and spacePicked flag
    static func writeRating(for imageURL: URL, rating: Int, label: String?, spacePicked: Bool) {
        let url = xmpURL(for: imageURL)

        var attrs = "xmp:Rating=\"\(rating)\""
        // spacePicked + colorLabel 둘 다 있으면 colorLabel 우선 (덮어쓰기 방지)
        if spacePicked && (label == nil || label?.isEmpty == true) {
            attrs += "\n    xmp:Label=\"Red\""
        } else if let label = label, !label.isEmpty {
            attrs += "\n    xmp:Label=\"\(label)\""
        }

        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description xmlns:xmp="http://ns.adobe.com/xap/1.0/"
            \(attrs)/>
        </rdf:RDF>
        </x:xmpmeta>
        """

        try? xml.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    // MARK: - Label Mapping

    /// Map ColorLabel to XMP label string
    static func xmpLabel(from colorLabel: String) -> String? {
        switch colorLabel.lowercased() {
        case "주황", "orange": return "Orange"
        case "노랑", "yellow": return "Yellow"
        case "초록", "green": return "Green"
        case "파랑", "blue": return "Blue"
        default: return nil
        }
    }

    /// Map XMP label string to internal ColorLabel raw value
    static func colorLabelKey(from xmpLabel: String) -> String? {
        switch xmpLabel.lowercased() {
        case "orange": return "주황"
        case "yellow": return "노랑"
        case "green": return "초록"
        case "blue": return "파랑"
        case "select": return nil  // spacePicked marker, not a color label
        default: return nil
        }
    }
}
