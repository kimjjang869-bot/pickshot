//
//  CLIPTokenizer.swift
//  PhotoRawManager
//
//  v8.9: OpenAI CLIP BPE 토크나이저 (Swift 포팅).
//  - GPT-2 스타일 byte-to-unicode 전처리
//  - bpe_simple_vocab_16e6.txt 에서 48894개 merge 규칙 로드
//  - 총 49408 vocab (256 bytes + 256 byte</w> + 48894 merges + 2 special)
//  - 토큰화 결과는 CLIP 기본 context_length=77 패딩
//

import Foundation
import Compression

final class CLIPTokenizer {
    static let shared = CLIPTokenizer()

    /// BPE 토큰 → id 매핑
    private var encoder: [String: Int] = [:]
    /// byte(0~255) → unicode char (GPT-2 스타일, 모든 바이트를 printable unicode 로 매핑)
    private let byteEncoder: [UInt8: String]
    /// 병합 우선순위 (낮을수록 먼저 병합)
    private var bpeRanks: [BPEPair: Int] = [:]
    /// 이미 계산한 단어의 BPE 캐시
    private var cache: [String: [String]] = [:]
    private let cacheLock = NSLock()

    /// CLIP 기본 context length
    static let contextLength = 77
    /// <|startoftext|>
    private(set) var startToken: Int = 49406
    /// <|endoftext|>
    private(set) var endToken: Int = 49407
    /// 정규식 — 단어/숫자/기호 단위 분할 (CLIP 레퍼런스와 동일)
    private let wordRegex: NSRegularExpression

    private struct BPEPair: Hashable {
        let left: String
        let right: String
    }

    /// 로딩 완료 여부
    private(set) var isLoaded = false

    private init() {
        byteEncoder = Self.makeByteEncoder()
        // CLIP 레퍼런스 regex: "<\\|startoftext\\|>|<\\|endoftext\\|>|'s|'t|'re|'ve|'m|'ll|'d|[\\p{L}]+|[\\p{N}]|[^\\s\\p{L}\\p{N}]+"
        let pattern = #"<\|startoftext\|>|<\|endoftext\|>|'s|'t|'re|'ve|'m|'ll|'d|[\p{L}]+|[\p{N}]|[^\s\p{L}\p{N}]+"#
        wordRegex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    /// 최초 사용 시 vocab 로드. 오래 걸리므로 백그라운드 큐에서 호출 권장.
    func ensureLoaded() {
        guard !isLoaded else { return }
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if isLoaded { return }

        guard let url = Bundle.main.url(forResource: "bpe_simple_vocab_16e6", withExtension: "txt.gz"),
              let gzData = try? Data(contentsOf: url),
              let rawData = Self.gunzip(gzData),
              let text = String(data: rawData, encoding: .utf8) else {
            plog("[CLIP-TOK] bpe_simple_vocab_16e6.txt.gz 로드 실패\n")
            return
        }

        // merges: 헤더 1줄 skip, 48894줄 merge 규칙
        let allLines = text.components(separatedBy: "\n")
        let merges = allLines.dropFirst(1).prefix(48894)

        // encoder: byte 단일 → byte 단일</w> → merged tokens → specials
        var enc: [String: Int] = [:]
        var vocab: [String] = []
        // 기본 256 byte 문자
        for b in 0...255 {
            vocab.append(byteEncoder[UInt8(b)] ?? "")
        }
        // 256 byte + </w> (즉, word-ending 단일 문자)
        for b in 0...255 {
            vocab.append((byteEncoder[UInt8(b)] ?? "") + "</w>")
        }
        // merge 결과 토큰 추가
        var ranks: [BPEPair: Int] = [:]
        for (i, line) in merges.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let pair = BPEPair(left: parts[0], right: parts[1])
            ranks[pair] = i
            vocab.append(parts[0] + parts[1])
        }
        // 특수 토큰
        vocab.append("<|startoftext|>")
        vocab.append("<|endoftext|>")

        for (i, v) in vocab.enumerated() {
            enc[v] = i
        }
        encoder = enc
        bpeRanks = ranks
        startToken = enc["<|startoftext|>"] ?? 49406
        endToken = enc["<|endoftext|>"] ?? 49407
        isLoaded = true
        plog("[CLIP-TOK] loaded vocab=\(encoder.count) merges=\(bpeRanks.count)\n")
    }

