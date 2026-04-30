//
//  LibRawDecoder.swift
//  PhotoRawManager
//
//  v8.9.4: LibRaw Phase 1 — orientation/임베디드 thumb 폴백.
//  Apple ImageIO 가 모르는 Canon CR3 MakerNote / Nikon Z9 HE 등에 사용.
//
//  라이선스: LibRaw 는 LGPL 2.1 / CDDL 1.0 듀얼. 동적 링크(libraw.dylib) 사용으로
//  사용자가 dylib 교체 가능 — LGPL 의무 면제.
//

import Foundation
import AppKit

final class LibRawDecoder {
    private let proc: UnsafeMutablePointer<libraw_data_t>

    /// init 실패 시 nil 반환. 파일 열기까지 성공한 경우만 인스턴스 생성.
    init?(url: URL) {
        guard let p = libraw_init(0) else { return nil }
        let openResult = url.path.withCString { libraw_open_file(p, $0) }
        guard openResult == LIBRAW_SUCCESS.rawValue else {
            libraw_close(p)
            return nil
        }
        self.proc = p
    }

    deinit { libraw_close(proc) }

    // MARK: - Orientation / dimensions

    /// LibRaw 의 `flip` 값을 EXIF orientation 으로 변환.
    ///   flip 0 → EXIF 1 (회전 없음)
    ///   flip 3 → EXIF 3 (180°)
    ///   flip 5 → EXIF 8 (90° CCW)
    ///   flip 6 → EXIF 6 (90° CW)
    var exifOrientation: Int {
        let f = Int(proc.pointee.sizes.flip)
        switch f {
        case 0: return 1
        case 3: return 3
        case 5: return 8
        case 6: return 6
        default: return 1
        }
    }

    /// 표시 dimension (orientation 적용 전 원본 픽셀)
    var sensorSize: (width: Int, height: Int) {
        let s = proc.pointee.sizes
        return (Int(s.iwidth), Int(s.iheight))
    }

    /// 디스플레이 dimension (orientation 적용 후 — H/W 가 swap 될 수 있음)
    var displaySize: (width: Int, height: Int) {
        let (w, h) = sensorSize
        let f = Int(proc.pointee.sizes.flip)
        // flip 5/6 = 90° rotation → W/H swap
        if f == 5 || f == 6 { return (h, w) }
        return (w, h)
    }

    // MARK: - Embedded thumbnail extraction

    /// 임베디드 JPEG/PPM 추출. 가장 빠른 RAW preview 경로.
    /// returns: NSImage (Apple 디코드)
    func extractEmbeddedThumb() -> NSImage? {
        guard libraw_unpack_thumb(proc) == LIBRAW_SUCCESS.rawValue else { return nil }
        let thumb = proc.pointee.thumbnail
        guard let buf = thumb.thumb, thumb.tlength > 0 else { return nil }
        let data = Data(bytes: buf, count: Int(thumb.tlength))

        // tformat: LIBRAW_THUMBNAIL_JPEG=2, BITMAP=1
        if thumb.tformat.rawValue == LIBRAW_THUMBNAIL_JPEG {
            return NSImage(data: data)
        }
        // PPM/RAW bitmap — Apple 이 못 읽으므로 nil. (대부분 카메라는 JPEG 임베디드)
        return nil
    }

    /// 임베디드 thumb 의 raw bytes (캐시 저장용). format 정보 포함.
    func extractEmbeddedRaw() -> (data: Data, isJPEG: Bool)? {
        guard libraw_unpack_thumb(proc) == LIBRAW_SUCCESS.rawValue else { return nil }
        let thumb = proc.pointee.thumbnail
        guard let buf = thumb.thumb, thumb.tlength > 0 else { return nil }
        let data = Data(bytes: buf, count: Int(thumb.tlength))
        return (data, thumb.tformat.rawValue == LIBRAW_THUMBNAIL_JPEG)
    }

    // MARK: - v9.1: Full RAW Demosaic (LibRaw → CGImage)

    /// LibRaw 옵션 prepass — Apple ImageIO 보다 빠른 RAW 디코드 위함.
    /// 기본 설정: half-size = 1 (빠른 미리보기 / fit 모드용), use_camera_wb = 1.
    /// fullSize = true 면 풀해상도 (느리나 100% 줌용).
    enum DemosaicQuality: Int32 {
        case fastHalf = 0       // half-size (1/2 해상도, 가장 빠름 — 100~150ms 풀프레임)
        case linear = 1         // bilinear (빠른 demosaic)
        case ahd = 3            // AHD (기본, 균형)
        case dcb = 4            // DCB (고품질)
        case amaze = 11         // AMaZE (RawTherapee 사용 — 최고 품질 but 느림)
    }

    /// 풀 RAW demosaic + CGImage 반환.
    /// - useHalfSize: true 면 half-size (1/2 해상도, 4× 빠름) — fit 모드용 권장.
    /// - quality: false 시 어차피 무시. true 면 품질 설정.
    func demosaicToCGImage(useHalfSize: Bool = true, quality: DemosaicQuality = .ahd, useCameraWB: Bool = true) -> CGImage? {
        // 옵션 셋업 (.params 직접 수정).
        proc.pointee.params.half_size = useHalfSize ? 1 : 0
        proc.pointee.params.use_camera_wb = useCameraWB ? 1 : 0
        proc.pointee.params.user_qual = quality.rawValue
        proc.pointee.params.no_auto_bright = 0
        proc.pointee.params.output_color = 1   // sRGB
        proc.pointee.params.output_bps = 8
        proc.pointee.params.gamm.0 = 1.0 / 2.4  // sRGB gamma curve
        proc.pointee.params.gamm.1 = 12.92

        guard libraw_unpack(proc) == LIBRAW_SUCCESS.rawValue else { return nil }
        guard libraw_dcraw_process(proc) == LIBRAW_SUCCESS.rawValue else { return nil }

        var status: Int32 = 0
        guard let memImg = libraw_dcraw_make_mem_image(proc, &status),
              status == LIBRAW_SUCCESS.rawValue else { return nil }
        defer { libraw_dcraw_clear_mem(memImg) }

        let img = memImg.pointee
        let width = Int(img.width)
        let height = Int(img.height)
        let bits = Int(img.bits)
        let colors = Int(img.colors)
        let bytesPerRow = width * colors * (bits / 8)
        let dataSize = Int(img.data_size)

        // libraw_processed_image_t 의 data 는 flexible array — pointer 위치 직접 계산.
        let basePtr = withUnsafePointer(to: &memImg.pointee.data) { UnsafeRawPointer($0) }
        let pixelPtr = basePtr.advanced(by: 0)

        // CGImage 생성 (sRGB / 8-bit / 3-channel)
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: NSData(bytes: pixelPtr, length: dataSize)) else {
            return nil
        }
        return CGImage(
            width: width, height: height,
            bitsPerComponent: bits, bitsPerPixel: bits * colors,
            bytesPerRow: bytesPerRow,
            space: cs,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent
        )
    }
}

// MARK: - LIBRAW_SUCCESS 상수 호환 (libraw.h 의 #define 0 대응)
//   libraw.h 가 enum 이 아니라 #define 으로 LIBRAW_SUCCESS = 0 을 정의하기 때문에
//   Swift 에서 직접 비교하려면 매크로 import 필요. 안전하게 우리 쪽에서 0 으로 정의.
private struct LIBRAW_SUCCESS { static let rawValue: Int32 = 0 }
private let LIBRAW_THUMBNAIL_JPEG: Int32 = 2
