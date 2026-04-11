import Foundation
import AppKit
import SwiftUI

struct AFPoint {
    var x: CGFloat      // 0~1 normalized (left=0, right=1)
    var y: CGFloat      // 0~1 normalized (top=0, bottom=1)
    var width: CGFloat?  // optional size (normalized)
    var height: CGFloat? // optional size (normalized)
}

struct ExifData {
    var cameraMake: String?
    var cameraModel: String?
    var lensModel: String?
    var iso: Int?
    var shutterSpeed: String?
    var exposureTime: Double?
    var exposureBias: Double?
    var aperture: Double?
    var focalLength: Double?
    var dateTaken: Date?
    var imageWidth: Int?
    var imageHeight: Int?
    var bitDepth: Int?
    var dpiX: Int?
    var dpiY: Int?
    var afPoint: AFPoint?
    var latitude: Double?
    var longitude: Double?
    var placeName: String?  // 역지오코딩 결과 (시/구/동)

    // Camera Picture Style / Creative Look / Film Simulation
    var pictureStyle: String?       // "Standard", "Portrait", "Vivid", "Classic Chrome" 등
    var pictureStyleColorSpace: String?  // "sRGB", "Adobe RGB"

    // Camera/XMP Rating (0-5)
    var rating: Int?

    var hasGPS: Bool {
        latitude != nil && longitude != nil
    }
}

// MARK: - Quality Analysis

struct QualityIssue: Identifiable {
    let id = UUID()
    let type: IssueType
    let severity: Severity
    let message: String

    enum IssueType {
        // Image analysis based (affects grade)
        case blur
        case outOfFocus      // 초점 미스 (선명 영역 없음)
        case faceOutOfFocus  // 인물 초점 미스
        case overexposed
        case underexposed
        case lowContrast
        case closedEyes
        case duplicate       // 중복/유사 사진
        // EXIF info based (reference only, does NOT affect grade)
        case highISO
        case shakeRisk
        case exposureBias
    }

    enum Severity: String {
        case info = "참고"      // EXIF-based, no grade impact
        case warning = "주의"   // image issue, mild
        case bad = "나쁨"       // image issue, severe

        var icon: String {
            switch self {
            case .info: return "info.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .bad: return "xmark.circle.fill"
            }
        }
    }

    /// Whether this issue affects the overall grade
    var affectsGrade: Bool {
        severity != .info
    }
}

struct QualityAnalysis {
    var issues: [QualityIssue] = []
    var sharpnessScore: Double = 0
    var brightnessScore: Double = 0
    var contrastScore: Double = 0
    var highlightClipping: Double = 0
    var shadowClipping: Double = 0
    var sharpRegionRatio: Double = 0
    var compositionScore: Double = 0
    var nimaScore: Double = 0          // NIMA 미적 품질 점수 (1~10)
    var smileScore: Double = 0         // 표정 점수 (0=무표정, 1=활짝 웃음)
    var faceExpressionGood: Bool = false // 좋은 표정 여부
    var detectedIntent: ShootingIntent?
    var isAnalyzed: Bool = false

    var gradingIssues: [QualityIssue] {
        issues.filter { $0.affectsGrade }
    }

    /// 0-100 단일 점수. NIMA 기반 (있으면) 또는 기존 방식
    var score: Int {
        // NIMA 점수가 있으면 우선 사용 (1~10 → 10~100)
        if nimaScore > 0 {
            let base = nimaScore * 10  // 1~10 → 10~100
            let badPenalty = Double(gradingIssues.filter { $0.severity == .bad }.count) * 10
            let warnPenalty = Double(gradingIssues.filter { $0.severity == .warning }.count) * 5
            return max(0, min(100, Int(base - badPenalty - warnPenalty)))
        }

        // 기존 방식 (NIMA 없을 때 fallback)
        // 선명도: 0-100 (sharpnessScore 일반적으로 0~200 범위)
        let sharpness = min(100, sharpnessScore / 2.0) * 0.4

        // 노출: 밝기가 0.3~0.7 이면 만점, 벗어나면 감점
        let brightDiff = abs(brightnessScore - 0.5)
        let exposure = max(0, 100 - brightDiff * 300) * 0.3

        // 구도: compositionScore 0~1
        let composition = compositionScore * 100 * 0.3

        // 이슈 감점: bad -15, warning -8
        let badPenalty = Double(gradingIssues.filter { $0.severity == .bad }.count) * 15
        let warnPenalty = Double(gradingIssues.filter { $0.severity == .warning }.count) * 8

        return max(0, min(100, Int(sharpness + exposure + composition - badPenalty - warnPenalty)))
    }

    /// 3단계 심플 등급
    var overallGrade: Grade {
        let s = score
        if s >= 70 { return .good }
        if s >= 40 { return .average }
        return .poor
    }

    mutating func finalizeGrade() {
        // score is computed, no caching needed
    }

    enum Grade: String {
        case good = "좋음"
        case average = "보통"
        case poor = "문제"

        // Legacy aliases
        static let excellent = Grade.good
        static let belowAverage = Grade.average

        var icon: String {
            switch self {
            case .good: return "checkmark.circle.fill"
            case .average: return "minus.circle.fill"
            case .poor: return "xmark.circle.fill"
            }
        }
    }
}

// MARK: - Color Label

