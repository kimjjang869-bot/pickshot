import Foundation
import CoreGraphics

/// 한 장의 모든 비파괴 보정값을 담는 구조체.
/// 원본 파일은 절대 건드리지 않으며, 이 구조체만 JSON 으로 저장됨.
///
/// 저장 위치 (이중화):
/// - L1: UserDefaults 키 `develop:<absolute_path>`
/// - L2: 폴더당 하나 `.pickshot_develop.json` (여러 파일 매핑)
///
/// 모든 숫자는 **정규화/표준 단위** 로 유지해서 JSON 호환성/버전업에 유리:
/// - 색온도·틴트: -100 ~ +100 (UI 레이어에서 K / G-M 으로 변환)
/// - 노출: -2.0 ~ +2.0 EV (CIExposureAdjust · CIRAWFilter.exposure 와 동일 단위)
/// - 커브 포인트: 0.0 ~ 1.0 정규화 좌표
/// - 크롭 사각형: 0.0 ~ 1.0 정규화 좌표 (이미지 크기 독립)
/// - 크롭 회전: 도(degree), -45 ~ +45
struct DevelopSettings: Codable, Hashable {

    // MARK: - Version

    /// 포맷 버전. 향후 필드 추가/변경 시 마이그레이션 판단에 사용.
    var version: Int = 1

    // MARK: - White Balance

    /// true 면 Shades of Gray 자동 WB 적용. temperature / tint 는 수동 오프셋 (자동 위에 추가 조정).
    var wbAuto: Bool = false

    /// 색온도 오프셋: -100 (차갑게) ~ +100 (따뜻하게)
    /// 내부 렌더링 파이프라인에서 약 2000K~12000K 범위로 매핑
    var temperature: Double = 0

    /// 틴트 오프셋: -100 (초록) ~ +100 (마젠타)
    var tint: Double = 0

    // MARK: - Exposure

    /// true 면 히스토그램 기반 자동 노출. exposure 는 추가 오프셋.
    var exposureAuto: Bool = false

    /// 노출 보정: -2.0 ~ +2.0 EV (CIExposureAdjust 의 `inputEV` 와 동일 스케일)
    var exposure: Double = 0

    // MARK: - Tone Curve

    /// true 면 히스토그램 매칭 기반 자동 커브. curvePoints 는 추가 편집.
    var curveAuto: Bool = false

    /// 커브 컨트롤 포인트 (정규화 0~1, x=입력 y=출력).
    /// 빈 배열 = 선형 (보정 없음). 5개 이하 권장 (CIToneCurve 는 5개까지).
    var curvePoints: [CGPoint] = []

    // MARK: - Crop

    /// 크롭 사각형 (정규화 0~1). nil = 크롭 안 함 (전체 프레임).
    var cropRect: CGRect? = nil

    /// 회전 각도 (degree). -45 ~ +45. 크롭과 함께 적용.
    var cropRotation: Double = 0

    /// 종횡비 프리셋 라벨 (UI 표시용, 예: "3:2"). nil = 자유.
    var cropAspectLabel: String? = nil

    // MARK: - Convenience

    /// 기본값(보정 안 한 상태)인지 검사. 히스토리/UI 분기에 사용.
    var isDefault: Bool {
        !wbAuto && temperature == 0 && tint == 0 &&
        !exposureAuto && exposure == 0 &&
        !curveAuto && curvePoints.isEmpty &&
        cropRect == nil && cropRotation == 0
    }

    /// 특정 필드군만 복사. 설정 붙여넣기 시 선택 적용에 사용.
    enum ComponentMask: String, CaseIterable, Codable {
        case whiteBalance
        case exposure
        case curve
        case crop

        var displayName: String {
            switch self {
            case .whiteBalance: return "화이트밸런스"
            case .exposure: return "노출"
            case .curve: return "커브"
            case .crop: return "크롭"
            }
        }
    }

    /// `source` 의 지정된 component 만 현재 구조체로 덮어씀.
    /// 설정 복사/붙여넣기 시 "WB 만 복사, 크롭은 유지" 같은 유스케이스용.
    mutating func apply(_ source: DevelopSettings, components: Set<ComponentMask>) {
        if components.contains(.whiteBalance) {
            wbAuto = source.wbAuto
            temperature = source.temperature
            tint = source.tint
        }
        if components.contains(.exposure) {
            exposureAuto = source.exposureAuto
            exposure = source.exposure
        }
        if components.contains(.curve) {
            curveAuto = source.curveAuto
            curvePoints = source.curvePoints
        }
        if components.contains(.crop) {
            cropRect = source.cropRect
            cropRotation = source.cropRotation
            cropAspectLabel = source.cropAspectLabel
        }
    }

