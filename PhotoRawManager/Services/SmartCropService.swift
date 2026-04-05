import Foundation
import CoreImage
import Vision

// MARK: - SmartCropService
// 어텐션 기반 스마트 크롭 + 얼굴 인식 + 삼분할 법칙

struct SmartCropService {

    // MARK: - 최적 크롭 영역 제안

    /// 어텐션 히트맵 + 얼굴 감지 + 삼분할 법칙 기반 최적 크롭 영역 제안
    /// - Parameters:
    ///   - cgImage: 원본 이미지
    ///   - aspectRatio: 원하는 비율 (nil이면 자유 비율)
    /// - Returns: 정규화된 CGRect (0~1 범위)
    static func suggestCrop(cgImage: CGImage, aspectRatio: CGFloat? = nil) -> CGRect {
        let imageWidth = CGFloat(cgImage.width)
        let imageHeight = CGFloat(cgImage.height)

        // 1. 어텐션 영역 감지
        let attentionRect = detectAttentionArea(cgImage: cgImage)

        // 2. 얼굴 영역 감지
        let faceRects = detectFaces(cgImage: cgImage)

        // 3. 주요 영역 결합 (얼굴 우선)
        let subjectArea: CGRect
        if !faceRects.isEmpty {
            // 모든 얼굴을 포함하는 영역 + 헤드룸
            var combined = faceRects[0]
            for rect in faceRects.dropFirst() {
                combined = combined.union(rect)
            }
            // 헤드룸: 얼굴 위쪽 50%, 아래쪽 100% (바디)
            let headroom = combined.height * 0.5
            let bodyRoom = combined.height * 1.0
            combined = CGRect(
                x: max(0, combined.minX - combined.width * 0.3),
                y: max(0, combined.minY - bodyRoom),
                width: min(1, combined.width * 1.6),
                height: min(1, combined.height + headroom + bodyRoom)
            )
            // 어텐션 영역과 병합 (가중치: 얼굴 70%, 어텐션 30%)
            if let att = attentionRect {
                subjectArea = CGRect(
                    x: combined.minX * 0.7 + att.minX * 0.3,
                    y: combined.minY * 0.7 + att.minY * 0.3,
                    width: combined.width * 0.7 + att.width * 0.3,
                    height: combined.height * 0.7 + att.height * 0.3
                )
            } else {
                subjectArea = combined
            }
        } else if let att = attentionRect {
            // 어텐션 영역만 사용 (패딩 추가)
            let padding: CGFloat = 0.1
            subjectArea = CGRect(
                x: max(0, att.minX - padding),
                y: max(0, att.minY - padding),
                width: min(1, att.width + padding * 2),
                height: min(1, att.height + padding * 2)
            )
        } else {
            // 감지 실패 시 중앙 80% 영역
            subjectArea = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        }

        // 4. 삼분할 법칙 적용 — 주요 피사체를 1/3 교차점에 배치
        let subjectCenter = CGPoint(x: subjectArea.midX, y: subjectArea.midY)
        let thirdPoint = nearestThirdPoint(to: subjectCenter)

        // 5. 크롭 영역 계산
        var cropWidth: CGFloat
        var cropHeight: CGFloat

        if let ratio = aspectRatio {
            // 비율 고정: 피사체를 포함하면서 비율 유지
            let imageAspect = imageWidth / imageHeight
            let normalizedRatio = ratio / imageAspect

            // 피사체를 포함할 최소 크기
            cropWidth = max(subjectArea.width * 1.2, 0.5)
            cropHeight = cropWidth / normalizedRatio

            if cropHeight < subjectArea.height * 1.2 {
                cropHeight = max(subjectArea.height * 1.2, 0.5)
                cropWidth = cropHeight * normalizedRatio
            }

            // 범위 제한
            cropWidth = min(cropWidth, 1.0)
            cropHeight = min(cropHeight, 1.0)

            // 비율 재조정
            if cropWidth / normalizedRatio > 1.0 {
                cropHeight = 1.0
                cropWidth = cropHeight * normalizedRatio
            }
            if cropHeight * normalizedRatio > 1.0 {
                cropWidth = 1.0
                cropHeight = cropWidth / normalizedRatio
            }
        } else {
            // 자유 비율: 피사체 영역 기반
            cropWidth = min(max(subjectArea.width * 1.3, 0.5), 1.0)
            cropHeight = min(max(subjectArea.height * 1.3, 0.5), 1.0)
        }

        // 삼분할 교차점에 피사체 배치하도록 오프셋 계산
        let offsetX = thirdPoint.x - subjectCenter.x
        let offsetY = thirdPoint.y - subjectCenter.y

        var cropX = subjectArea.midX - cropWidth / 2 + offsetX * 0.3
        var cropY = subjectArea.midY - cropHeight / 2 + offsetY * 0.3

        // 범위 클램핑
        cropX = max(0, min(cropX, 1.0 - cropWidth))
        cropY = max(0, min(cropY, 1.0 - cropHeight))

        let result = CGRect(x: cropX, y: cropY, width: cropWidth, height: cropHeight)
        AppLogger.log(.analysis, "SmartCrop: subject=\(String(format: "%.2f,%.2f", subjectArea.midX, subjectArea.midY)) crop=\(String(format: "%.2f,%.2f %.2fx%.2f", cropX, cropY, cropWidth, cropHeight)) faces=\(faceRects.count)")

        return result
    }

