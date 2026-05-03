import Foundation
import AppKit
import ImageIO

struct XMPService {

    // MARK: - JPG EXIF Rating 직접 쓰기 (XMP 사이드카 없이 라이트룸 인식)

    /// JPG 파일에 EXIF Rating + Label 직접 쓰기 (재압축 없음)
    static func writeRatingToJPG(url: URL, rating: Int, label: String? = nil) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard ["jpg", "jpeg"].contains(ext) else { return false }

        guard let fileData = try? Data(contentsOf: url),
              let source = CGImageSourceCreateWithData(fileData as CFData, nil) else { return false }
        guard let uti = CGImageSourceGetType(source) else { return false }

        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(mutableData, uti, 1, nil) else { return false }

        // 기존 메타데이터 복사
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return false }
        var newProps = properties

        // EXIF Rating 설정
        // Microsoft Rating (0-5) — Lightroom이 읽는 표준
        newProps[kCGImagePropertyExifDictionary as String] = {
            let exif = (properties[kCGImagePropertyExifDictionary as String] as? [String: Any]) ?? [:]
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
            plog("[XMP] JPG EXIF 쓰기 실패: \(error.localizedDescription)\n")
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
            guard photo.rating > 0 || photo.colorLabel != .none else { continue }

            let label = photo.colorLabel != .none ? photo.colorLabel.xmpName : nil
            if writeRatingToJPG(url: photo.jpgURL, rating: photo.rating, label: label) {
                count += 1
            }
        }
        return count
    }

    /// v9.1.4 (Lightroom 호환): 모든 사진(JPG + RAW)에 XMP 사이드카 일괄 생성.
    /// - JPG 는 EXIF + XMP 임베딩 (writeRatingToJPG)
    /// - RAW 는 .xmp 사이드카 생성 (writeRating)
    /// - Lightroom Classic 의 "메타데이터 → 파일에서 읽기" 로 자동 인식.
    /// - Returns: (jpgCount, xmpSidecarCount, totalProcessed)
    @discardableResult
    static func exportLightroomCompatible(photos: [PhotoItem]) -> (jpg: Int, xmp: Int, total: Int) {
        var jpgCount = 0
        var xmpCount = 0
        var total = 0
        for photo in photos {
            guard !photo.isFolder, !photo.isParentFolder else { continue }
            // 별점 또는 컬러 라벨이 있는 사진만 (메타데이터 없는 사진 skip)
            guard photo.rating > 0 || photo.colorLabel != .none else { continue }
            total += 1

            let label = photo.colorLabel != .none ? photo.colorLabel.xmpName : nil
            let ext = photo.jpgURL.pathExtension.lowercased()
            // JPG 는 EXIF + XMP 임베딩
            if ["jpg", "jpeg"].contains(ext) {
                if writeRatingToJPG(url: photo.jpgURL, rating: photo.rating, label: label) {
                    jpgCount += 1
                }
            }
            // RAW 가 있으면 .xmp 사이드카 생성 — Lightroom 표준
            if let rawURL = photo.rawURL {
                writeRating(for: rawURL, rating: photo.rating, label: label, spacePicked: false)
                xmpCount += 1
            }
            // JPG 만 있는 경우도 .xmp 사이드카 추가 (호환성 ↑)
            if photo.rawURL == nil && ["jpg", "jpeg"].contains(ext) {
                writeRating(for: photo.jpgURL, rating: photo.rating, label: label, spacePicked: false)
                xmpCount += 1
            }
        }
        return (jpg: jpgCount, xmp: xmpCount, total: total)
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

    /// Map ColorLabel to XMP label string (Lightroom 호환)
    static func xmpLabel(from colorLabel: String) -> String? {
        switch colorLabel.lowercased() {
        case "빨강", "red": return "Red"
        case "노랑", "yellow": return "Yellow"
        case "초록", "green": return "Green"
        case "파랑", "blue": return "Blue"
        case "보라", "purple": return "Purple"
        // 하위 호환: 기존 "주황" → "Red"로 매핑
        case "주황", "orange": return "Red"
        default: return nil
        }
    }

    /// Map XMP label string to internal ColorLabel raw value (Lightroom → PickShot)
    static func colorLabelKey(from xmpLabel: String) -> String? {
        switch xmpLabel.lowercased() {
        case "red": return "빨강"
        case "yellow": return "노랑"
        case "green": return "초록"
        case "blue": return "파랑"
        case "purple": return "보라"
        // 하위 호환
        case "orange": return "빨강"
        case "select": return nil
        default: return nil
        }
    }

    // MARK: - IPTC Metadata

    /// IPTC 메타데이터 구조체
    struct IPTCMetadata {
        var title: String = ""
        var description: String = ""
        var creator: String = ""
        var copyright: String = ""
        var keywords: [String] = []
        var usageTerms: String = ""
        var instructions: String = ""
        var city: String = ""
        var country: String = ""
        var event: String = ""
    }

    /// 파일에서 IPTC/XMP 메타데이터 읽기
    static func readIPTCMetadata(from url: URL) -> IPTCMetadata? {
        let opts: [NSString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, opts as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            return nil
        }

        var meta = IPTCMetadata()
        let iptc = properties[kCGImagePropertyIPTCDictionary as String] as? [String: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]

        // IPTC fields
        meta.title = iptc[kCGImagePropertyIPTCObjectName as String] as? String ?? ""
        meta.description = iptc[kCGImagePropertyIPTCCaptionAbstract as String] as? String ?? ""
        meta.creator = iptc[kCGImagePropertyIPTCByline as String] as? String
            ?? (iptc["By-line"] as? [String])?.first ?? ""
        meta.copyright = iptc[kCGImagePropertyIPTCCopyrightNotice as String] as? String ?? ""
        meta.instructions = iptc[kCGImagePropertyIPTCSpecialInstructions as String] as? String ?? ""
        meta.city = iptc[kCGImagePropertyIPTCCity as String] as? String ?? ""
        meta.country = iptc[kCGImagePropertyIPTCCountryPrimaryLocationName as String] as? String ?? ""

        // Keywords (array)
        if let kw = iptc[kCGImagePropertyIPTCKeywords as String] as? [String] {
            meta.keywords = kw
        }

        // TIFF fallback
        if meta.description.isEmpty {
            meta.description = tiff[kCGImagePropertyTIFFImageDescription as String] as? String ?? ""
        }
        if meta.copyright.isEmpty {
            meta.copyright = tiff[kCGImagePropertyTIFFCopyright as String] as? String ?? ""
        }

        // XMP sidecar fallback
        let xmpURL = self.xmpURL(for: url)
        if FileManager.default.fileExists(atPath: xmpURL.path),
           let xmpContent = try? String(contentsOf: xmpURL, encoding: .utf8) {
            if meta.title.isEmpty, let val = extractXMPValue(xmpContent, tag: "dc:title") { meta.title = val }
            if meta.description.isEmpty, let val = extractXMPValue(xmpContent, tag: "dc:description") { meta.description = val }
            if meta.creator.isEmpty, let val = extractXMPValue(xmpContent, tag: "dc:creator") { meta.creator = val }
            if meta.copyright.isEmpty, let val = extractXMPValue(xmpContent, tag: "dc:rights") { meta.copyright = val }
            if meta.usageTerms.isEmpty, let val = extractXMPValue(xmpContent, tag: "xmpRights:UsageTerms") { meta.usageTerms = val }
            if meta.keywords.isEmpty { meta.keywords = extractXMPArray(xmpContent, tag: "dc:subject") }
        }

        return meta
    }

    /// JPG 파일에 IPTC 메타데이터 쓰기 (재압축 없음)
    static func writeIPTCMetadata(url: URL, metadata: IPTCMetadata) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard ["jpg", "jpeg"].contains(ext) else {
            // RAW/기타 파일: XMP 사이드카에 쓰기
            return writeIPTCToXMPSidecar(for: url, metadata: metadata)
        }

        guard let data = try? Data(contentsOf: url),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let uti = CGImageSourceGetType(source) else { return false }

        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(mutableData, uti, 1, nil) else { return false }

        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return false }
        var newProps = properties

        // IPTC Dictionary
        var iptc = (properties[kCGImagePropertyIPTCDictionary as String] as? [String: Any]) ?? [:]
        if !metadata.title.isEmpty { iptc[kCGImagePropertyIPTCObjectName as String] = metadata.title }
        if !metadata.description.isEmpty { iptc[kCGImagePropertyIPTCCaptionAbstract as String] = metadata.description }
        if !metadata.creator.isEmpty { iptc[kCGImagePropertyIPTCByline as String] = [metadata.creator] }
        if !metadata.copyright.isEmpty { iptc[kCGImagePropertyIPTCCopyrightNotice as String] = metadata.copyright }
        if !metadata.instructions.isEmpty { iptc[kCGImagePropertyIPTCSpecialInstructions as String] = metadata.instructions }
        if !metadata.city.isEmpty { iptc[kCGImagePropertyIPTCCity as String] = metadata.city }
        if !metadata.country.isEmpty { iptc[kCGImagePropertyIPTCCountryPrimaryLocationName as String] = metadata.country }
        if !metadata.keywords.isEmpty { iptc[kCGImagePropertyIPTCKeywords as String] = metadata.keywords }
        newProps[kCGImagePropertyIPTCDictionary as String] = iptc

        // TIFF Dictionary (일부 앱 호환)
        var tiff = (properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any]) ?? [:]
        if !metadata.description.isEmpty { tiff[kCGImagePropertyTIFFImageDescription as String] = metadata.description }
        if !metadata.copyright.isEmpty { tiff[kCGImagePropertyTIFFCopyright as String] = metadata.copyright }
        newProps[kCGImagePropertyTIFFDictionary as String] = tiff

        CGImageDestinationAddImageFromSource(dest, source, 0, newProps as CFDictionary)

        guard CGImageDestinationFinalize(dest) else { return false }

        do {
            try (mutableData as Data).write(to: url, options: .atomic)
            // XMP 사이드카에도 쓰기 (Lightroom 호환)
            _ = writeIPTCToXMPSidecar(for: url, metadata: metadata)
            return true
        } catch {
            plog("[XMP] IPTC 쓰기 실패: \(error.localizedDescription)\n")
            return false
        }
    }

    /// XMP 사이드카에 IPTC 메타데이터 쓰기 (RAW 파일용)
    @discardableResult
    static func writeIPTCToXMPSidecar(for imageURL: URL, metadata: IPTCMetadata) -> Bool {
        let url = xmpURL(for: imageURL)

        // 기존 XMP에서 rating/label 보존
        var ratingAttr = ""
        var labelAttr = ""
        if let existing = readRating(for: imageURL) {
            ratingAttr = "\n    xmp:Rating=\"\(existing.rating)\""
            if let label = existing.label { labelAttr = "\n    xmp:Label=\"\(label)\"" }
        }

        // Keywords → dc:subject 배열
        let keywordsXML: String
        if metadata.keywords.isEmpty {
            keywordsXML = ""
        } else {
            let items = metadata.keywords.map { "          <rdf:li>\(escapeXML($0))</rdf:li>" }.joined(separator: "\n")
            keywordsXML = """

              <dc:subject>
                <rdf:Bag>
            \(items)
                </rdf:Bag>
              </dc:subject>
            """
        }

        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description
            xmlns:xmp="http://ns.adobe.com/xap/1.0/"
            xmlns:dc="http://purl.org/dc/elements/1.1/"
            xmlns:xmpRights="http://ns.adobe.com/xap/1.0/rights/"
            xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/"\(ratingAttr)\(labelAttr)>
          <dc:title><rdf:Alt><rdf:li xml:lang="x-default">\(escapeXML(metadata.title))</rdf:li></rdf:Alt></dc:title>
          <dc:description><rdf:Alt><rdf:li xml:lang="x-default">\(escapeXML(metadata.description))</rdf:li></rdf:Alt></dc:description>
          <dc:creator><rdf:Seq><rdf:li>\(escapeXML(metadata.creator))</rdf:li></rdf:Seq></dc:creator>
          <dc:rights><rdf:Alt><rdf:li xml:lang="x-default">\(escapeXML(metadata.copyright))</rdf:li></rdf:Alt></dc:rights>\(keywordsXML)
          <xmpRights:UsageTerms><rdf:Alt><rdf:li xml:lang="x-default">\(escapeXML(metadata.usageTerms))</rdf:li></rdf:Alt></xmpRights:UsageTerms>
          <photoshop:Instructions>\(escapeXML(metadata.instructions))</photoshop:Instructions>
          <photoshop:City>\(escapeXML(metadata.city))</photoshop:City>
          <photoshop:Country>\(escapeXML(metadata.country))</photoshop:Country>
        </rdf:Description>
        </rdf:RDF>
        </x:xmpmeta>
        """

        do {
            try xml.data(using: .utf8)?.write(to: url, options: .atomic)
            return true
        } catch {
            plog("[XMP] 사이드카 쓰기 실패: \(error.localizedDescription)\n")
            return false
        }
    }

    /// 배치 IPTC 쓰기 (선택된 사진들에 동일 메타데이터 적용)
    static func batchWriteIPTC(photos: [PhotoItem], metadata: IPTCMetadata, fieldsToApply: Set<String>) -> Int {
        var count = 0
        for photo in photos {
            guard !photo.isFolder, !photo.isParentFolder else { continue }

            // 기존 메타데이터 읽기 → 선택된 필드만 덮어쓰기
            var merged = readIPTCMetadata(from: photo.jpgURL) ?? IPTCMetadata()
            if fieldsToApply.contains("title") { merged.title = metadata.title }
            if fieldsToApply.contains("description") { merged.description = metadata.description }
            if fieldsToApply.contains("creator") { merged.creator = metadata.creator }
            if fieldsToApply.contains("copyright") { merged.copyright = metadata.copyright }
            if fieldsToApply.contains("keywords") { merged.keywords = metadata.keywords }
            if fieldsToApply.contains("usageTerms") { merged.usageTerms = metadata.usageTerms }
            if fieldsToApply.contains("instructions") { merged.instructions = metadata.instructions }
            if fieldsToApply.contains("city") { merged.city = metadata.city }
            if fieldsToApply.contains("country") { merged.country = metadata.country }

            if writeIPTCMetadata(url: photo.jpgURL, metadata: merged) {
                count += 1
            }
        }
        return count
    }

    // MARK: - XML Helpers

    private static func escapeXML(_ str: String) -> String {
        str.replacingOccurrences(of: "&", with: "&amp;")
           .replacingOccurrences(of: "<", with: "&lt;")
           .replacingOccurrences(of: ">", with: "&gt;")
           .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func extractXMPValue(_ content: String, tag: String) -> String? {
        // <tag>...<rdf:li xml:lang="x-default">VALUE</rdf:li>...</tag>
        let pattern = "<\(tag)>[\\s\\S]*?<rdf:li[^>]*>([^<]+)</rdf:li>"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)),
              let range = Range(match.range(at: 1), in: content) else { return nil }
        let val = String(content[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        return val.isEmpty ? nil : val
    }

    private static func extractXMPArray(_ content: String, tag: String) -> [String] {
        // <tag><rdf:Bag><rdf:li>VALUE1</rdf:li><rdf:li>VALUE2</rdf:li></rdf:Bag></tag>
        let pattern = "<\(tag)>[\\s\\S]*?<rdf:(?:Bag|Seq)>([\\s\\S]*?)</rdf:(?:Bag|Seq)>"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)),
              let range = Range(match.range(at: 1), in: content) else { return [] }
        let bagContent = String(content[range])

        let itemPattern = "<rdf:li>([^<]+)</rdf:li>"
        guard let itemRegex = try? NSRegularExpression(pattern: itemPattern) else { return [] }
        let matches = itemRegex.matches(in: bagContent, range: NSRange(bagContent.startIndex..., in: bagContent))
        return matches.compactMap { m in
            guard let r = Range(m.range(at: 1), in: bagContent) else { return nil }
            return String(bagContent[r]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
