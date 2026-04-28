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
}

// MARK: - LIBRAW_SUCCESS 상수 호환 (libraw.h 의 #define 0 대응)
//   libraw.h 가 enum 이 아니라 #define 으로 LIBRAW_SUCCESS = 0 을 정의하기 때문에
//   Swift 에서 직접 비교하려면 매크로 import 필요. 안전하게 우리 쪽에서 0 으로 정의.
private struct LIBRAW_SUCCESS { static let rawValue: Int32 = 0 }
private let LIBRAW_THUMBNAIL_JPEG: Int32 = 2
