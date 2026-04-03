import Foundation
import AppKit
import Vision
import ImageIO

struct FaceGroupResult {
    var assignments: [UUID: Int] = [:]   // photoID -> groupID
    var groups: [Int: [UUID]] = [:]       // groupID -> [photoIDs]
    var faceCountPerPhoto: [UUID: Int] = [:]  // photoID -> face count
    var faceThumbnails: [Int: NSImage] = [:]  // groupID -> representative face crop
}

/// Extracts a face thumbnail from a photo for display in the group filter
func extractFaceThumbnail(url: URL, maxSize: CGFloat = 80) -> NSImage? {
    // Use 640px for face thumbnail extraction (fast + sufficient quality)
    let sourceOptions: [NSString: Any] = [kCGImageSourceShouldCache: false]
    guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else { return nil }
    let thumbOptions: [NSString: Any] = [
        kCGImageSourceThumbnailMaxPixelSize: 640,
        kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCache: false
    ]
    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else { return nil }

    let faceRequest = VNDetectFaceRectanglesRequest()
    if #available(macOS 13.0, *) {
        faceRequest.revision = VNDetectFaceRectanglesRequestRevision3
    }
    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
    do {
        try handler.perform([faceRequest])
    } catch {
        print("[FaceGrouping] Face detection failed for \(url.lastPathComponent): \(error.localizedDescription)")
        return nil
    }

    guard let face = faceRequest.results?.filter({ $0.confidence > 0.7 }).max(by: {
        $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height
    }) else { return nil }

    let imgW = CGFloat(cgImage.width)
    let imgH = CGFloat(cgImage.height)
    let box = face.boundingBox
    let faceRect = CGRect(
        x: box.origin.x * imgW,
        y: (1 - box.origin.y - box.height) * imgH,
        width: box.width * imgW,
        height: box.height * imgH
    ).integral.insetBy(dx: -box.width * imgW * 0.2, dy: -box.height * imgH * 0.2)
        .intersection(CGRect(x: 0, y: 0, width: imgW, height: imgH))

    guard faceRect.width > 10, faceRect.height > 10,
          let cropped = cgImage.cropping(to: faceRect) else { return nil }

    return NSImage(cgImage: cropped, size: NSSize(width: maxSize, height: maxSize))
}

struct FaceGroupingService {

