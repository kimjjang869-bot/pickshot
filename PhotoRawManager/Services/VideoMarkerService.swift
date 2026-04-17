//
//  VideoMarkerService.swift
//  PhotoRawManager
//
//  영상 IN/OUT 마커를 XMP 사이드카에 저장/로드.
//  Adobe XMP Dynamic Media 표준 스키마 사용 → Premiere Pro / DaVinci Resolve / Final Cut 호환.
//
//  파일 구조:
//    MVI_0042.MOV          ← 영상 원본 (수정하지 않음)
//    MVI_0042.MOV.xmp      ← 마커 메타데이터 (사이드카)
//

import Foundation
import AVFoundation

struct VideoMarkers: Equatable {
    /// 초 단위 In 포인트. nil 이면 미설정.
    var inSeconds: Double?
    /// 초 단위 Out 포인트. nil 이면 미설정.
    var outSeconds: Double?

    var isEmpty: Bool { inSeconds == nil && outSeconds == nil }
    var hasRange: Bool { inSeconds != nil && outSeconds != nil }

    /// 유효성: in < out 이어야 함
    var isValid: Bool {
        guard let i = inSeconds, let o = outSeconds else { return true }
        return i < o
    }

    /// 구간 길이 (초). IN/OUT 모두 있을 때만.
    var duration: Double? {
        guard let i = inSeconds, let o = outSeconds, o > i else { return nil }
        return o - i
    }
}

final class VideoMarkerService {
    static let shared = VideoMarkerService()
    private init() {}

    // 인메모리 캐시 — 썸네일 그리드에서 수천 개 영상 XMP 를 매번 읽지 않도록
    private var cache: [URL: VideoMarkers] = [:]
    private let cacheLock = NSLock()

    /// 영상 URL 에 대한 XMP 사이드카 경로. (예: "MVI_0042.MOV" → "MVI_0042.MOV.xmp")
    func sidecarURL(for videoURL: URL) -> URL {
        videoURL.appendingPathExtension("xmp")
    }

    /// 영상 파일의 마커 읽기 (XMP 없으면 빈 VideoMarkers 반환).
    /// - 캐시 우선, 미스 시 디스크에서 파싱.
    func markers(for videoURL: URL) -> VideoMarkers {
        cacheLock.lock()
        if let cached = cache[videoURL] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let markers = loadFromDisk(videoURL: videoURL)
        cacheLock.lock()
        cache[videoURL] = markers
        cacheLock.unlock()
        return markers
    }

    /// 마커 저장 + 캐시 갱신. 둘 다 nil 이면 XMP 파일 삭제.
    func save(_ markers: VideoMarkers, for videoURL: URL) {
        cacheLock.lock()
        cache[videoURL] = markers
        cacheLock.unlock()

        let xmpURL = sidecarURL(for: videoURL)
        if markers.isEmpty {
            // 마커 모두 없으면 XMP 파일 삭제 (지저분한 빈 파일 방지)
            try? FileManager.default.removeItem(at: xmpURL)
            return
        }

        // 기존 XMP 가 있으면 읽어서 markers 필드만 교체 (Rating 등 다른 필드 보존)
        let existingXMP = (try? String(contentsOf: xmpURL, encoding: .utf8)) ?? ""
        let newXMP = rewriteXMP(existing: existingXMP, markers: markers)
        try? newXMP.write(to: xmpURL, atomically: true, encoding: .utf8)
    }

    /// 특정 URL 캐시 무효화 (외부에서 XMP 가 바뀌었을 때)
    func invalidate(_ videoURL: URL) {
        cacheLock.lock()
        cache.removeValue(forKey: videoURL)
        cacheLock.unlock()
    }

    /// 전체 캐시 비움 (폴더 전환 시 호출)
    func clearCache() {
        cacheLock.lock()
        cache.removeAll(keepingCapacity: false)
        cacheLock.unlock()
    }

    // MARK: - XMP 파싱/쓰기

    private func loadFromDisk(videoURL: URL) -> VideoMarkers {
        let xmpURL = sidecarURL(for: videoURL)
        guard let data = try? Data(contentsOf: xmpURL),
              let text = String(data: data, encoding: .utf8) else {
            return VideoMarkers()
        }
        return parseXMP(text)
    }

