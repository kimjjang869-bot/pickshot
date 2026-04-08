import Foundation

struct XMPService {

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