    /// Group photos by detected faces using VNFeaturePrint distance comparison.
    /// Improved: higher resolution input, multi-face support, adaptive threshold.
    static func groupFaces(
        photos: [PhotoItem],
        progress: @escaping (Int) -> Void
    ) -> FaceGroupResult {

        // Step 1: Detect ALL faces and compute feature prints
        struct FaceEntry {
            let photoID: UUID
            let featurePrint: VNFeaturePrintObservation
            let faceSize: CGFloat  // relative size of face in image
            let faceIndex: Int     // which face in the photo (0 = largest)
        }

        var allFaces: [FaceEntry] = []
        var faceCountMap: [UUID: Int] = [:]
        let lock = NSLock()
        // Use concurrent perform for better CPU utilization
        let total = photos.count
        DispatchQueue.concurrentPerform(iterations: total) { idx in
            autoreleasepool {
                let photo = photos[idx]
                let faces = extractAllFaceFeaturePrints(url: photo.jpgURL)

                lock.lock()
                faceCountMap[photo.id] = faces.count
                for (i, face) in faces.enumerated() {
                    allFaces.append(FaceEntry(
                        photoID: photo.id,
                        featurePrint: face.featurePrint,
                        faceSize: face.relativeSize,
                        faceIndex: i
                    ))
                }
                let done = faceCountMap.count
                lock.unlock()

                if done % 20 == 0 || done == total {
                    progress(done)
                }
            }
        }

        guard !allFaces.isEmpty else { return FaceGroupResult(faceCountPerPhoto: faceCountMap) }

        // Step 2: Cluster faces using union-find with adaptive threshold
        var result = FaceGroupResult()
        result.faceCountPerPhoto = faceCountMap

        // Union-Find
        var parent = Array(0..<allFaces.count)
        var rank = Array(repeating: 0, count: allFaces.count)

        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x {
                parent[x] = parent[parent[x]]  // path compression
                x = parent[x]
            }
            return x
        }

        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra == rb { return }
            if rank[ra] < rank[rb] { parent[ra] = rb }
            else if rank[ra] > rank[rb] { parent[rb] = ra }
            else { parent[rb] = ra; rank[ra] += 1 }
        }

        // Compare all pairs — parallelized for speed
        let n = allFaces.count
        let maxCompare = min(n, 5000)

        // Pre-compute pairs to compare, then parallelize
        struct PairResult {
            let i: Int
            let j: Int
        }
        let pairLock = NSLock()
        var matchedPairs: [PairResult] = []

        DispatchQueue.concurrentPerform(iterations: min(n, maxCompare)) { i in
            var localPairs: [PairResult] = []
            for j in (i + 1)..<min(n, maxCompare) {
                if allFaces[i].photoID == allFaces[j].photoID { continue }

                var distance: Float = 0
                do {
                    try allFaces[i].featurePrint.computeDistance(&distance, to: allFaces[j].featurePrint)
                } catch { continue }

                let avgSize = Float((allFaces[i].faceSize + allFaces[j].faceSize) / 2)
                // Balanced thresholds: strict enough to avoid false grouping, lenient enough to catch same person
                let threshold: Float = avgSize > 0.15 ? 0.62 : (avgSize > 0.08 ? 0.58 : 0.52)

                if distance < threshold {
                    localPairs.append(PairResult(i: i, j: j))
                }
            }
            if !localPairs.isEmpty {
                pairLock.lock()
                matchedPairs.append(contentsOf: localPairs)
                pairLock.unlock()
            }
        }

        // Apply unions (sequential — union-find is not thread-safe)
        for pair in matchedPairs {
            union(pair.i, pair.j)
        }

        // Build groups from union-find
        var clusterMap: [Int: [Int]] = [:]
        for i in 0..<allFaces.count {
            let root = find(i)
            clusterMap[root, default: []].append(i)
        }

        // Convert to photo-level groups (2+ distinct photos, sorted by size)
        var groupID = 0
        for (_, members) in clusterMap.sorted(by: { $0.value.count > $1.value.count }) {
            let photoIDs = Set(members.map { allFaces[$0].photoID })
            if photoIDs.count >= 2 {
                for photoID in photoIDs {
                    result.assignments[photoID] = groupID
                }
                result.groups[groupID] = Array(photoIDs)
                groupID += 1
            }
        }

        return result
    }

    /// Extract ALL faces from a photo with feature prints (up to 3 largest)
    private static func extractAllFaceFeaturePrints(url: URL) -> [(featurePrint: VNFeaturePrintObservation, relativeSize: CGFloat)] {
        // Use 640px — sufficient for face detection, 4x faster than 1280px
        let sourceOptions: [NSString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else { return [] }
        let thumbOptions: [NSString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: 640,
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldCache: false
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else { return [] }

        // Batch: detect faces + feature prints in single handler
        let faceRequest = VNDetectFaceRectanglesRequest()
        if #available(macOS 13.0, *) {
            faceRequest.revision = VNDetectFaceRectanglesRequestRevision3
        }
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        do {
            try handler.perform([faceRequest])
        } catch { return [] }

        // Higher confidence threshold (0.7) to exclude false positives (hands, objects, patterns)
        guard let faces = faceRequest.results?.filter({ $0.confidence > 0.7 }), !faces.isEmpty else { return [] }

        // Sort by size descending, take up to 3
        let sortedFaces = faces.sorted {
            ($0.boundingBox.width * $0.boundingBox.height) > ($1.boundingBox.width * $1.boundingBox.height)
        }.prefix(3)

        let imgW = CGFloat(cgImage.width)
        let imgH = CGFloat(cgImage.height)
        var results: [(featurePrint: VNFeaturePrintObservation, relativeSize: CGFloat)] = []

        for face in sortedFaces {
            let box = face.boundingBox
            let relativeSize = box.width * box.height
            // Skip tiny faces (< 2% of image) — too small to be reliable
            guard relativeSize > 0.02 else { continue }
            // Skip unrealistically large "faces" (> 80% of image) — likely false detection
            guard relativeSize < 0.8 else { continue }

            let faceRect = CGRect(
                x: box.origin.x * imgW,
                y: (1 - box.origin.y - box.height) * imgH,
                width: box.width * imgW,
                height: box.height * imgH
            ).integral

            let expanded = faceRect.insetBy(dx: -faceRect.width * 0.15, dy: -faceRect.height * 0.15)
            let clipped = expanded.intersection(CGRect(x: 0, y: 0, width: imgW, height: imgH))

            guard clipped.width > 15, clipped.height > 15,
                  let faceCrop = cgImage.cropping(to: clipped) else { continue }

            let fpRequest = VNGenerateImageFeaturePrintRequest()
            let fpHandler = VNImageRequestHandler(cgImage: faceCrop, options: [:])

            do {
                try fpHandler.perform([fpRequest])
                if let fp = fpRequest.results?.first {
                    results.append((featurePrint: fp, relativeSize: relativeSize))
                }
            } catch { continue }
        }

        return results
    }
}
