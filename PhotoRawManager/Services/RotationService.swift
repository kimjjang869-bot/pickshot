//
//  RotationService.swift
//  PhotoRawManager
//
//  v8.6.2: 일괄 회전 — JPG는 lossless EXIF 재기록, RAW는 XMP 사이드카 기록.
//  철학: "원본 RAW 바이너리는 건드리지 않는다. 메타데이터/사이드카만 수정."
//
//  - JPG/JPEG: kCGImagePropertyOrientation 재기록 (CGImageDestination 무손실 경로)
//  - ARW/NEF/CR2/DNG/… : `<filename>.xmp` 사이드카에 tiff:Orientation 기록.
//    Adobe Lightroom / Capture One / Bridge 모두 인식.
//  - 앱 내부 표시: PhotoStore.rotationOverrideCW 맵으로 delta 관리 → 로드 시 rotate.
//

import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

enum RotationService {

    /// 90° CW 회전을 EXIF Orientation 값에 합성
    /// Orientation 매핑 (시계방향 90도):  1→6, 2→5, 3→8, 4→7, 5→4, 6→3, 7→2, 8→1
    private static let cwMap90: [Int: Int] = [1:6, 2:5, 3:8, 4:7, 5:4, 6:3, 7:2, 8:1]

    /// EXIF Orientation 값을 CW 각도만큼 회전해서 새 값 반환
    static func composeOrientation(base: Int, degreesCW: Int) -> Int {
        var v = base.clamped(1, 8)
        var remaining = ((degreesCW % 360) + 360) % 360
        while remaining >= 90 {
            v = cwMap90[v] ?? v
            remaining -= 90
        }
        return v
    }

