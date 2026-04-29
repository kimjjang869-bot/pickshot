//
//  BurstPickerService.swift
//  PhotoRawManager
//
//  v8.9: 연사 그룹에서 베스트 1장 자동 선별.
//  - 사용자가 체크한 기준만 점수에 반영 (가중치 합산).
//  - 상세 항목: 눈뜸 / 얼굴 포커스 / 전체 선명도 / 정노출 / 수평 등.
//  - 결과: 베스트샷 1장에 지정된 마커 부여 (컬러 라벨 초록 / SP / 별점).
//

import Foundation
import Vision
import CoreImage
import AppKit

/// 사용자가 다이얼로그에서 체크한 기준들
struct BurstPickerCriteria {
    var requireEyesOpen: Bool = true          // 눈 감지 않은 사진 우선
    var requireFaceFocus: Bool = true         // 얼굴 영역 선명도
    var requireOverallSharpness: Bool = true  // 전체 선명도
    var requireCorrectExposure: Bool = true   // 히스토그램 균형
    var requireSmile: Bool = false            // 미소/자연스러운 표정
    var requireEyeContact: Bool = false       // 시선 카메라 향함
    var requireMutualGaze: Bool = false       // 여러 얼굴 서로 마주봄
    var requireNoOcclusion: Bool = false      // 얼굴 가림 없음
    var requireNoMotionBlur: Bool = false     // 모션 블러 없음
    var requireNoBlownHighlights: Bool = false // 하이라이트 안 날림
    var requireHorizon: Bool = false          // 수평 맞음
    var requireGoodComposition: Bool = false  // 주제 구도 (삼등분/중앙)
    var useUserPreference: Bool = false       // 내 취향 learning profile 반영
    var userPreferenceWeight: Double = 1.0    // 취향 가중치

    /// 엄격도 0.0 (느슨) ~ 1.0 (엄격) — 기준 점수 통과 임계값
    var strictness: Double = 0.5

    /// 결과 표시 방식
    var resultMarker: ResultMarker = .greenLabel

    enum ResultMarker {
        case greenLabel, spacePick, star4
    }

    // MARK: - 프리셋

    static let weddingEvent: BurstPickerCriteria = {
        var c = BurstPickerCriteria()
        c.requireEyesOpen = true
        c.requireFaceFocus = true
        c.requireOverallSharpness = true
        c.requireCorrectExposure = true
        return c
    }()

    static let portrait: BurstPickerCriteria = {
        var c = BurstPickerCriteria()
        c.requireEyesOpen = true
        c.requireFaceFocus = true
        c.requireSmile = true
        c.requireEyeContact = true
        c.requireNoOcclusion = true
        return c
    }()

    static let landscape: BurstPickerCriteria = {
        var c = BurstPickerCriteria()
        c.requireEyesOpen = false
        c.requireFaceFocus = false
        c.requireOverallSharpness = true
        c.requireCorrectExposure = true
        c.requireHorizon = true
        c.requireGoodComposition = true
        return c
    }()
}

/// 그룹 내 사진 하나의 세부 점수
struct BurstShotScore {
    let url: URL
    let photoID: UUID
    var overall: Double = 0           // 0 ~ 1
    var eyesOpen: Double = 0.5
    var faceFocus: Double = 0.5
    var overallSharpness: Double = 0.5
    var exposure: Double = 0.5
    var smile: Double = 0.5
    var eyeContact: Double = 0.5
    var horizon: Double = 0.5
    var composition: Double = 0.5
    var blowHighlights: Double = 0.5  // 날림 감점 (높을수록 좋음)
    var motionBlur: Double = 0.5      // 블러 없음 (높을수록 좋음)
}

final class BurstPickerService {
    static let shared = BurstPickerService()
    /// v8.9: CIContext 는 GPU Metal queue 포함한 무거운 객체 — 매 호출마다 생성하지 않고 공유.
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private init() {}