    /// XMP 텍스트에서 In/Out 마커 추출.
    /// xmpDM:markers > rdf:Seq > rdf:li > xmpDM:name + xmpDM:startTime
    /// startTime 형식: Adobe 는 보통 "frames" 또는 "samples" 기반 정수 (내부 타임스케일 필요)
    /// 호환성을 위해 커스텀 필드 `pickshot:inSeconds`/`outSeconds` 도 같이 저장/읽기.
    func parseXMP(_ text: String) -> VideoMarkers {
        var markers = VideoMarkers()

        // 우선 커스텀 필드(초 단위 실수) — PickShot 이 쓴 경우
        if let inSec = regex(text, pattern: #"pickshot:inSeconds\s*=\s*"([\d.]+)""#) ??
                       regex(text, pattern: #"<pickshot:inSeconds>([\d.]+)</pickshot:inSeconds>"#) {
            markers.inSeconds = Double(inSec)
        }
        if let outSec = regex(text, pattern: #"pickshot:outSeconds\s*=\s*"([\d.]+)""#) ??
                        regex(text, pattern: #"<pickshot:outSeconds>([\d.]+)</pickshot:outSeconds>"#) {
            markers.outSeconds = Double(outSec)
        }

        // 폴백: Adobe 표준 xmpDM:markers (다른 편집 툴에서 쓴 경우)
        // 30fps 가정 폴백 (편집툴이 저장한 걸 읽기만 하고, PickShot 은 항상 pickshot: 필드에 함께 쓴다).
        if markers.inSeconds == nil || markers.outSeconds == nil,
           let blockRange = text.range(of: #"<xmpDM:markers[\s\S]*?</xmpDM:markers>"#, options: .regularExpression) {
            let block = String(text[blockRange])
            if let re = try? NSRegularExpression(pattern: #"<rdf:li[\s\S]*?</rdf:li>"#) {
                let ns = block as NSString
                let matches = re.matches(in: block, range: NSRange(location: 0, length: ns.length))
                for m in matches {
                    let liText = ns.substring(with: m.range)
                    let name = regex(liText, pattern: #"<xmpDM:name>(\w+)</xmpDM:name>"#) ?? ""
                    if let s = regex(liText, pattern: #"<xmpDM:startTime>(\d+)</xmpDM:startTime>"#),
                       let frames = Double(s) {
                        let seconds = frames / 30.0
                        if name.lowercased() == "in", markers.inSeconds == nil {
                            markers.inSeconds = seconds
                        } else if name.lowercased() == "out", markers.outSeconds == nil {
                            markers.outSeconds = seconds
                        }
                    }
                }
            }
        }

        return markers
    }

    /// 기존 XMP 가 있으면 marker 영역만 교체, 없으면 새 XMP 생성.
    private func rewriteXMP(existing: String, markers: VideoMarkers) -> String {
        // 마커 XML 블록 생성 (커스텀 필드 + Adobe 표준 둘 다)
        let markerBlock = buildMarkerBlock(markers: markers)

        if existing.isEmpty {
            return buildFullXMP(markerBlock: markerBlock)
        }

        // 기존 XMP 에 pickshot 마커 블록이 있으면 교체
        var result = existing
        let rangePatterns = [
            #"<!--\s*pickshot:markers\s*-->[\s\S]*?<!--\s*/pickshot:markers\s*-->"#,
        ]
        for pattern in rangePatterns {
            if let range = result.range(of: pattern, options: .regularExpression) {
                result.replaceSubrange(range, with: markerBlock)
                return result
            }
        }
        // 없으면 </rdf:Description> 앞에 삽입
        if let closing = result.range(of: "</rdf:Description>") {
            result.insert(contentsOf: markerBlock + "\n  ", at: closing.lowerBound)
            return result
        }
        // 최악의 경우 — 완전 새로 작성
        return buildFullXMP(markerBlock: markerBlock)
    }

    private func buildMarkerBlock(markers: VideoMarkers) -> String {
        var s = "<!-- pickshot:markers -->\n"
        if let i = markers.inSeconds {
            s += "    <pickshot:inSeconds>\(String(format: "%.3f", i))</pickshot:inSeconds>\n"
        }
        if let o = markers.outSeconds {
            s += "    <pickshot:outSeconds>\(String(format: "%.3f", o))</pickshot:outSeconds>\n"
        }
        // Adobe 표준 xmpDM:markers (편집 툴 호환용, 30fps 기준 frame 변환)
        if markers.inSeconds != nil || markers.outSeconds != nil {
            s += "    <xmpDM:markers>\n"
            s += "      <rdf:Seq>\n"
            if let i = markers.inSeconds {
                s += "        <rdf:li rdf:parseType=\"Resource\"><xmpDM:name>In</xmpDM:name><xmpDM:startTime>\(Int(i * 30))</xmpDM:startTime></rdf:li>\n"
            }
            if let o = markers.outSeconds {
                s += "        <rdf:li rdf:parseType=\"Resource\"><xmpDM:name>Out</xmpDM:name><xmpDM:startTime>\(Int(o * 30))</xmpDM:startTime></rdf:li>\n"
            }
            s += "      </rdf:Seq>\n"
            s += "    </xmpDM:markers>\n"
        }
        s += "    <!-- /pickshot:markers -->"
        return s
    }

    private func buildFullXMP(markerBlock: String) -> String {
        return """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description
              xmlns:xmp="http://ns.adobe.com/xap/1.0/"
              xmlns:xmpDM="http://ns.adobe.com/xmp/1.0/DynamicMedia/"
              xmlns:pickshot="http://pickshot.app/ns/1.0/">
        \(markerBlock)
            </rdf:Description>
          </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
    }

    private func regex(_ text: String, pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let match = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges >= 2,
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range])
    }
}
