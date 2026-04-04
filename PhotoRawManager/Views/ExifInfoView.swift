import SwiftUI

struct ExifInfoView: View {
    let photo: PhotoItem
    @EnvironmentObject var store: PhotoStore
    @State private var loadedExif: ExifData?
    @State private var loadedRawExif: ExifData?
    @State private var jpgSize: Int64 = 0
    @State private var rawSize: Int64 = 0
    @State private var colorProfile: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                headerLine
                sectionDivider

                if let e = loadedRawExif ?? loadedExif {
                    shootingLine(e)

                    // Picture Style / Creative Look
                    if let style = e.pictureStyle {
                        HStack(spacing: 6) {
                            Image(systemName: "paintpalette.fill")
                                .font(.system(size: 9))
                                .foregroundColor(.purple)
                            Text(style)
                                .font(.system(size: AppTheme.fontBody, weight: .medium))
                                .foregroundColor(.purple)
                        }
                        .padding(.horizontal, AppTheme.space12)
                        .padding(.vertical, 3)
                    }

                    sectionDivider
                }

                fileLine

                if let quality = photo.quality, quality.isAnalyzed {
                    sectionDivider
                    QualitySection(quality: quality)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }

                if photo.aiCategory != nil {
                    sectionDivider
                    aiClassificationSection
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }

                // === Client Comments ===
                if !photo.comments.isEmpty {
                    sectionDivider
                    commentsSection
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .onAppear { loadExif() }
        .onChange(of: photo.id) { _ in loadExif() }
    }