    /// 그룹별 베스트샷 선정. 콜백으로 진행률 + 결과 반환.
    /// - Returns: [(group: [PhotoItem], best: PhotoItem)] — 각 그룹에 대한 베스트 1장.
    func pickBest(
        groups: [[PhotoItem]],
        criteria: BurstPickerCriteria,
        onProgress: @escaping (Int, Int) -> Void,
        onComplete: @escaping ([(group: [PhotoItem], best: PhotoItem, scores: [BurstShotScore])]) -> Void
    ) {
        // v9.0.2 crash fix:
        //   1) QoS .userInitiated → .utility (메인 스레드 starvation 차단)
        //   2) 그룹 단위 autoreleasepool (메모리 누적 차단)
        //   3) progress 콜백 throttle (매 10장 또는 50ms 마다 1회 → 1000장 burst 시 main hop 1000→~100)
        //   4) Vision 동시 실행 제한 (단일 ciContext 보호 — Self.visionLock)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            var results: [(group: [PhotoItem], best: PhotoItem, scores: [BurstShotScore])] = []
            let total = groups.reduce(0) { $0 + $1.count }
            var done = 0
            var lastProgressEmit: CFAbsoluteTime = 0

            // v8.9: 엄격도(strictness) — 최고 점수가 이 값 미만이면 그룹을 skip (결과 안 내놓음).
            let minOverall = 0.30 + criteria.strictness * 0.40

            for group in groups {
                // 그룹 단위 autoreleasepool — Vision/CIContext 결과 그룹 끝나면 즉시 해제.
                autoreleasepool {
                    var groupScores: [BurstShotScore] = []
                    for photo in group {
                        autoreleasepool {
                            let s = self.scorePhoto(photo, criteria: criteria)
                            groupScores.append(s)
                        }
                        done += 1
                        // progress throttle: 10장 마다 또는 50ms 경과 시.
                        let now = CFAbsoluteTimeGetCurrent()
                        if done % 10 == 0 || now - lastProgressEmit >= 0.05 {
                            lastProgressEmit = now
                            let d = done
                            DispatchQueue.main.async { onProgress(d, total) }
                        }
                    }
                    if let winner = groupScores.max(by: { $0.overall < $1.overall }),
                       winner.overall >= minOverall,
                       let bestPhoto = group.first(where: { $0.id == winner.photoID }) {
                        results.append((group: group, best: bestPhoto, scores: groupScores))
                    } else if let winner = groupScores.max(by: { $0.overall < $1.overall }) {
                        fputs("[BURST-SKIP] 그룹 (\(group.count)장) 최고 점수 \(String(format: "%.2f", winner.overall)) < 엄격도 바닥 \(String(format: "%.2f", minOverall))\n", stderr)
                    }
                }
            }
            // 마지막 진행률 강제 emit (마무리).
            let finalDone = done
            DispatchQueue.main.async {
                onProgress(finalDone, total)
                onComplete(results)
            }
        }
    }

    /// v9.0.2: Vision + CIContext 동시 실행 직렬화. Vision 은 thread-safe 표방하나,
    ///   공유 CIContext + ImageRequestHandler 조합에서 race condition 가능 → 락으로 보호.
    private static let visionLock = NSLock()

    // MARK: - Scoring

    /// 한 장에 대한 점수 산정. 체크된 항목만 최종 점수에 반영.
    private func scorePhoto(_ photo: PhotoItem, criteria: BurstPickerCriteria) -> BurstShotScore {
        var score = BurstShotScore(url: photo.jpgURL, photoID: photo.id)

        // 1) QualityAnalysis 재사용 (이미 분석됐으면)
        if let q = photo.quality {
            score.overallSharpness = min(1.0, q.sharpnessScore / 200.0)
            // 정노출: brightness 0.3~0.7 이 이상
            let brightDiff = abs(q.brightnessScore - 0.5)
            score.exposure = max(0, 1.0 - brightDiff * 3.0)
            score.blowHighlights = 1.0 - min(1.0, q.highlightClipping * 2.0)
            score.smile = q.smileScore
            score.composition = q.compositionScore
        } else {
            // 분석 안 된 사진은 실시간으로 Vision 이용한 간이 분석
            if let stats = quickAnalyze(url: photo.jpgURL) {
                score.overallSharpness = stats.sharpness
                score.exposure = stats.exposure
                score.blowHighlights = stats.highlights
            }
        }

        // 2) 얼굴 기반 항목 (Vision landmarks) — 체크된 것이 있을 때만 실행
        let needsFaceAnalysis = criteria.requireEyesOpen || criteria.requireFaceFocus
            || criteria.requireSmile || criteria.requireEyeContact
            || criteria.requireMutualGaze || criteria.requireNoOcclusion
        if needsFaceAnalysis, let faceStats = analyzeFaces(url: photo.jpgURL) {
            score.eyesOpen = faceStats.eyesOpen
            score.faceFocus = faceStats.faceFocus
            score.eyeContact = faceStats.eyeContact
            if faceStats.smile > 0 { score.smile = max(score.smile, faceStats.smile) }
        }

        // 3) 수평
        if criteria.requireHorizon {
            score.horizon = analyzeHorizon(url: photo.jpgURL)
        }

        // 4) 가중치 합산 — 체크된 항목만 참여
        var sum: Double = 0
        var weightSum: Double = 0
        func add(_ value: Double, weight: Double, enabled: Bool) {
            guard enabled else { return }
            sum += value * weight
            weightSum += weight
        }
        add(score.eyesOpen,         weight: 1.5, enabled: criteria.requireEyesOpen)
        add(score.faceFocus,        weight: 1.5, enabled: criteria.requireFaceFocus)
        add(score.overallSharpness, weight: 1.3, enabled: criteria.requireOverallSharpness)
        add(score.exposure,         weight: 1.0, enabled: criteria.requireCorrectExposure)
        add(score.smile,            weight: 0.7, enabled: criteria.requireSmile)
        add(score.eyeContact,       weight: 0.8, enabled: criteria.requireEyeContact)
        add(score.horizon,          weight: 0.5, enabled: criteria.requireHorizon)
        add(score.composition,      weight: 0.6, enabled: criteria.requireGoodComposition)
        add(score.blowHighlights,   weight: 0.6, enabled: criteria.requireNoBlownHighlights)
        add(score.motionBlur,       weight: 0.7, enabled: criteria.requireNoMotionBlur)

        // 내 취향 learning — 가중치 큼
        if criteria.useUserPreference && UserPreferenceService.shared.profile.isTrained {
            let prefScore = UserPreferenceService.shared.preferenceScore(for: photo.jpgURL)
            sum += prefScore * (2.0 * criteria.userPreferenceWeight)
            weightSum += 2.0 * criteria.userPreferenceWeight
        }

        if weightSum > 0 {
            score.overall = sum / weightSum
        } else {
            // 아무 기준도 체크 안 되었을 때 — 선명도 기본
            score.overall = score.overallSharpness
        }
        return score
    }

    // MARK: - Vision 분석

    /// 간이 이미지 분석 — QualityAnalysis 없을 때 실시간 Laplacian + 히스토그램.
    private struct QuickStats {
        var sharpness: Double
        var exposure: Double
        var highlights: Double
    }
    private func quickAnalyze(url: URL) -> QuickStats? {
        guard let cg = loadCGImage(url: url, maxPixel: 800) else { return nil }
        let ci = CIImage(cgImage: cg)

        // 밝기 평균
        let avgFilter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: ci,
            kCIInputExtentKey: CIVector(cgRect: ci.extent)
        ])
        var brightness: Double = 0.5
        if let out = avgFilter?.outputImage {
            var rgba = [UInt8](repeating: 0, count: 4)
            let ctx = ciContext
            ctx.render(out, toBitmap: &rgba, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
            // v9.0: UInt8 합산 overflow 방지 — 각 채널 Double 변환 후 합산.
            //   이전: Double(rgba[0] + rgba[1] + rgba[2]) → 255+255+255=765 = UInt8 overflow → arithmetic overflow 크래시.
            brightness = (Double(rgba[0]) + Double(rgba[1]) + Double(rgba[2])) / (3.0 * 255.0)
        }
        let brightDiff = abs(brightness - 0.5)
        let exposure = max(0, 1.0 - brightDiff * 3.0)

        // 선명도 (Laplacian variance 근사) — 간단히 Sobel 같은 엣지 필터 대체
        var sharpness: Double = 0.5
        if let edges = CIFilter(name: "CIEdges", parameters: [
            kCIInputImageKey: ci, kCIInputIntensityKey: 1.0
        ])?.outputImage,
           let stats = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: edges,
            kCIInputExtentKey: CIVector(cgRect: ci.extent)
           ])?.outputImage {
            var rgba = [UInt8](repeating: 0, count: 4)
            ciContext.render(stats, toBitmap: &rgba, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
            let edgeEnergy = Double(rgba[0]) / 255.0
            sharpness = min(1.0, edgeEnergy * 4.0)
        }

        // 하이라이트 날림 비율 — 밝기 > 0.95 픽셀 비율
        let highlights = brightness > 0.85 ? max(0, 0.5 - (brightness - 0.85) * 5.0) : 1.0

        return QuickStats(sharpness: sharpness, exposure: exposure, highlights: highlights)
    }

    /// 얼굴 landmark 기반 눈뜸/포커스/시선/미소 점수.
    private struct FaceStats {
        var eyesOpen: Double    // 0~1 (1 = 완전히 뜸)
        var faceFocus: Double   // 얼굴 영역 선명도
        var eyeContact: Double  // yaw=0 일수록 높음
        var smile: Double       // 입 landmark 기반
    }
    private func analyzeFaces(url: URL) -> FaceStats? {
        guard let cg = loadCGImage(url: url, maxPixel: 1200) else { return nil }
        let req = VNDetectFaceLandmarksRequest()
        if #available(macOS 13.0, *) {
            req.revision = VNDetectFaceLandmarksRequestRevision3
        }
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        // v9.0.2 crash fix: Vision request 직렬화 (CIContext race 방지).
        Self.visionLock.lock()
        defer { Self.visionLock.unlock() }
        do { try handler.perform([req]) } catch { return nil }
        guard let faces = req.results, !faces.isEmpty else {
            // 얼굴 없음 — face 관련 점수는 중립 0.5 로 반환 (감점/가점 없음)
            return FaceStats(eyesOpen: 0.5, faceFocus: 0.5, eyeContact: 0.5, smile: 0.5)
        }
        // 가장 큰 얼굴 기준
        let main = faces.max { a, b in
            a.boundingBox.width * a.boundingBox.height < b.boundingBox.width * b.boundingBox.height
        }!

        // 눈뜸 — eye aspect ratio (세로/가로 비율)
        var eyesOpen: Double = 0.5
        if let lm = main.landmarks {
            if let left = lm.leftEye, let right = lm.rightEye {
                let le = eyeOpenness(left.normalizedPoints)
                let re = eyeOpenness(right.normalizedPoints)
                eyesOpen = min(1.0, (le + re) * 0.5 * 5.0)  // 0.2 아래면 감긴 걸로 취급
            }
        }

        // 시선 (yaw) — 정면일수록 1.0
        var eyeContact: Double = 0.5
        if let yaw = main.yaw?.doubleValue {
            // yaw 0° = 정면, ±30° 이상이면 옆모습
            eyeContact = max(0, 1.0 - abs(yaw) / (.pi / 6))  // π/6 = 30°
        }

        // 미소 — 입 모서리 vs 중앙 높이 차
        var smile: Double = 0.5
        if let lm = main.landmarks, let outerLips = lm.outerLips?.normalizedPoints, outerLips.count >= 6 {
            // 대략 왼끝, 중앙, 오른끝 3점 비교
            let leftY = Double(outerLips.first?.y ?? 0)
            let rightY = Double(outerLips.last?.y ?? 0)
            let centerIdx = outerLips.count / 2
            let centerY = Double(outerLips[centerIdx].y)
            let cornerAvg = (leftY + rightY) / 2.0
            // 입 모서리가 중앙보다 아래면 미소 (normalized y: 아래가 0)
            smile = min(1.0, max(0, (centerY - cornerAvg) * 20.0))
        }

        // 얼굴 영역 선명도 — 얼굴 crop 후 edge energy
        var faceFocus: Double = 0.5
        let bb = main.boundingBox
        let faceRect = CGRect(
            x: bb.origin.x * CGFloat(cg.width),
            y: (1.0 - bb.origin.y - bb.height) * CGFloat(cg.height),
            width: bb.width * CGFloat(cg.width),
            height: bb.height * CGFloat(cg.height)
        )
        if faceRect.width > 30, faceRect.height > 30, let faceCrop = cg.cropping(to: faceRect) {
            let ci = CIImage(cgImage: faceCrop)
            if let edges = CIFilter(name: "CIEdges", parameters: [kCIInputImageKey: ci, kCIInputIntensityKey: 1.0])?.outputImage,
               let stats = CIFilter(name: "CIAreaAverage", parameters: [
                kCIInputImageKey: edges, kCIInputExtentKey: CIVector(cgRect: ci.extent)
               ])?.outputImage {
                var rgba = [UInt8](repeating: 0, count: 4)
                ciContext.render(stats, toBitmap: &rgba, rowBytes: 4,
                                   bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                                   format: .RGBA8, colorSpace: nil)
                faceFocus = min(1.0, Double(rgba[0]) / 255.0 * 5.0)
            }
        }

        return FaceStats(eyesOpen: eyesOpen, faceFocus: faceFocus, eyeContact: eyeContact, smile: smile)
    }

    /// 수평 맞음 점수. 기울기 작을수록 1.0.
    private func analyzeHorizon(url: URL) -> Double {
        guard let cg = loadCGImage(url: url, maxPixel: 1000) else { return 0.5 }
        let req = VNDetectHorizonRequest()
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        // v9.0.2 crash fix: Vision request 직렬화.
        Self.visionLock.lock()
        defer { Self.visionLock.unlock() }
        do { try handler.perform([req]) } catch { return 0.5 }
        guard let angle = req.results?.first?.angle else { return 0.5 }
        // angle 은 라디안. ±1° 이면 완벽, ±5° 이상이면 기울어짐.
        let absDeg = abs(angle) * 180 / .pi
        return max(0, 1.0 - absDeg / 5.0)
    }

    private func eyeOpenness(_ points: [CGPoint]) -> Double {
        guard points.count >= 4 else { return 0.5 }
        // 대략 좌우 가장자리와 위아래 지점의 비율.
        let xs = points.map { $0.x }
        let ys = points.map { $0.y }
        let w = (xs.max() ?? 0) - (xs.min() ?? 0)
        let h = (ys.max() ?? 0) - (ys.min() ?? 0)
        guard w > 0 else { return 0.5 }
        return Double(h / w)  // 열린 눈 ~0.3~0.5, 감긴 눈 ~0.05
    }

    private func loadCGImage(url: URL, maxPixel: CGFloat) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        // v9.0.2 crash fix: IfAbsent: false → 임베디드만 사용 (RAW demosaic 안 함).
        //   풀 RAW demosaic 은 사진당 200~500MB 메모리 → 1000장 burst 메모리 폭발 원인.
        let opts: [NSString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: false
        ]
        if let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) {
            return cg
        }
        // 임베디드 없으면 폴백 (희귀 케이스 — JPG 등).
        let fallbackOpts: [NSString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCache: false
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, fallbackOpts as CFDictionary)
    }
}