    /// 이 구조체에서 조정된(기본값과 다른) 컴포넌트 집합 반환. UI 뱃지 표시용.
    var touchedComponents: Set<ComponentMask> {
        var s: Set<ComponentMask> = []
        if wbAuto || temperature != 0 || tint != 0 { s.insert(.whiteBalance) }
        if exposureAuto || exposure != 0 { s.insert(.exposure) }
        if curveAuto || !curvePoints.isEmpty { s.insert(.curve) }
        if cropRect != nil || cropRotation != 0 { s.insert(.crop) }
        return s
    }

    /// 전체 리셋.
    mutating func reset() {
        self = DevelopSettings()
    }

    /// 특정 component 만 리셋.
    mutating func reset(_ components: Set<ComponentMask>) {
        let blank = DevelopSettings()
        apply(blank, components: components)
    }

    // MARK: - Preset (사용자 저장 프리셋)

    /// 이 설정을 프리셋으로 저장할 때 사용하는 래퍼. 이름·설명·썸네일 이미지 경로 포함.
    struct Preset: Codable, Hashable, Identifiable {
        var id: UUID = UUID()
        var name: String
        var summary: String = ""   // "+0.3EV · 5200K" 같은 짧은 요약 (자동 생성)
        var settings: DevelopSettings
        var createdAt: Date = Date()
        var thumbnailFilename: String? = nil  // ~/Library/Application Support/PickShot/Presets/Thumbs/<id>.jpg
    }
}

// MARK: - CGPoint Codable 편의 (기본 제공되지만 명시)

extension DevelopSettings {
    /// CIToneCurve 가 받는 5개 Split vector 형태로 변환.
    /// 포인트가 5개 미만이면 선형 포인트로 보간해 채움, 5개 초과면 균등 샘플링.
    func normalizedCurvePoints() -> [CGPoint] {
        guard !curvePoints.isEmpty else {
            return [CGPoint(x: 0, y: 0),
                    CGPoint(x: 0.25, y: 0.25),
                    CGPoint(x: 0.5, y: 0.5),
                    CGPoint(x: 0.75, y: 0.75),
                    CGPoint(x: 1, y: 1)]
        }
        let sorted = curvePoints.sorted { $0.x < $1.x }
        if sorted.count == 5 { return sorted }
        // 5개로 맞추기: 부족하면 양 끝 고정 후 균등 보간, 많으면 균등 샘플.
        if sorted.count < 5 {
            var result = sorted
            while result.count < 5 {
                // 가장 큰 gap 중앙에 보간 포인트 삽입
                var maxGapIdx = 0
                var maxGap: CGFloat = 0
                for i in 0..<(result.count - 1) {
                    let g = result[i + 1].x - result[i].x
                    if g > maxGap { maxGap = g; maxGapIdx = i }
                }
                let midX = (result[maxGapIdx].x + result[maxGapIdx + 1].x) / 2
                let midY = (result[maxGapIdx].y + result[maxGapIdx + 1].y) / 2
                result.insert(CGPoint(x: midX, y: midY), at: maxGapIdx + 1)
            }
            return result
        } else {
            // 균등 5개 샘플
            var result: [CGPoint] = []
            for i in 0..<5 {
                let t = Double(i) / 4.0
                let idxF = t * Double(sorted.count - 1)
                let idx0 = Int(idxF.rounded(.down))
                let idx1 = min(idx0 + 1, sorted.count - 1)
                let frac = idxF - Double(idx0)
                let x = sorted[idx0].x + (sorted[idx1].x - sorted[idx0].x) * frac
                let y = sorted[idx0].y + (sorted[idx1].y - sorted[idx0].y) * frac
                result.append(CGPoint(x: x, y: y))
            }
            return result
        }
    }

    /// 간단한 요약 문자열 — 프리셋/툴팁용.
    var shortSummary: String {
        var parts: [String] = []
        if wbAuto { parts.append("AWB") }
        if temperature != 0 || tint != 0 {
            let t = Int(temperature)
            parts.append(t >= 0 ? "WB +\(t)" : "WB \(t)")
        }
        if exposureAuto { parts.append("AutoExp") }
        if exposure != 0 { parts.append(String(format: "%+.1fEV", exposure)) }
        if curveAuto { parts.append("AutoCurve") }
        if !curvePoints.isEmpty { parts.append("Curve") }
        if cropRect != nil { parts.append("Crop") }
        if cropRotation != 0 { parts.append(String(format: "↻%+.0f°", cropRotation)) }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }
}