    // MARK: - 어텐션 히트맵 시각화

    /// 어텐션 히트맵을 CIImage로 반환 (오버레이 시각화용)
    static func attentionHeatmap(cgImage: CGImage) -> CIImage? {
        let request = VNGenerateAttentionBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        do {
            try handler.perform([request])
        } catch {
            AppLogger.log(.error, "Attention heatmap error: \(error)")
            return nil
        }

        guard let result = request.results?.first else { return nil }
        let pixelBuffer = result.pixelBuffer

        // 픽셀 버퍼 → CIImage
        var heatmap = CIImage(cvPixelBuffer: pixelBuffer)

        // 원본 이미지 크기에 맞게 스케일
        let scaleX = CGFloat(cgImage.width) / heatmap.extent.width
        let scaleY = CGFloat(cgImage.height) / heatmap.extent.height
        heatmap = heatmap.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        // 히트맵 컬러 적용 (파랑→빨강)
        guard let colorFilter = CIFilter(name: "CIFalseColor") else { return heatmap }
        colorFilter.setValue(heatmap, forKey: kCIInputImageKey)
        colorFilter.setValue(CIColor(red: 0, green: 0, blue: 1, alpha: 0), forKey: "inputColor0")  // 차가운 영역 (투명 파랑)
        colorFilter.setValue(CIColor(red: 1, green: 0, blue: 0, alpha: 0.6), forKey: "inputColor1")  // 뜨거운 영역 (반투명 빨강)

        return colorFilter.outputImage
    }

    // MARK: - 주요 피사체 중심 감지

    /// 어텐션 + 얼굴 감지 결합으로 주요 피사체 위치 반환
    static func detectSubjectCenter(cgImage: CGImage) -> CGPoint? {
        let faces = detectFaces(cgImage: cgImage)
        let attention = detectAttentionArea(cgImage: cgImage)

        if !faces.isEmpty {
            // 가장 큰 얼굴 중심 (70%) + 어텐션 중심 (30%)
            let largestFace = faces.max(by: { $0.width * $0.height < $1.width * $1.height })!
            let faceCenter = CGPoint(x: largestFace.midX, y: largestFace.midY)

            if let att = attention {
                let attCenter = CGPoint(x: att.midX, y: att.midY)
                return CGPoint(
                    x: faceCenter.x * 0.7 + attCenter.x * 0.3,
                    y: faceCenter.y * 0.7 + attCenter.y * 0.3
                )
            }
            return faceCenter
        }

        if let att = attention {
            return CGPoint(x: att.midX, y: att.midY)
        }

        return nil
    }

    // MARK: - Private Helpers

    /// VNGenerateAttentionBasedSaliencyImageRequest로 어텐션 영역 감지
    private static func detectAttentionArea(cgImage: CGImage) -> CGRect? {
        let request = VNGenerateAttentionBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        do {
            try handler.perform([request])
        } catch {
            AppLogger.log(.error, "Attention detection error: \(error)")
            return nil
        }

        guard let result = request.results?.first else { return nil }

        // 가장 현저한 객체의 바운딩 박스 (Vision 좌표: 좌하단 원점)
        guard let salientObjects = result.salientObjects, !salientObjects.isEmpty else {
            return nil
        }

        // 모든 현저 객체를 포함하는 영역
        var combined = salientObjects[0].boundingBox
        for obj in salientObjects.dropFirst() {
            combined = combined.union(obj.boundingBox)
        }

        // Vision 좌표 → 상단 원점 좌표로 변환
        return CGRect(
            x: combined.origin.x,
            y: 1.0 - combined.origin.y - combined.height,
            width: combined.width,
            height: combined.height
        )
    }

    /// VNDetectFaceRectanglesRequest로 얼굴 영역 감지
    private static func detectFaces(cgImage: CGImage) -> [CGRect] {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        do {
            try handler.perform([request])
        } catch {
            return []
        }

        guard let results = request.results else { return [] }

        // Vision 좌표 → 상단 원점 좌표로 변환
        return results.compactMap { face -> CGRect? in
            guard face.confidence > 0.5 else { return nil }
            let box = face.boundingBox
            return CGRect(
                x: box.origin.x,
                y: 1.0 - box.origin.y - box.height,
                width: box.width,
                height: box.height
            )
        }
    }

    /// 주어진 점에 가장 가까운 삼분할 교차점 반환
    private static func nearestThirdPoint(to point: CGPoint) -> CGPoint {
        let thirds: [CGPoint] = [
            CGPoint(x: 1.0/3.0, y: 1.0/3.0),
            CGPoint(x: 2.0/3.0, y: 1.0/3.0),
            CGPoint(x: 1.0/3.0, y: 2.0/3.0),
            CGPoint(x: 2.0/3.0, y: 2.0/3.0),
        ]

        var nearest = thirds[0]
        var minDist = CGFloat.greatestFiniteMagnitude

        for tp in thirds {
            let dx = point.x - tp.x
            let dy = point.y - tp.y
            let dist = dx * dx + dy * dy
            if dist < minDist {
                minDist = dist
                nearest = tp
            }
        }

        return nearest
    }
}