    private static let exifQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInitiated
        return q
    }()

    /// Load EXIF independently — does NOT touch photos array
    private func loadExif() {
        let jpgURL = photo.jpgURL
        let rawURL = photo.rawURL
        let photoID = photo.id
        let rawExts: Set<String> = ["arw","cr2","cr3","nef","nrw","raf","dng","orf","rw2","pef","srw","3fr","nefx"]
        let isRaw = rawExts.contains(jpgURL.pathExtension.lowercased())

        // Cancel previous EXIF loads — only latest photo matters
        Self.exifQueue.cancelAllOperations()

        Self.exifQueue.addOperation {
            var exif = ExifService.extractExif(from: jpgURL)
            if exif == nil || (exif?.cameraModel == nil && isRaw), let rawURL = rawURL {
                let re = ExifService.extractExif(from: rawURL)
                if re != nil { exif = re }
            }

            var rawExif: ExifData?
            var rSize: Int64 = 0
            var cp: String?
            if let rawURL = rawURL {
                rawExif = ExifService.extractExif(from: rawURL)
                rSize = (try? FileManager.default.attributesOfItem(atPath: rawURL.path)[.size] as? Int64) ?? 0
                let opts: [NSString: Any] = [kCGImageSourceShouldCache: false]
                if let src = CGImageSourceCreateWithURL(rawURL as CFURL, opts as CFDictionary),
                   let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] {
                    // Read camera's original color space from EXIF, not macOS output profile
                    let exifDict = props[kCGImagePropertyExifDictionary as String] as? [String: Any]
                    let makerCanon = props["{MakerCanon}"] as? [String: Any]
                    let colorSpaceTag = exifDict?["ColorSpace"] as? Int
                        ?? makerCanon?["ColorSpace"] as? Int

                    if let cs = colorSpaceTag {
                        switch cs {
                        case 1: cp = "sRGB"
                        case 2: cp = "Adobe RGB"
                        case 0xFFFF: cp = "Uncalibrated"  // Often means Adobe RGB
                        default: cp = props["ProfileName"] as? String
                        }
                    } else {
                        cp = props["ProfileName"] as? String
                    }
                }
            }

            let jSize = (try? FileManager.default.attributesOfItem(atPath: jpgURL.path)[.size] as? Int64) ?? 0

            DispatchQueue.main.async {
                self.loadedExif = exif
                self.loadedRawExif = rawExif
                self.jpgSize = jSize
                self.rawSize = rSize
                self.colorProfile = cp
            }
        }
    }

    // MARK: - Client Comments Section

    private var commentsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "bubble.left.fill")
                    .foregroundColor(.orange)
                    .font(.system(size: 11))
                Text("코멘트")
                    .font(.system(size: AppTheme.fontBody, weight: .semibold))
                Spacer()
                Text("\(photo.comments.count)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.15))
                    .cornerRadius(4)
            }

            ForEach(photo.comments.indices, id: \.self) { i in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "person.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.system(size: 14))
                    Text(photo.comments[i])
                        .font(.system(size: AppTheme.fontBody))
                        .foregroundColor(.primary)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.08))
                        .cornerRadius(8)
                }
            }
        }
    }

    // MARK: - AI Classification Section

    private var aiClassificationSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header
            HStack {
                Image(systemName: "sparkles")
                    .foregroundColor(.purple)
                    .font(.system(size: 11))
                Text("AI 분류")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.purple)
                Spacer()
                if let score = photo.aiScore {
                    Text("\(score)점")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(score >= 80 ? .green : score >= 50 ? .yellow : .red)
                }
            }

            // Category + Subcategory
            HStack(spacing: 6) {
                if let cat = photo.aiCategory {
                    Text(cat)
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.purple.opacity(0.2))
                        .cornerRadius(4)
                }
                if let sub = photo.aiSubcategory {
                    Text(sub)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                Spacer()
                if let mood = photo.aiMood {
                    Text(mood)
                        .font(.system(size: 10))
                        .foregroundColor(.cyan)
                }
            }

            // Usability + BestFor
            HStack(spacing: 6) {
                if let usability = photo.aiUsability {
                    let icon: String = {
                        switch usability {
                        case "즉시사용": return "🟢"
                        case "편집후사용": return "🟡"
                        case "참고용": return "🟠"
                        case "삭제후보": return "🔴"
                        default: return "⚪"
                        }
                    }()
                    Text("\(icon) \(usability)")
                        .font(.system(size: 10, weight: .medium))
                }
                if let bestFor = photo.aiBestFor {
                    Text("→ \(bestFor)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }

            // Description
            if let desc = photo.aiDescription {
                Text(desc)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.7))
                    .lineLimit(2)
            }
        }
    }

    // MARK: - Line 1: Header

    private var headerLine: some View {
        let e = displayExif
        return HStack(spacing: 0) {
            // Camera + Lens
            VStack(alignment: .leading, spacing: 2) {
                if let model = e?.cameraModel {
                    Text(model)
                        .font(.system(size: AppTheme.fontHeading, weight: .bold))
                }
                if let lens = e?.lensModel {
                    Text(lens)
                        .font(.system(size: AppTheme.fontBody))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            // Date
            if let date = e?.dateTaken {
                Text("\(formatDate(date))  \(formatTime(date))")
                    .font(.system(size: AppTheme.fontBody, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.6))
            }
        }
        .padding(.horizontal, AppTheme.space12)
        .padding(.vertical, AppTheme.space8)
    }

    // MARK: - Line 2: Shooting Settings

    private func shootingLine(_ exif: ExifData) -> some View {
        HStack(spacing: 0) {
            if let iso = exif.iso {
                settingItem(value: "\(iso)", label: "ISO",
                            color: iso > 6400 ? .red : iso > 3200 ? .orange : .accentColor)
            }
            if let shutter = exif.shutterSpeed {
                cellDot
                settingItem(value: shutter, label: "셔터", color: .accentColor)
            }
            if let aperture = exif.aperture {
                cellDot
                settingItem(value: String(format: "f/%.1f", aperture), label: "조리개", color: .accentColor)
            }
            if let focal = exif.focalLength {
                cellDot
                settingItem(value: String(format: "%.0fmm", focal), label: "초점", color: .accentColor)
            }

            Spacer(minLength: 4)

            // Resolution + MP (right aligned)
            let re = displayExif
            if let w = re?.imageWidth, let h = re?.imageHeight {
                let mp = Double(w * h) / 1_000_000.0
                Text("\(w)x\(h)")
                    .font(.system(size: AppTheme.fontSubhead, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
                Text(String(format: " %.0fMP", mp))
                    .font(.system(size: AppTheme.fontSubhead, weight: .bold))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, AppTheme.space12)
        .padding(.vertical, AppTheme.space8)
    }

    // MARK: - Line 3: File Info

    private var fileLine: some View {
        let quality = jpgQualityLabel
        let e = displayExif

        return HStack(spacing: 0) {
            // JPG pill badge
            HStack(spacing: 4) {
                Text(quality.label)
                    .font(.system(size: AppTheme.fontCaption, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(quality.color.opacity(0.85))
                    .clipShape(Capsule())
                Text(jpgFileSizeStr)
                    .font(.system(size: AppTheme.fontCaption, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            cellDot

            // RAW pill badge
            if photo.hasRAW, let rawURL = photo.rawURL {
                HStack(spacing: 4) {
                    Text(rawURL.pathExtension.uppercased())
                        .font(.system(size: AppTheme.fontCaption, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.85))
                        .clipShape(Capsule())
                    Text(rawFileSizeStr)
                        .font(.system(size: AppTheme.fontCaption, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            } else {
                Text("RAW 없음")
                    .font(.system(size: AppTheme.fontCaption))
                    .foregroundColor(.secondary.opacity(0.6))
            }

            Spacer(minLength: 4)

            // Specs: bit | DPI | color space
            if let bit = e?.bitDepth {
                Text("\(bit)bit")
                    .font(.system(size: AppTheme.fontCaption, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            if let dpi = e?.dpiX {
                cellDot
                Text("\(dpi)dpi")
                    .font(.system(size: AppTheme.fontCaption, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            if let profile = displayColorProfile {
                cellDot
                Text(profile)
                    .font(.system(size: AppTheme.fontCaption, weight: .medium))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, AppTheme.space12)
        .padding(.vertical, AppTheme.space8)
    }

    // MARK: - Small Components

    private func settingItem(value: String, label: String, color: Color) -> some View {
        HStack(spacing: 2) {
            Text(value)
                .font(.system(size: AppTheme.fontSubhead, weight: .bold, design: .monospaced))
                .foregroundColor(color)
            Text(label)
                .font(.system(size: AppTheme.fontMicro))
                .foregroundColor(.secondary.opacity(0.6))
        }
    }

    private var infoDot: some View {
        Text(" · ")
            .font(.system(size: 10))
            .foregroundColor(.gray)
    }

    private var cellDot: some View {
        Text("  ·  ")
            .font(.system(size: 9))
            .foregroundColor(.gray.opacity(0.5))
    }

    private var sectionDivider: some View {
        Rectangle().fill(Color.gray.opacity(0.15)).frame(height: 0.5)
    }

    // MARK: - RAW EXIF (cached in PhotoItem, no disk reads)

    // All data comes from @State (self-loaded), not from photos array
    private var displayExif: ExifData? { loadedRawExif ?? loadedExif }
    private var displayColorProfile: String? { colorProfile }

    // MARK: - JPG Quality

    private var jpgQualityLabel: (label: String, color: Color) {
        guard let e = self.loadedExif,
              let w = e.imageWidth, let h = e.imageHeight else {
            return ("JPG", .gray)
        }
        if let re = loadedRawExif, let rw = re.imageWidth, let rh = re.imageHeight {
            let ratio = Double(w * h) / Double(rw * rh)
            if ratio > 0.9 { return ("JPG L", .yellow) }
            if ratio > 0.4 { return ("JPG M", .orange) }
            return ("JPG S", .gray)
        }
        let mp = Double(w * h) / 1_000_000.0
        if mp > 20 { return ("JPG L", .yellow) }
        if mp > 8 { return ("JPG M", .orange) }
        if mp > 3 { return ("JPG S", .gray) }
        return ("JPG XS", .gray)
    }

    // MARK: - File Sizes

    private var jpgFileSizeStr: String { formatSize(jpgSize) }
    private var rawFileSizeStr: String { formatSize(rawSize) }

    private func formatSize(_ size: Int64) -> String {
        if size <= 0 { return "?" }
        if size < 1024 { return "\(size)B" }
        if size < 1024 * 1024 { return "\(size / 1024)KB" }
        return String(format: "%.1fMB", Double(size) / 1_048_576.0)
    }

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy.MM.dd"; return f
    }()
    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()
    private func formatDate(_ date: Date) -> String { Self.dateFmt.string(from: date) }
    private func formatTime(_ date: Date) -> String { Self.timeFmt.string(from: date) }
}

// MARK: - Quality Section

struct QualitySection: View {
    let quality: QualityAnalysis
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: quality.overallGrade.icon)
                    .foregroundColor(gradeColor(quality.overallGrade))
                Text(quality.overallGrade.rawValue)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(gradeColor(quality.overallGrade))
                Spacer()
                HStack(spacing: 6) {
                    MiniScore(label: "선명", value: Int(quality.sharpnessScore), max: 1000)
                    MiniScore(label: "밝기", value: Int(quality.brightnessScore * 100), max: 100)
                    MiniScore(label: "대비", value: Int(quality.contrastScore * 100), max: 50)
                }
            }
            .padding(6)
            .background(gradeColor(quality.overallGrade).opacity(0.1))
            .cornerRadius(5)

            let grading = quality.gradingIssues
            if !grading.isEmpty {
                ForEach(grading) { issue in
                    HStack(spacing: 4) {
                        Image(systemName: issue.severity.icon)
                            .font(.system(size: 9))
                            .foregroundColor(issue.severity == .bad ? .red : .orange)
                        Text(issue.message)
                            .font(.system(size: 9))
                    }
                }
            }
        }
    }
    private func gradeColor(_ grade: QualityAnalysis.Grade) -> Color {
        switch grade {
        case .excellent: return .green
        case .good: return .blue
        case .average: return .yellow
        case .belowAverage: return .orange
        case .poor: return .red
        }
    }
}

struct MiniScore: View {
    let label: String; let value: Int; let max: Int
    var body: some View {
        VStack(spacing: 2) {
            Text("\(min(value, max))")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
            Text(label).font(.system(size: 7)).foregroundColor(.secondary)
        }
    }
}

struct ExifRow: View {
    let label: String; let value: String
    var body: some View {
        HStack {
            Text(label).font(.caption).foregroundColor(.secondary).frame(width: 50, alignment: .leading)
            Text(value).font(.caption).lineLimit(1)
        }
    }
}

struct ExifBadge: View {
    let label: String; let value: String
    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 11, weight: .medium, design: .monospaced))
            Text(label).font(.system(size: 9)).foregroundColor(.secondary)
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(Color.gray.opacity(0.1)).cornerRadius(4)
    }
}