    /// 파일의 현재 EXIF Orientation 읽기 (없으면 1)
    static func readOrientation(url: URL) -> Int {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return 1 }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        return (props?[kCGImagePropertyOrientation] as? Int) ?? 1
    }

    /// 파일 1개 회전. 성공 시 (newOrientation, 사용된 방식) 반환.
    /// - Parameters:
    ///   - url: 대상 파일 (JPG or RAW)
    ///   - degreesCW: 90, 180, 270 중 하나
    /// - Returns: 성공 여부
    @discardableResult
    static func rotate(url: URL, degreesCW: Int) -> Bool {
        guard [90, 180, 270].contains(degreesCW) else { return false }
        let ext = url.pathExtension.lowercased()
        let isJPG = (ext == "jpg" || ext == "jpeg")
        if isJPG {
            return rotateJPGLossless(url: url, degreesCW: degreesCW)
        } else {
            // RAW 또는 기타: XMP 사이드카로만 기록 (원본 바이너리 불변)
            return rotateViaXMPSidecar(for: url, degreesCW: degreesCW)
        }
    }

    // MARK: - JPG lossless

    private static func rotateJPGLossless(url: URL, degreesCW: Int) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        guard let uti = CGImageSourceGetType(src) else { return false }
        let currentOri = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])?[kCGImagePropertyOrientation] as? Int ?? 1
        let newOri = composeOrientation(base: currentOri, degreesCW: degreesCW)

        let tempURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).rot.tmp")
        guard let dest = CGImageDestinationCreateWithURL(tempURL as CFURL, uti, CGImageSourceGetCount(src), nil) else { return false }

        let count = CGImageSourceGetCount(src)
        for i in 0..<count {
            if i == 0 {
                var props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
                props[kCGImagePropertyOrientation] = newOri
                if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                    tiff[kCGImagePropertyTIFFOrientation] = newOri
                    props[kCGImagePropertyTIFFDictionary] = tiff
                }
                CGImageDestinationAddImageFromSource(dest, src, 0, props as CFDictionary)
            } else {
                CGImageDestinationAddImageFromSource(dest, src, i, nil)
            }
        }
        guard CGImageDestinationFinalize(dest) else {
            try? FileManager.default.removeItem(at: tempURL)
            return false
        }
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
            return true
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            return false
        }
    }

    // MARK: - RAW XMP sidecar

    private static func sidecarURL(for url: URL) -> URL {
        // "IMG_1234.ARW" → "IMG_1234.xmp" (확장자 교체가 Adobe 표준)
        return url.deletingPathExtension().appendingPathExtension("xmp")
    }

    /// XMP 사이드카에 tiff:Orientation 기록. 기존 XMP 있으면 Orientation 만 교체.
    private static func rotateViaXMPSidecar(for url: URL, degreesCW: Int) -> Bool {
        // 원본 EXIF Orientation + 추가 회전 = 합성된 절대 값
        let baseOri = readOrientation(url: url)
        let composed = composeOrientation(base: baseOri, degreesCW: degreesCW)
        let sidecar = sidecarURL(for: url)

        if FileManager.default.fileExists(atPath: sidecar.path),
           let existing = try? String(contentsOf: sidecar, encoding: .utf8) {
            let updated = replaceOrInsertOrientation(xmp: existing, newValue: composed)
            do {
                try updated.write(to: sidecar, atomically: true, encoding: .utf8)
                return true
            } catch {
                return false
            }
        } else {
            let xmp = newXMPWithOrientation(composed)
            do {
                try xmp.write(to: sidecar, atomically: true, encoding: .utf8)
                return true
            } catch {
                return false
            }
        }
    }

    private static func newXMPWithOrientation(_ ori: Int) -> String {
        return """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="PickShot">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about=""
              xmlns:tiff="http://ns.adobe.com/tiff/1.0/"
              xmlns:exif="http://ns.adobe.com/exif/1.0/">
              <tiff:Orientation>\(ori)</tiff:Orientation>
              <exif:Orientation>\(ori)</exif:Orientation>
            </rdf:Description>
          </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
    }

    /// XMP 문자열에서 tiff:Orientation / exif:Orientation 값을 교체. 없으면 삽입.
    private static func replaceOrInsertOrientation(xmp: String, newValue: Int) -> String {
        var result = xmp
        for tag in ["tiff:Orientation", "exif:Orientation"] {
            // <tag>...</tag> 형식
            let pattern1 = "<\(tag)>[^<]*</\(tag)>"
            if let range = result.range(of: pattern1, options: .regularExpression) {
                result.replaceSubrange(range, with: "<\(tag)>\(newValue)</\(tag)>")
                continue
            }
            // tag="value" 속성 형식
            let pattern2 = "\(tag)=\"[^\"]*\""
            if let range = result.range(of: pattern2, options: .regularExpression) {
                result.replaceSubrange(range, with: "\(tag)=\"\(newValue)\"")
                continue
            }
            // 둘 다 없음 → rdf:Description 닫기 전에 삽입
            if let insertRange = result.range(of: "</rdf:Description>") {
                let insertion = "<\(tag)>\(newValue)</\(tag)>\n"
                result.insert(contentsOf: insertion, at: insertRange.lowerBound)
            }
        }
        return result
    }

    /// 사이드카에서 tiff:Orientation 읽기 (없으면 nil)
    static func readSidecarOrientation(for url: URL) -> Int? {
        let sidecar = sidecarURL(for: url)
        guard FileManager.default.fileExists(atPath: sidecar.path),
              let text = try? String(contentsOf: sidecar, encoding: .utf8) else { return nil }
        // tiff:Orientation 먼저 시도, 실패 시 exif:Orientation
        for tag in ["tiff:Orientation", "exif:Orientation"] {
            if let range = text.range(of: "<\(tag)>(\\d+)</\(tag)>", options: .regularExpression) {
                let matched = String(text[range])
                let digits = matched.compactMap { $0.isNumber ? $0 : nil }
                if let v = Int(String(digits)) { return v }
            }
            if let range = text.range(of: "\(tag)=\"(\\d+)\"", options: .regularExpression) {
                let matched = String(text[range])
                let digits = matched.compactMap { $0.isNumber ? $0 : nil }
                if let v = Int(String(digits)) { return v }
            }
        }
        return nil
    }

    // MARK: - 앱 내부 표시용: NSImage 를 주어진 각도만큼 CW 회전

    static func rotateImage(_ src: NSImage, degreesCW: Int) -> NSImage {
        let degrees = ((degreesCW % 360) + 360) % 360
        guard degrees != 0 else { return src }
        guard let cg = src.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return src }
        let w = cg.width
        let h = cg.height
        let swap = (degrees == 90 || degrees == 270)
        let outW = swap ? h : w
        let outH = swap ? w : h

        guard let ctx = CGContext(
            data: nil, width: outW, height: outH,
            bitsPerComponent: cg.bitsPerComponent,
            bytesPerRow: 0,
            space: cg.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: cg.bitmapInfo.rawValue
        ) else { return src }

        ctx.translateBy(x: CGFloat(outW)/2, y: CGFloat(outH)/2)
        ctx.rotate(by: -CGFloat(degrees) * .pi / 180.0)  // CGContext는 반시계 기준 → CW는 음수
        ctx.translateBy(x: -CGFloat(w)/2, y: -CGFloat(h)/2)
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else { return src }
        return NSImage(cgImage: out, size: NSSize(width: outW, height: outH))
    }
}

private extension Int {
    func clamped(_ lo: Int, _ hi: Int) -> Int {
        return Swift.max(lo, Swift.min(hi, self))
    }
}
