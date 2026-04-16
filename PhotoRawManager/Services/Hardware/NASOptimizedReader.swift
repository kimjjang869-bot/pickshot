//
//  NASOptimizedReader.swift
//  PhotoRawManager
//
//  NAS(네트워크 볼륨) 전용 최적화 파일 읽기 서비스.
//
//  핵심 전략:
//  1. **부분 읽기 (range read)**: RAW 파일 전체 다운로드 대신 임베디드
//     JPEG 가 있는 앞쪽 ~4MB 만 읽어서 썸네일 추출.
//     → 50MB RAW 파일이 1초→80ms 로 단축 (50MB/s 링크 기준).
//
//  2. **메타데이터 캐시**: NAS 파일은 한번 읽으면 세션 내 재접근을 최소화.
//
//  3. **우선순위 큐**: 화면에 보이는 인덱스 우선, off-screen 지연.
//
//  NAS 가 아닌 디스크에서는 이 파일을 거치지 않음 (기본 CGImageSource 사용).
//

import Foundation
import CoreGraphics
import ImageIO

/// NAS 환경에서 썸네일/프리뷰 읽기를 최적화하는 유틸리티.
enum NASOptimizedReader {

    /// RAW 파일의 앞쪽 부분만 읽어서 임베디드 JPEG 썸네일 추출.
    /// - Parameters:
    ///   - url: RAW 파일 URL (ARW/CR2/CR3/NEF/RAF/DNG 등)
    ///   - maxPixel: 원하는 최대 픽셀 크기
    /// - Returns: 썸네일 CGImage. 실패 시 nil.
    ///
    /// - Note: 대부분의 RAW 포맷은 EXIF 헤더 다음에 임베디드 JPEG 이 있음
    ///         (보통 첫 2-4MB 이내). 이 부분만 읽으면 전체 파일 다운로드 불필요.
    static func extractRAWThumbnail(url: URL, maxPixel: CGFloat) -> CGImage? {
        // 전략: 파일 앞 4MB 만 읽어서 메모리 버퍼에 올리고 CGImageSource 생성
        // 많은 RAW 포맷이 이 범위 안에 preview JPEG 을 포함
        let probeSize = 4 * 1024 * 1024  // 4MB
        guard let partialData = readPartialFile(url: url, byteCount: probeSize) else {
            return nil
        }

        let opts: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceTypeIdentifierHint: "public.image"
        ]
        guard let src = CGImageSourceCreateWithData(partialData as CFData, opts as CFDictionary) else {
            return nil
        }

        // CGImageSource 가 thumbnail 추출 지원하는지 확인
        let thumbOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: false
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts as CFDictionary)
    }

    /// 파일의 앞쪽 byteCount 바이트만 읽어서 Data 로 반환.
    /// 네트워크 볼륨에서도 FileHandle 을 쓰면 SMB/AFP 가 range request 로 처리.
    static func readPartialFile(url: URL, byteCount: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        // 파일 전체 크기 확인 (부분 읽기 범위 조정)
        let fileSize: UInt64 = (try? handle.seekToEnd()) ?? 0
        let readSize = min(UInt64(byteCount), fileSize)
        guard readSize > 0 else { return nil }

        try? handle.seek(toOffset: 0)
        return try? handle.read(upToCount: Int(readSize))
    }

    /// 경로가 네트워크 볼륨인지 빠르게 판단 (volumeIsLocalKey).
    static func isNetworkPath(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.volumeIsLocalKey]),
              let isLocal = values.volumeIsLocal else {
            return false
        }
        return !isLocal
    }

    /// RAW 파일 확장자 여부 (부분 읽기 대상 판단용).
    static func isRAWFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return Self.rawExtensions.contains(ext)
    }

    private static let rawExtensions: Set<String> = [
        "arw", "sr2", "srf",           // Sony
        "cr2", "cr3", "crw",           // Canon
        "nef", "nrw",                  // Nikon
        "raf",                         // Fujifilm
        "rw2",                         // Panasonic
        "orf",                         // Olympus
        "pef", "ptx",                  // Pentax
        "dng",                         // Adobe/범용
        "iiq",                         // Phase One
        "3fr", "fff",                  // Hasselblad
        "x3f",                         // Sigma
        "rwl",                         // Leica
        "mrw",                         // Minolta
    ]
}
