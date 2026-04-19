import SwiftUI
import AVFoundation

struct ExifInfoView: View {
    let photo: PhotoItem
    @EnvironmentObject var store: PhotoStore
    @State private var loadedExif: ExifData?
    @State private var loadedRawExif: ExifData?
    @State private var jpgSize: Int64 = 0
    @State private var rawSize: Int64 = 0
    @State private var colorProfile: String?
    @State private var loadedIPTC: XMPService.IPTCMetadata?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                headerLine
                sectionDivider

                if let e = loadedRawExif ?? loadedExif {
                    shootingLine(e)
                    sectionDivider
                }

                fileLine

                // === Video Metadata ===
                if photo.isVideoFile {
                    sectionDivider
                    videoMetadataSection
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }

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

                // === IPTC/XMP Metadata ===
                if hasIPTCData {
                    sectionDivider
                    iptcSection
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }

                // === Advanced Classification ===
                if photo.colorMood != nil || photo.compositionType != nil || !photo.dominantColors.isEmpty {
                    sectionDivider
                    advancedClassSection
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }

                // === Keywords ===
                if !photo.keywords.isEmpty {
                    sectionDivider
                    keywordsSection
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
        .onChange(of: photo.id) { _, _ in loadExif() }
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
        let rawExts = FileMatchingService.rawExtensions
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

            // IPTC metadata
            let iptc = XMPService.readIPTCMetadata(from: jpgURL)

            DispatchQueue.main.async {
                self.loadedExif = exif
                self.loadedRawExif = rawExif
                self.loadedIPTC = iptc
                self.jpgSize = jSize
                self.rawSize = rSize
                self.colorProfile = cp
            }
        }
    }

    // MARK: - Advanced Classification Section

    private var advancedClassSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "wand.and.stars")
                    .foregroundColor(.cyan)
                    .font(.system(size: 11))
                Text("AI 분석")
                    .font(.system(size: AppTheme.fontBody, weight: .semibold))
                Spacer()
            }

            // 분위기 + 시간대 + 구도
            HStack(spacing: 8) {
                if let mood = photo.colorMood, mood != "중립", mood != "미분류" {
                    classTagView(mood, color: moodColor(mood))
                }
                if let time = photo.timeOfDay, time != "미분류" {
                    classTagView(time, color: .orange)
                }
                if let comp = photo.compositionType, comp != "기타" {
                    classTagView(comp, color: .purple)
                }
            }

            // 주요 색상
            if !photo.dominantColors.isEmpty {
                HStack(spacing: 4) {
                    Text("색상")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.secondary)
                    ForEach(photo.dominantColors.prefix(3), id: \.self) { color in
                        HStack(spacing: 2) {
                            Circle()
                                .fill(colorForName(color))
                                .frame(width: 8, height: 8)
                            Text(color)
                                .font(.system(size: 9))
                        }
                    }
                }
            }

            // 인물 비율
            if photo.personCoverage > 0.05 {
                HStack(spacing: 4) {
                    Image(systemName: "person.fill")
                        .font(.system(size: 8))
                        .foregroundColor(.blue)
                    Text("인물 \(Int(photo.personCoverage * 100))%")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private func classTagView(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .cornerRadius(3)
    }

    private func moodColor(_ mood: String) -> Color {
        switch mood {
        case "따뜻한": return .orange
        case "차가운": return .blue
        case "비비드": return .pink
        case "차분한": return .gray
        case "어두운": return .indigo
        case "밝은": return .yellow
        case "흑백": return .gray
        default: return .secondary
        }
    }

    private func colorForName(_ name: String) -> Color {
        switch name {
        case "빨강": return .red
        case "주황": return .orange
        case "노랑": return .yellow
        case "초록": return .green
        case "시안": return .cyan
        case "파랑": return .blue
        case "보라": return .purple
        case "핑크": return .pink
        case "검정": return .black
        case "흰색": return .white
        case "회색": return .gray
        default: return .secondary
        }
    }

    // MARK: - IPTC Section

    private var hasIPTCData: Bool {
        if let m = loadedIPTC {
            return !m.title.isEmpty || !m.description.isEmpty ||
                   !m.creator.isEmpty || !m.copyright.isEmpty
        }
        return !photo.iptcTitle.isEmpty || !photo.iptcDescription.isEmpty ||
               !photo.iptcCreator.isEmpty || !photo.iptcCopyright.isEmpty
    }

    private var iptcSection: some View {
        let m = loadedIPTC ?? XMPService.IPTCMetadata()
        let title = m.title.isEmpty ? photo.iptcTitle : m.title
        let desc = m.description.isEmpty ? photo.iptcDescription : m.description
        let creator = m.creator.isEmpty ? photo.iptcCreator : m.creator
        let copyright = m.copyright.isEmpty ? photo.iptcCopyright : m.copyright
        let city = m.city.isEmpty ? photo.iptcCity : m.city
        let country = m.country.isEmpty ? photo.iptcCountry : m.country

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "doc.badge.gearshape")
                    .foregroundColor(.indigo)
                    .font(.system(size: 11))
                Text("메타데이터")
                    .font(.system(size: AppTheme.fontBody, weight: .semibold))
                Spacer()
                Button(action: {
                    store.metadataEditorMode = .single
                    store.showMetadataEditor = true
                }) {
                    Image(systemName: "pencil.circle")
                        .font(.system(size: 12))
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
                .help("메타데이터 편집")
            }

            if !title.isEmpty {
                iptcRow(label: "제목", value: title, icon: "textformat")
            }
            if !desc.isEmpty {
                iptcRow(label: "설명", value: desc, icon: "text.alignleft")
            }
            if !creator.isEmpty {
                iptcRow(label: "작가", value: creator, icon: "person")
            }
            if !copyright.isEmpty {
                iptcRow(label: "저작권", value: copyright, icon: "c.circle")
            }
            if !city.isEmpty || !country.isEmpty {
                let loc = [city, country].filter { !$0.isEmpty }.joined(separator: ", ")
                iptcRow(label: "위치", value: loc, icon: "location")
            }
        }
    }

    private func iptcRow(label: String, value: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 8))
                .foregroundColor(.secondary)
                .frame(width: 12)
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 35, alignment: .trailing)
            Text(value)
                .font(.system(size: 10))
                .lineLimit(2)
        }
    }

    // MARK: - Keywords Section

    private var keywordsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "tag.fill")
                    .foregroundColor(.teal)
                    .font(.system(size: 11))
                Text("키워드")
                    .font(.system(size: AppTheme.fontBody, weight: .semibold))
                Spacer()
                Text("\(photo.keywords.count)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(.teal)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.teal.opacity(0.15))
                    .cornerRadius(4)
            }

            // Flow layout using multiple HStacks
            KeywordFlowLayout(keywords: photo.keywords) { keyword in
                store.keywordFilter = (store.keywordFilter == keyword) ? nil : keyword
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

    // MARK: - Line 1: 카메라 · 렌즈 · ISO · 셔터 · 조리개 · 화각 | 날짜

    private var headerLine: some View {
        let e = displayExif
        return HStack(spacing: 0) {
            if photo.isVideoFile {
                // 비디오: 파일명 표시
                Image(systemName: "film")
                    .font(.system(size: AppTheme.fontCaption))
                    .foregroundColor(.purple)
                Text("  \(photo.fileNameWithExtension)")
                    .font(.system(size: AppTheme.fontBody, weight: .bold))
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                if let model = e?.cameraModel {
                    Text(model).font(.system(size: AppTheme.fontBody, weight: .bold))
                }
                if let lens = e?.lensModel {
                    cellDot
                    Text(lens).font(.system(size: AppTheme.fontCaption)).foregroundColor(.secondary).lineLimit(1)
                }
                if let exif = loadedRawExif ?? loadedExif {
                    if let iso = exif.iso {
                        cellDot; settingItem(value: "\(iso)", label: "ISO", color: iso > 6400 ? .red : iso > 3200 ? .orange : .accentColor)
                    }
                    if let shutter = exif.shutterSpeed { cellDot; settingItem(value: shutter, label: "셔터", color: .accentColor) }
                    if let aperture = exif.aperture { cellDot; settingItem(value: String(format: "f/%.1f", aperture), label: "", color: .accentColor) }
                    if let focal = exif.focalLength { cellDot; settingItem(value: String(format: "%.0fmm", focal), label: "", color: .accentColor) }
                }
            }

            Spacer(minLength: 4)

            if let date = e?.dateTaken {
                Text("\(formatDate(date)) \(formatTime(date))")
                    .font(.system(size: AppTheme.fontCaption, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.6))
            } else if photo.isVideoFile {
                // 비디오는 파일 수정일 표시
                Text("\(formatDate(photo.fileModDate)) \(formatTime(photo.fileModDate))")
                    .font(.system(size: AppTheme.fontCaption, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.6))
            }
        }
        .padding(.horizontal, AppTheme.space12)
        .padding(.vertical, 5)
    }

    // shootingLine은 headerLine에 통합됨
    private func shootingLine(_ exif: ExifData) -> some View { EmptyView() }

    // MARK: - Line 2: 파일 뱃지 | 픽처스타일 + 해상도

    private var fileLine: some View {
        let quality = jpgQualityLabel
        let e = displayExif

        return HStack(spacing: 0) {
            if photo.isVideoFile {
                // Video file
                let ext = photo.jpgURL.pathExtension.uppercased()
                Text(ext).font(.system(size: AppTheme.fontCaption, weight: .bold)).foregroundColor(.white)
                    .padding(.horizontal, 5).padding(.vertical, 1).background(Color.purple.opacity(0.85)).clipShape(Capsule())
                Text(" \(jpgFileSizeStr)").font(.system(size: AppTheme.fontCaption, design: .monospaced)).foregroundColor(.secondary)
                if let dur = photo.videoDuration, dur > 0 {
                    cellDot
                    Text(VideoPlayerManager.formatTime(dur))
                        .font(.system(size: AppTheme.fontCaption, weight: .medium, design: .monospaced)).foregroundColor(.purple)
                }
            } else if photo.isRawOnly {
                // RAW only
                let ext = photo.jpgURL.pathExtension.uppercased()
                Text(ext).font(.system(size: AppTheme.fontCaption, weight: .bold)).foregroundColor(.white)
                    .padding(.horizontal, 5).padding(.vertical, 1).background(Color.orange.opacity(0.85)).clipShape(Capsule())
                Text(" \(jpgFileSizeStr)").font(.system(size: AppTheme.fontCaption, design: .monospaced)).foregroundColor(.secondary)
            } else if photo.hasRAW, let rawURL = photo.rawURL {
                // JPG + RAW
                Text(quality.label).font(.system(size: AppTheme.fontCaption, weight: .bold)).foregroundColor(.white)
                    .padding(.horizontal, 5).padding(.vertical, 1).background(quality.color.opacity(0.85)).clipShape(Capsule())
                Text(" \(jpgFileSizeStr)").font(.system(size: AppTheme.fontCaption, design: .monospaced)).foregroundColor(.secondary)
                cellDot
                Text(rawURL.pathExtension.uppercased()).font(.system(size: AppTheme.fontCaption, weight: .bold)).foregroundColor(.white)
                    .padding(.horizontal, 5).padding(.vertical, 1).background(Color.green.opacity(0.85)).clipShape(Capsule())
                Text(" \(rawFileSizeStr)").font(.system(size: AppTheme.fontCaption, design: .monospaced)).foregroundColor(.secondary)
            } else {
                // JPG only
                Text(quality.label).font(.system(size: AppTheme.fontCaption, weight: .bold)).foregroundColor(.white)
                    .padding(.horizontal, 5).padding(.vertical, 1).background(quality.color.opacity(0.85)).clipShape(Capsule())
                Text(" \(jpgFileSizeStr)").font(.system(size: AppTheme.fontCaption, design: .monospaced)).foregroundColor(.secondary)
            }

            Spacer(minLength: 4)

            // 오른쪽: 픽처스타일 + 해상도 + bit + color
            if let style = e?.pictureStyle {
                HStack(spacing: 3) {
                    Image(systemName: "paintpalette.fill").font(.system(size: 8)).foregroundColor(.purple)
                    Text(style).font(.system(size: AppTheme.fontCaption, weight: .medium)).foregroundColor(.purple)
                }
                cellDot
            }
            if let w = e?.imageWidth, let h = e?.imageHeight {
                let mp = Double(w * h) / 1_000_000.0
                Text("\(w)x\(h) \(String(format: "%.0fMP", mp))")
                    .font(.system(size: AppTheme.fontCaption, design: .monospaced)).foregroundColor(.secondary)
            }
            if let bit = e?.bitDepth { cellDot; Text("\(bit)bit").font(.system(size: AppTheme.fontCaption, design: .monospaced)).foregroundColor(.secondary) }
            if let profile = displayColorProfile { cellDot; Text(profile).font(.system(size: AppTheme.fontCaption)).foregroundColor(.secondary) }
        }
        .padding(.horizontal, AppTheme.space12)
        .padding(.vertical, 5)
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

    // MARK: - Video Metadata Section

    @State private var videoMeta: VideoPlayerManager.VideoMetadata?

    private var videoMetadataSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "film")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.purple)
                Text("비디오 정보")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.purple)
            }

            // SLO-MO 뱃지
            if let meta = videoMeta, let sloMo = meta.slowMoText {
                Text(sloMo)
                    .font(.system(size: 10, weight: .black))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.red.opacity(0.8))
                    .clipShape(Capsule())
            }

            if let meta = videoMeta {
                // Resolution + FPS + Codec
                HStack(spacing: 0) {
                    Text(meta.resolutionText)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                    infoDot
                    Text(meta.fpsText)
                        .font(.system(size: 10, design: .monospaced))
                    infoDot
                    Text(meta.codecBadge)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(meta.isRAWVideo ? Color.orange.opacity(0.85) : Color.purple.opacity(0.7))
                        .clipShape(Capsule())
                }

                // Bitrate + Duration + File size
                HStack(spacing: 0) {
                    Text(meta.bitrateText)
                        .font(.system(size: 10, design: .monospaced))
                    if meta.duration > 0 {
                        infoDot
                        Text(VideoPlayerManager.formatTime(meta.duration))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                    }
                    if meta.fileSize > 0 {
                        infoDot
                        Text(formatSize(meta.fileSize))
                            .font(.system(size: 10, design: .monospaced))
                    }
                }
                .foregroundColor(.secondary)

                // Audio
                if meta.audioChannels > 0 {
                    HStack(spacing: 0) {
                        Image(systemName: "speaker.wave.2")
                            .font(.system(size: 8))
                            .foregroundColor(.secondary)
                        Text(" \(meta.audioChannels)ch")
                            .font(.system(size: 10, design: .monospaced))
                        if meta.audioSampleRate > 0 {
                            infoDot
                            Text(String(format: "%.0fkHz", meta.audioSampleRate / 1000))
                                .font(.system(size: 10, design: .monospaced))
                        }
                    }
                    .foregroundColor(.secondary)
                }

                // LOG/RAW indicator
                if meta.isLOG || meta.isRAWVideo {
                    HStack(spacing: 4) {
                        Text(meta.isRAWVideo ? "RAW Video" : "LOG")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(meta.isRAWVideo ? .orange : .yellow)
                        if let gamma = meta.captureGamma {
                            Text(gamma)
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundColor(.yellow)
                        }
                        if let tf = meta.transferFunction, tf != "ITU_R_709_2" {
                            Text(tf)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        if let cp = meta.colorPrimaries, cp != "ITU_R_709_2" {
                            Text(cp)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            } else {
                Text("로딩 중...")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .onAppear { loadVideoMetadata() }
            }
        }
    }

    private func loadVideoMetadata() {
        guard photo.isVideoFile else { return }
        let mgr = VideoPlayerManager.shared
        // VideoPlayerManager가 같은 영상의 메타데이터를 이미 추출했으면 재사용
        if let existing = mgr.videoMetadata, existing.fileSize > 0 {
            self.videoMeta = existing
            return
        }
        // 없으면 대기 후 재시도 (최대 3회)
        Task {
            for _ in 0..<3 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if let meta = mgr.videoMetadata, meta.fileSize > 0 {
                    await MainActor.run { self.videoMeta = meta }
                    return
                }
            }
        }
    }
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

// MARK: - Keyword Flow Layout

struct KeywordFlowLayout: View {
    let keywords: [String]
    let onTap: (String) -> Void
    @EnvironmentObject var store: PhotoStore

    var body: some View {
        FlowLayout(spacing: 4) {
            ForEach(keywords, id: \.self) { keyword in
                let isActive = store.keywordFilter == keyword
                Text(keyword)
                    .font(.system(size: 10, weight: isActive ? .bold : .medium))
                    .foregroundColor(isActive ? .white : .teal)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(isActive ? Color.teal : Color.teal.opacity(0.12))
                    .cornerRadius(4)
                    .onTapGesture { onTap(keyword) }
            }
        }
    }
}

/// Simple flow layout that wraps items to next line when they exceed available width
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: .unspecified
            )
        }
    }

    private func arrangeSubviews(proposal: ProposedViewSize, subviews: Subviews) -> (positions: [CGPoint], size: CGSize) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            totalWidth = max(totalWidth, x - spacing)
        }

        return (positions, CGSize(width: totalWidth, height: y + rowHeight))
    }
}
