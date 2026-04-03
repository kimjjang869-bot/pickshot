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
    // Try hardware JPEG decode, fall back to CGImageSource
    let isJPEG = ["jpg", "jpeg"].contains(url.pathExtension.lowercased())
    let cgImage: CGImage
    if isJPEG, HWJPEGDecoder.isAvailable, let hwImage = HWJPEGDecoder.decode(url: url, maxPixel: 1280) {
        cgImage = hwImage
    } else {
        let sourceOptions: [NSString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else { return nil }
        let thumbOptions: [NSString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: 1280,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCache: false
        ]
        guard let swImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else { return nil }
        cgImage = swImage
    }

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

    guard let face = faceRequest.results?.filter({ $0.confidence > 0.5 }).max(by: {
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

        // Compare all pairs (for large sets, limit to reasonable count)
        let maxCompare = min(allFaces.count, 5000)  // Cap for performance
        for i in 0..<min(allFaces.count, maxCompare) {
            for j in (i + 1)..<min(allFaces.count, maxCompare) {
                // Skip if same photo
                if allFaces[i].photoID == allFaces[j].photoID { continue }

                var distance: Float = 0
                do {
                    try allFaces[i].featurePrint.computeDistance(&distance, to: allFaces[j].featurePrint)
                } catch { continue }

                // Adaptive threshold based on face size
                // Lower distance = more similar, so lower threshold = stricter
                // Large faces have more detail so we can be more lenient (higher threshold)
                // Small faces need more leniency too since they have less detail
                let avgSize = Float((allFaces[i].faceSize + allFaces[j].faceSize) / 2)
                let threshold: Float
                if avgSize > 0.15 {
                    threshold = 0.65  // Large faces: lenient (more detail available)
                } else if avgSize > 0.08 {
                    threshold = 0.6   // Medium faces: moderate
                } else {
                    threshold = 0.55  // Small faces: more lenient (less detail)
                }

                if distance < threshold {
                    union(i, j)
                }
            }
        }

        // Build groups from union-find
        var clusterMap: [Int: [Int]] = [:]
        for i in 0..<allFaces.count {
            let root = find(i)
            clusterMap[root, default: []].append(i)
        }

        // Convert to photo-level groups (only groups with 2+ distinct photos)
        var groupID = 0
        for (_, members) in clusterMap {
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

    /// Extract ALL faces from a photo with feature prints (up to 5 largest)
    private static func extractAllFaceFeaturePrints(url: URL) -> [(featurePrint: VNFeaturePrintObservation, relativeSize: CGFloat)] {
        // Use 1280px for better face detection accuracy in group photos
        // Try hardware JPEG decode, fall back to CGImageSource
        let isJPEG = ["jpg", "jpeg"].contains(url.pathExtension.lowercased())
        let cgImage: CGImage
        if isJPEG, HWJPEGDecoder.isAvailable, let hwImage = HWJPEGDecoder.decode(url: url, maxPixel: 1280) {
            cgImage = hwImage
        } else {
            let sourceOptions: [NSString: Any] = [kCGImageSourceShouldCache: false]
            guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else { return [] }
            let thumbOptions: [NSString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: 1280,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCache: false
            ]
            guard let swImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else { return [] }
            cgImage = swImage
        }

        // Detect faces
        let faceRequest = VNDetectFaceRectanglesRequest()
        if #available(macOS 13.0, *) {
            faceRequest.revision = VNDetectFaceRectanglesRequestRevision3
        }
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        do {
            try handler.perform([faceRequest])
        } catch { return [] }

        guard let faces = faceRequest.results?.filter({ $0.confidence > 0.5 }), !faces.isEmpty else { return [] }

        // Sort by size descending, take up to 5
        let sortedFaces = faces.sorted {
            ($0.boundingBox.width * $0.boundingBox.height) > ($1.boundingBox.width * $1.boundingBox.height)
        }.prefix(5)

        let imgW = CGFloat(cgImage.width)
        let imgH = CGFloat(cgImage.height)
        var results: [(featurePrint: VNFeaturePrintObservation, relativeSize: CGFloat)] = []

        for face in sortedFaces {
            let box = face.boundingBox
            let relativeSize = box.width * box.height

            // Skip very small faces (< 1% of image)
            guard relativeSize > 0.01 else { continue }

            let faceRect = CGRect(
                x: box.origin.x * imgW,
                y: (1 - box.origin.y - box.height) * imgH,
                width: box.width * imgW,
                height: box.height * imgH
            ).integral

            // Expand by 15% for context
            let expanded = faceRect.insetBy(dx: -faceRect.width * 0.15, dy: -faceRect.height * 0.15)
            let clipped = expanded.intersection(CGRect(x: 0, y: 0, width: imgW, height: imgH))

            guard clipped.width > 20, clipped.height > 20,
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