enum ColorLabel: String, CaseIterable {
    case none = "없음"
    case orange = "주황"
    case yellow = "노랑"
    case green = "초록"
    case blue = "파랑"

    var color: Color? {
        switch self {
        case .none: return nil
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .blue: return .blue
        }
    }

    var key: String {
        switch self {
        case .none: return ""
        case .orange: return "6"
        case .yellow: return "7"
        case .green: return "8"
        case .blue: return "9"
        }
    }
}

// MARK: - PhotoItem

struct PhotoItem: Identifiable, Hashable {
    let id = UUID()
    let jpgURL: URL
    var rawURL: URL?
    var isFolder: Bool = false       // true = this item represents a subfolder
    var isParentFolder: Bool = false  // true = "상위 폴더로 이동" 아이템
    var rating: Int = 0
    var colorLabel: ColorLabel = .none
    var exifData: ExifData?
    var rawExifData: ExifData?
    var rawColorProfile: String?
    var jpgFileSize: Int64 = 0
    var rawFileSize: Int64 = 0
    var fileModDate: Date = .distantPast  // File modification date for stable sorting
    var quality: QualityAnalysis?
    var isCorrected: Bool = false
    var isSpacePicked: Bool = false
    var isGSelected: Bool = false      // G셀렉 (즉시 Google Drive 업로드)
    var duplicateGroupID: Int? = nil  // Same ID = similar photos
    var isBestInGroup: Bool = false   // Best shot in duplicate group
    var sceneTag: String? = nil       // Vision 장면 분류 태그 (인물, 풍경, 음식, etc.)
    var keywords: [String] = []       // IPTC 호환 키워드 (장면분류 + 얼굴 + 실내외 등)
    var faceGroupID: Int? = nil       // 얼굴 그룹 ID (같은 ID = 같은 인물)

    // Client Comments
    var comments: [String] = []        // 코멘트 (pickshot 파일에서 가져옴)

    // AI Smart Classification
    var aiCategory: String? = nil      // 클린샷/인물/군중/무대/분위기/디테일/비하인드/기념
    var aiSubcategory: String? = nil   // 세부 분류
    var aiMood: String? = nil          // 분위기
    var aiUsability: String? = nil     // 즉시사용/편집후사용/참고용/삭제후보
    var aiBestFor: String? = nil       // 용도 추천
    var aiDescription: String? = nil   // 한 줄 설명
    var aiScore: Int? = nil            // 0~100 활용도 점수

    var fileName: String {
        jpgURL.deletingPathExtension().lastPathComponent
    }

    var fileNameWithExtension: String {
        jpgURL.lastPathComponent
    }

    var hasRAW: Bool {
        rawURL != nil
    }

    /// RAW only (no separate JPG - jpgURL points to RAW file)
    var isRawOnly: Bool {
        let ext = jpgURL.pathExtension.lowercased()
        return FileMatchingService.rawExtensions.contains(ext)
    }

    /// Image file (HEIC, PSD, TIFF - not JPG or RAW)
    var isImageFile: Bool {
        let ext = jpgURL.pathExtension.lowercased()
        return FileMatchingService.imageExtensions.contains(ext)
    }

    /// Video file (MOV, MP4, AVI, M4V)
    var isVideoFile: Bool {
        let ext = jpgURL.pathExtension.lowercased()
        return FileMatchingService.videoExtensions.contains(ext)
    }

    /// Generic file (not image, not RAW, not video)
    var isGenericFile: Bool {
        let ext = jpgURL.pathExtension.lowercased()
        return !FileMatchingService.jpgExtensions.contains(ext) &&
               !FileMatchingService.rawExtensions.contains(ext) &&
               !FileMatchingService.imageExtensions.contains(ext) &&
               !FileMatchingService.videoExtensions.contains(ext)
    }

    /// JPG only (no RAW paired)
    var isJpgOnly: Bool {
        !hasRAW && !isRawOnly && !isImageFile && !isVideoFile && !isGenericFile
    }

    /// File type badge text and color
    var fileTypeBadge: (text: String, color: String) {
        if isGenericFile {
            let ext = jpgURL.pathExtension.uppercased()
            return (ext.isEmpty ? "FILE" : ext, "gray")  // Generic file
        } else if isVideoFile {
            let ext = jpgURL.pathExtension.uppercased()
            return (ext, "purple")         // Video
        } else if isImageFile {
            let ext = jpgURL.pathExtension.uppercased()
            return (ext, "teal")           // HEIC/PSD/TIFF
        } else if isRawOnly {
            let ext = jpgURL.pathExtension.uppercased()
            return (ext.isEmpty ? "RAW" : ext, "orange")  // NEF, CR3, ARW 등
        } else if hasRAW {
            return ("R+J", "green")        // RAW + JPG
        } else {
            return ("JPG", "blue")         // JPG만
        }
    }

    var rawExtension: String? {
        rawURL?.pathExtension.uppercased()
    }

    var hasQualityIssues: Bool {
        guard let q = quality else { return false }
        return !q.gradingIssues.isEmpty
    }

    /// AI Pick: 점수 75점 이상 + 심각한 문제 없음
    var isAIPick: Bool {
        guard let q = quality, q.isAnalyzed else { return false }
        return q.score >= 75 && q.gradingIssues.filter({ $0.severity == .bad }).isEmpty
    }

    static func == (lhs: PhotoItem, rhs: PhotoItem) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
