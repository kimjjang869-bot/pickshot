import Foundation
import CoreImage
import AppKit
import UniformTypeIdentifiers

// MARK: - LUT 서비스
// .cube 파일 파싱 + CIColorCubeWithColorSpace 데이터 생성
// GPU 가속 실시간 LUT 적용 지원

struct LUTService {

    // MARK: - LUT 데이터

    struct LUTData {
        let dimension: Int
        let data: Data      // Float32 RGBA 큐브 데이터
        let name: String
        let url: URL
    }

    // MARK: - .cube 파일 파싱

    /// .cube LUT 파일을 파싱하여 CIColorCube용 데이터 반환
    static func parseCubeFile(url: URL) -> LUTData? {
        // 보안: 파일 크기 제한 (100MB 이상은 악의적 파일로 간주)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int, size > 100_000_000 {
            plog("[LUT] 파일 크기 초과: \(size) bytes (최대 100MB)\n")
            return nil
        }
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lines = content.components(separatedBy: .newlines)

        var dimension = 0
        var name = url.deletingPathExtension().lastPathComponent
        var rgbValues: [(Float, Float, Float)] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            if trimmed.hasPrefix("TITLE") {
                // TITLE "LUT Name"
                let parts = trimmed.replacingOccurrences(of: "TITLE", with: "")
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                if !parts.isEmpty { name = parts }
                continue
            }

            if trimmed.hasPrefix("LUT_3D_SIZE") {
                let parts = trimmed.components(separatedBy: .whitespaces)
                if let last = parts.last, let dim = Int(last) {
                    dimension = dim
                }
                continue
            }

            // DOMAIN_MIN / DOMAIN_MAX 무시 (0~1 가정)
            if trimmed.hasPrefix("DOMAIN_") { continue }
            if trimmed.hasPrefix("LUT_") { continue }

            // RGB 값 파싱
            let parts = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            if parts.count >= 3,
               let r = Float(parts[0]),
               let g = Float(parts[1]),
               let b = Float(parts[2]) {
                rgbValues.append((r, g, b))
            }
        }

        guard dimension > 0, dimension <= 128 else {
            plog("[LUT] 유효하지 않은 dimension: \(dimension) (최대 128)\n")
            return nil
        }
        let expectedCount = dimension * dimension * dimension
        guard rgbValues.count == expectedCount else {
            plog("[LUT] 데이터 수 불일치: 예상 \(expectedCount), 실제 \(rgbValues.count)\n")
            return nil
        }

        // Float32 RGBA 데이터 생성 (CIColorCube 요구 포맷)
        var floatData = [Float]()
        floatData.reserveCapacity(expectedCount * 4)
        for (r, g, b) in rgbValues {
            floatData.append(r)
            floatData.append(g)
            floatData.append(b)
            floatData.append(1.0)  // Alpha
        }

        let data = Data(bytes: floatData, count: floatData.count * MemoryLayout<Float>.size)
        return LUTData(dimension: dimension, data: data, name: name, url: url)
    }

    // MARK: - .3dl 파일 파싱

    /// .3dl LUT 파일 파싱 (Lustre/Flame 포맷)
    static func parse3dlFile(url: URL) -> LUTData? {
        // 보안: 파일 크기 제한
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int, size > 100_000_000 {
            plog("[LUT] 파일 크기 초과: \(size) bytes (최대 100MB)\n")
            return nil
        }
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lines = content.components(separatedBy: .newlines)
        let name = url.deletingPathExtension().lastPathComponent

        var rgbValues: [(Float, Float, Float)] = []
        var maxValue: Float = 1023  // 10-bit 기본값

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            let parts = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }

            // 첫 줄에 쉐이퍼 테이블이 있을 수 있음 (무시)
            if parts.count >= 3,
               let r = Float(parts[0]),
               let g = Float(parts[1]),
               let b = Float(parts[2]) {
                // 값이 1보다 크면 정수 LUT (0~1023 또는 0~4095)
                if r > 1 || g > 1 || b > 1 {
                    maxValue = max(maxValue, max(r, max(g, b)))
                }
                rgbValues.append((r, g, b))
            }
        }

        guard !rgbValues.isEmpty else { return nil }

        // 3D LUT 크기 역추출 (n^3 = count)
        let cubeRoot = Int(round(pow(Double(rgbValues.count), 1.0 / 3.0)))
        guard cubeRoot * cubeRoot * cubeRoot == rgbValues.count else { return nil }

        // 정규화 (0~1 범위로)
        let normalize = maxValue > 1
        var floatData = [Float]()
        floatData.reserveCapacity(rgbValues.count * 4)
        for (r, g, b) in rgbValues {
            floatData.append(normalize ? r / maxValue : r)
            floatData.append(normalize ? g / maxValue : g)
            floatData.append(normalize ? b / maxValue : b)
            floatData.append(1.0)
        }

        let data = Data(bytes: floatData, count: floatData.count * MemoryLayout<Float>.size)
        return LUTData(dimension: cubeRoot, data: data, name: name, url: url)
    }

    // MARK: - 자동 포맷 감지 파싱

    /// .cube 또는 .3dl 자동 감지
    static func parseLUT(url: URL) -> LUTData? {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "cube": return parseCubeFile(url: url)
        case "3dl": return parse3dlFile(url: url)
        default:
            // 확장자가 없으면 .cube로 시도
            return parseCubeFile(url: url)
        }
    }

    // MARK: - LUT 파일 선택 다이얼로그

    /// 파일 선택 다이얼로그로 LUT 파일 로드
    static func openLUTFile() -> LUTData? {
        let panel = NSOpenPanel()
        panel.title = "LUT 파일 선택"
        panel.allowedContentTypes = [
            UTType(filenameExtension: "cube"),
            UTType(filenameExtension: "3dl")
        ].compactMap { $0 }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return parseLUT(url: url)
    }

    // MARK: - CIImage에 LUT 적용 (스틸 이미지용)

    /// 단일 이미지에 LUT 적용
    static func applyLUT(_ lut: LUTData, to image: CIImage) -> CIImage? {
        let filter = CIFilter(name: "CIColorCubeWithColorSpace")
        filter?.setValue(lut.dimension, forKey: "inputCubeDimension")
        filter?.setValue(lut.data, forKey: "inputCubeData")
        filter?.setValue(CGColorSpace(name: CGColorSpace.sRGB), forKey: "inputColorSpace")
        filter?.setValue(image, forKey: kCIInputImageKey)
        return filter?.outputImage
    }
}