    /// 주어진 텍스트 → CLIP 토큰 ID 배열 (길이 = contextLength, 뒤는 0 패딩).
    func tokenize(_ text: String) -> [Int32] {
        ensureLoaded()
        let cleaned = Self.basicClean(text).lowercased()
        var tokenIDs: [Int32] = [Int32(startToken)]

        let range = NSRange(cleaned.startIndex..., in: cleaned)
        wordRegex.enumerateMatches(in: cleaned, options: [], range: range) { match, _, _ in
            guard let m = match, let r = Range(m.range, in: cleaned) else { return }
            let token = String(cleaned[r])
            // byte-level 인코딩
            let byteEncoded = token.utf8.map { byteEncoder[$0] ?? "" }.joined()
            // BPE 병합
            let bpeTokens = bpe(byteEncoded)
            for t in bpeTokens {
                if let id = encoder[t] {
                    tokenIDs.append(Int32(id))
                }
            }
        }

        tokenIDs.append(Int32(endToken))
        // context length 맞춤 (77)
        if tokenIDs.count > Self.contextLength {
            tokenIDs = Array(tokenIDs.prefix(Self.contextLength - 1))
            tokenIDs.append(Int32(endToken))
        } else {
            while tokenIDs.count < Self.contextLength {
                tokenIDs.append(0)
            }
        }
        return tokenIDs
    }

    // MARK: - BPE 병합 알고리즘

    private func bpe(_ token: String) -> [String] {
        if token.isEmpty { return [] }
        cacheLock.lock()
        if let cached = cache[token] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        // 문자 단위로 분리 + 마지막 토큰에 </w> 붙임
        var word: [String] = token.map { String($0) }
        if !word.isEmpty {
            word[word.count - 1] = word[word.count - 1] + "</w>"
        }

        while word.count > 1 {
            // 현재 word 에서 가능한 모든 인접 pair 생성, 가장 낮은 rank 찾기
            var bestRank = Int.max
            var bestIdx = -1
            for i in 0..<(word.count - 1) {
                let pair = BPEPair(left: word[i], right: word[i + 1])
                if let r = bpeRanks[pair], r < bestRank {
                    bestRank = r
                    bestIdx = i
                }
            }
            if bestIdx < 0 { break }  // 더 이상 병합 불가
            // 병합
            let merged = word[bestIdx] + word[bestIdx + 1]
            var newWord: [String] = []
            newWord.reserveCapacity(word.count - 1)
            newWord.append(contentsOf: word[0..<bestIdx])
            newWord.append(merged)
            if bestIdx + 2 < word.count {
                newWord.append(contentsOf: word[(bestIdx + 2)...])
            }
            word = newWord
        }

        cacheLock.lock()
        cache[token] = word
        cacheLock.unlock()
        return word
    }

    // MARK: - 전처리 유틸

    /// 단순 정리 — HTML escape 복원 + 양 끝 공백 제거 + 연속 공백 → 1개.
    private static func basicClean(_ text: String) -> String {
        var s = text
        // 대표적 HTML entity (CLIP 레퍼런스와 동일 범위)
        s = s.replacingOccurrences(of: "&amp;", with: "&")
        s = s.replacingOccurrences(of: "&lt;", with: "<")
        s = s.replacingOccurrences(of: "&gt;", with: ">")
        s = s.replacingOccurrences(of: "&quot;", with: "\"")
        s = s.replacingOccurrences(of: "&apos;", with: "'")
        s = s.replacingOccurrences(of: "&nbsp;", with: " ")
        // 연속 공백/탭/개행 하나로
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// GPT-2 byte_to_unicode: 256개 바이트를 printable unicode 로 매핑.
    /// 이렇게 해야 BPE 가 binary 까지 안정적으로 처리 가능.
    private static func makeByteEncoder() -> [UInt8: String] {
        var bs: [Int] = []
        bs.append(contentsOf: Array(0x21...0x7E))  // '!'~'~'
        bs.append(contentsOf: Array(0xA1...0xAC))
        bs.append(contentsOf: Array(0xAE...0xFF))

        var cs = bs
        var n = 0
        for b in 0..<256 where !bs.contains(b) {
            bs.append(b)
            cs.append(256 + n)
            n += 1
        }

        var map: [UInt8: String] = [:]
        for (b, c) in zip(bs, cs) {
            if let scalar = Unicode.Scalar(c) {
                map[UInt8(b)] = String(scalar)
            }
        }
        return map
    }

    // MARK: - gzip 압축 해제

    private static func gunzip(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Data? in
            guard let base = raw.baseAddress else { return nil }
            // 결과 버퍼는 넉넉히 (gz 압축률 대략 3~5배 가정 → 10배 버퍼)
            let capacity = data.count * 10
            let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
            defer { dst.deallocate() }
            let written = compression_decode_buffer(
                dst, capacity,
                base.assumingMemoryBound(to: UInt8.self).advanced(by: 10),  // gzip 헤더 10바이트 skip
                data.count - 10,
                nil,
                COMPRESSION_ZLIB
            )
            guard written > 0 else { return nil }
            return Data(bytes: dst, count: written)
        }
    }
}

