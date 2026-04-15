//
//  ParallelFFD8Scanner.swift
//  PhotoRawManager
//
//  RAW 파일 내부에 임베드된 JPEG 시작 마커(0xFFD8)를 병렬 청크 스캔으로 탐지한다.
//

import Foundation

// MARK: - Parallel FFD8 Scanner

/// Memory-mapped, parallel FFD8 marker scanner for extracting embedded JPEGs from RAW files.
struct ParallelFFD8Scanner {

    /// Scan data for FFD8 JPEG markers using parallel chunked search.
    /// Returns offsets sorted by position.
    static func findMarkers(in data: Data, maxMarkers: Int = 10) -> [Int] {
        let count = data.count
        guard count > 2 else { return [] }

        // Split data into chunks for parallel scanning
        let chunkCount = min(ProcessInfo.processInfo.activeProcessorCount, 8)
        let chunkSize = count / chunkCount

        let lock = NSLock()
        var allOffsets: [Int] = []

        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }

            DispatchQueue.concurrentPerform(iterations: chunkCount) { ci in
                let start = ci * chunkSize
                let end = min(start + chunkSize + 1, count - 1)  // +1 overlap for boundary
                var localOffsets: [Int] = []

                for i in start..<end {
                    if base[i] == 0xFF && base[i + 1] == 0xD8 {
                        localOffsets.append(i)
                        if localOffsets.count >= maxMarkers { break }
                    }
                }

                lock.lock()
                allOffsets.append(contentsOf: localOffsets)
                lock.unlock()
            }
        }

        return allOffsets.sorted().prefix(maxMarkers).map { $0 }
    }
}
