import SwiftUI
import Vision
import AppKit

// MARK: - Face Compare View

struct FaceCompareView: View {
    let photos: [PhotoItem]  // 2-6 photos to compare
    @EnvironmentObject var store: PhotoStore
    @Environment(\.dismiss) var dismiss

    @State private var faceRows: [[FaceCrop?]] = []  // rows[faceIndex][photoIndex]
    @State private var isLoading = true
    @State private var bestFaceIndices: [Int] = []  // per-row best photo index
    @State private var smileScores: [[Double]] = []  // rows[faceIndex][photoIndex]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header

            Divider()

            // Content
            if isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(1.2)
                    Text("얼굴 감지 중...")
                        .font(.system(size: AppTheme.fontBody))
                        .foregroundColor(AppTheme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if faceRows.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "face.dashed")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary)
                    Text("감지된 얼굴이 없습니다")
                        .font(.system(size: AppTheme.fontSubhead, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                faceGrid
            }

            Divider()

            // Bottom actions
            bottomActions
        }
        .frame(minWidth: 600, minHeight: 400)
        .frame(maxWidth: 1000, maxHeight: 700)
        .task {
            await detectFaces()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "face.smiling")
                .font(.system(size: AppTheme.iconMedium))
                .foregroundColor(AppTheme.accent)
            Text("표정 비교 (\(photos.count)장)")
                .font(.system(size: AppTheme.fontHeading, weight: .bold))

            Spacer()

            Button(action: { dismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Face Grid

    private var faceGrid: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Column headers (file names)
                HStack(spacing: 8) {
                    Text("얼굴")
                        .font(.system(size: AppTheme.fontCaption, weight: .medium))
                        .foregroundColor(AppTheme.textDim)
                        .frame(width: 40)

                    ForEach(Array(photos.enumerated()), id: \.offset) { idx, photo in
                        VStack(spacing: 2) {
                            Text(photo.fileName)
                                .font(.system(size: AppTheme.fontMicro, weight: .medium, design: .monospaced))
                                .foregroundColor(AppTheme.textPrimary)
                                .lineLimit(1)
                            HStack(spacing: 2) {
                                ForEach(0..<photo.rating, id: \.self) { _ in
                                    Image(systemName: "star.fill")
                                        .font(.system(size: 7))
                                        .foregroundColor(AppTheme.starGold)
                                }
                                if photo.isSpacePicked {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 8))
                                        .foregroundColor(AppTheme.spBadge)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(nsColor: .windowBackgroundColor))

                Divider()

                // Face rows
                ForEach(Array(faceRows.enumerated()), id: \.offset) { rowIdx, row in
                    HStack(spacing: 8) {
                        // Row label
                        Text("#\(rowIdx + 1)")
                            .font(.system(size: AppTheme.fontCaption, weight: .bold))
                            .foregroundColor(AppTheme.textDim)
                            .frame(width: 40)

                        // Face cells
                        ForEach(Array(row.enumerated()), id: \.offset) { colIdx, faceCrop in
                            faceCellView(faceCrop: faceCrop, rowIdx: rowIdx, colIdx: colIdx)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)

                    if rowIdx < faceRows.count - 1 {
                        Divider().padding(.horizontal, 12)
                    }
                }
            }
        }
    }

    // MARK: - Face Cell

    private func faceCellView(faceCrop: FaceCrop?, rowIdx: Int, colIdx: Int) -> some View {
        let isBest = rowIdx < bestFaceIndices.count && bestFaceIndices[rowIdx] == colIdx
        let score = (rowIdx < smileScores.count && colIdx < smileScores[rowIdx].count) ? smileScores[rowIdx][colIdx] : 0

        return VStack(spacing: 4) {
            if let crop = faceCrop, let image = crop.image {
                ZStack(alignment: .topTrailing) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 100, height: 100)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(isBest ? AppTheme.success : Color.clear, lineWidth: isBest ? 3 : 0)
                        )

                    if isBest {
                        Image(systemName: "star.fill")
                            .font(.system(size: 12))
                            .foregroundColor(AppTheme.starGold)
                            .padding(4)
                            .background(Color.black.opacity(0.6))
                            .clipShape(Circle())
                            .offset(x: -4, y: 4)
                    }
                }
                .onTapGesture {
                    // Click to select this photo in main viewer
                    store.selectPhoto(photos[colIdx].id, cmdKey: false)
                    dismiss()
                }

                // Smile indicator
                HStack(spacing: 2) {
                    Image(systemName: smileIcon(score: score))
                        .font(.system(size: 9))
                        .foregroundColor(smileColor(score: score))
                    Text(smileLabel(score: score))
                        .font(.system(size: AppTheme.fontMicro))
                        .foregroundColor(smileColor(score: score))
                }
            } else {
                // No face detected in this photo at this position
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.1))
                    .frame(width: 100, height: 100)
                    .overlay(
                        Image(systemName: "face.dashed")
                            .font(.system(size: 20))
                            .foregroundColor(.gray.opacity(0.3))
                    )
                Text("-")
                    .font(.system(size: AppTheme.fontMicro))
                    .foregroundColor(AppTheme.textDim)
            }
        }
    }

    // MARK: - Bottom Actions

    private var bottomActions: some View {
        HStack(spacing: 12) {
            // Info
            if !faceRows.isEmpty {
                Text("\(faceRows.count)명 감지")
                    .font(.system(size: AppTheme.fontCaption))
                    .foregroundColor(AppTheme.textSecondary)
            }

            Spacer()

            // Pick best button
            if let bestPhoto = overallBestPhoto {
                Button(action: {
                    store.toggleSpacePick(for: bestPhoto.id)
                    store.showToastMessage("\(bestPhoto.fileName) 스페이스 셀렉 토글")
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: AppTheme.iconSmall))
                        Text("이 사진 선택")
                            .font(.system(size: AppTheme.fontBody, weight: .medium))
                        Text("(\(bestPhoto.fileName))")
                            .font(.system(size: AppTheme.fontMicro))
                            .foregroundColor(AppTheme.textSecondary)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.accent)
            }

            Button("닫기") { dismiss() }
                .keyboardShortcut(.escape)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Smile Helpers

    private func smileIcon(score: Double) -> String {
        if score >= 0.6 { return "face.smiling.inverse" }
        if score >= 0.3 { return "face.smiling" }
        return "face.dashed"
    }

    private func smileColor(score: Double) -> Color {
        if score >= 0.6 { return AppTheme.success }
        if score >= 0.3 { return AppTheme.warning }
        return AppTheme.textDim
    }

    private func smileLabel(score: Double) -> String {
        if score >= 0.6 { return "좋음" }
        if score >= 0.3 { return "보통" }
        return "낮음"
    }

    /// Overall best photo: most faces with highest average smile
    private var overallBestPhoto: PhotoItem? {
        guard !photos.isEmpty, !smileScores.isEmpty else { return nil }
        var photoScores = [Double](repeating: 0, count: photos.count)
        var faceCounts = [Int](repeating: 0, count: photos.count)
        for rowIdx in 0..<smileScores.count {
            for colIdx in 0..<smileScores[rowIdx].count {
                if smileScores[rowIdx][colIdx] > 0 {
                    photoScores[colIdx] += smileScores[rowIdx][colIdx]
                    faceCounts[colIdx] += 1
                }
            }
        }
        // Normalize by face count, prefer photos with more detected faces
        var bestIdx = 0
        var bestScore = -1.0
        for i in 0..<photos.count {
            let avg = faceCounts[i] > 0 ? photoScores[i] / Double(faceCounts[i]) : 0
            let bonus = Double(faceCounts[i]) * 0.1  // slight bonus for more faces
            let total = avg + bonus
            if total > bestScore {
                bestScore = total
                bestIdx = i
            }
        }
        return bestScore > 0 ? photos[bestIdx] : nil
    }

    // MARK: - Face Detection

    private func detectFaces() async {
        var allFaces: [[DetectedFace]] = []  // [photoIndex][faceIndex]

        // Detect faces in each photo
        for photo in photos {
            let faces = await detectFacesInPhoto(url: photo.jpgURL)
            allFaces.append(faces)
        }

        // Find max faces across photos
        let maxFaces = allFaces.map(\.count).max() ?? 0
        guard maxFaces > 0 else {
            await MainActor.run {
                isLoading = false
            }
            return
        }

        // Build grid: rows = face index, columns = photo index
        // Match faces across photos by vertical position (top to bottom)
        var rows: [[FaceCrop?]] = []
        var scores: [[Double]] = []
        var bestIndices: [Int] = []

        // Sort each photo's faces by Y position (top to bottom) for alignment
        let sortedFaces = allFaces.map { faces in
            faces.sorted { $0.boundingBox.origin.y > $1.boundingBox.origin.y }
        }

        for faceIdx in 0..<maxFaces {
            var row: [FaceCrop?] = []
            var rowScores: [Double] = []
            var bestCol = -1
            var bestSmile = -1.0

            for photoIdx in 0..<photos.count {
                if faceIdx < sortedFaces[photoIdx].count {
                    let face = sortedFaces[photoIdx][faceIdx]
                    let crop = cropFace(from: photos[photoIdx].jpgURL, boundingBox: face.boundingBox)
                    row.append(crop)
                    rowScores.append(face.smileScore)
                    if face.smileScore > bestSmile {
                        bestSmile = face.smileScore
                        bestCol = photoIdx
                    }
                } else {
                    row.append(nil)
                    rowScores.append(0)
                }
            }

            rows.append(row)
            scores.append(rowScores)
            bestIndices.append(bestCol)
        }

        await MainActor.run {
            self.faceRows = rows
            self.smileScores = scores
            self.bestFaceIndices = bestIndices
            self.isLoading = false
        }
    }

    private func detectFacesInPhoto(url: URL) async -> [DetectedFace] {
        guard let cgImage = loadCGImage(url: url, maxSize: 1280) else { return [] }

        return await withCheckedContinuation { continuation in
            let request = VNDetectFaceLandmarksRequest { request, error in
                guard let results = request.results as? [VNFaceObservation] else {
                    continuation.resume(returning: [])
                    return
                }

                var faces: [DetectedFace] = []
                for obs in results {
                    let smileScore = Self.estimateSmileScore(observation: obs)
                    faces.append(DetectedFace(
                        boundingBox: obs.boundingBox,
                        smileScore: smileScore
                    ))
                }
                continuation.resume(returning: faces)
            }

            if #available(macOS 13.0, *) {
                request.revision = VNDetectFaceLandmarksRequestRevision3
            }

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: [])
            }
        }
    }

    /// Estimate smile score from face landmarks (0.0 - 1.0)
    static func estimateSmileScore(observation: VNFaceObservation) -> Double {
        guard let landmarks = observation.landmarks else { return 0.3 }

        // Use mouth geometry as smile proxy
        // Wider mouth relative to face width + upturned corners = smile
        var score = 0.3  // baseline

        if let outerLips = landmarks.outerLips {
            let points = outerLips.normalizedPoints
            guard points.count >= 6 else { return score }

            // Mouth width relative to face width
            let faceWidth = observation.boundingBox.width
            let mouthLeft = points.min(by: { $0.x < $1.x })?.x ?? 0
            let mouthRight = points.max(by: { $0.x < $1.x })?.x ?? 0
            let mouthWidth = mouthRight - mouthLeft
            let widthRatio = faceWidth > 0 ? mouthWidth / faceWidth : 0

            // Mouth height (openness)
            let mouthTop = points.max(by: { $0.y < $1.y })?.y ?? 0
            let mouthBottom = points.min(by: { $0.y < $1.y })?.y ?? 0
            let mouthHeight = mouthTop - mouthBottom

            // Corner upturn: compare corner Y to center bottom Y
            let leftCornerY = points.first?.y ?? 0
            let rightCornerY = points.last?.y ?? 0
            let centerBottomY = mouthBottom
            let cornerUpturn = ((leftCornerY - centerBottomY) + (rightCornerY - centerBottomY)) / 2

            // Score calculation
            if widthRatio > 0.45 { score += 0.2 }  // wide mouth
            if mouthHeight > 0.05 { score += 0.1 }  // open mouth
            if cornerUpturn > 0.01 { score += 0.3 }  // upturned corners (smiling)
            else if cornerUpturn < -0.01 { score -= 0.1 }  // downturned (frowning)
        }

        // Eye openness contributes slightly (open eyes = better expression)
        if let leftEye = landmarks.leftEye, let rightEye = landmarks.rightEye {
            let leftPoints = leftEye.normalizedPoints
            let rightPoints = rightEye.normalizedPoints
            if leftPoints.count >= 4 && rightPoints.count >= 4 {
                let leftHeight = (leftPoints.max(by: { $0.y < $1.y })?.y ?? 0) - (leftPoints.min(by: { $0.y < $1.y })?.y ?? 0)
                let rightHeight = (rightPoints.max(by: { $0.y < $1.y })?.y ?? 0) - (rightPoints.min(by: { $0.y < $1.y })?.y ?? 0)
                let avgEyeOpen = (leftHeight + rightHeight) / 2
                if avgEyeOpen > 0.04 { score += 0.1 }  // well-open eyes
                else if avgEyeOpen < 0.015 { score -= 0.2 }  // closed eyes penalty
            }
        }

        return min(1.0, max(0.0, score))
    }

    // MARK: - Image Helpers

    private func loadCGImage(url: URL, maxSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxSize,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private func cropFace(from url: URL, boundingBox: CGRect) -> FaceCrop? {
        guard let cgImage = loadCGImage(url: url, maxSize: 1280) else { return nil }

        let imgW = CGFloat(cgImage.width)
        let imgH = CGFloat(cgImage.height)

        // Convert normalized boundingBox to pixel coords
        // Vision: origin is bottom-left, need to flip Y
        let margin: CGFloat = 0.3  // 30% margin around face
        let faceX = boundingBox.origin.x * imgW
        let faceY = (1.0 - boundingBox.origin.y - boundingBox.height) * imgH
        let faceW = boundingBox.width * imgW
        let faceH = boundingBox.height * imgH

        let cropX = max(0, faceX - faceW * margin)
        let cropY = max(0, faceY - faceH * margin)
        let cropW = min(imgW - cropX, faceW * (1 + 2 * margin))
        let cropH = min(imgH - cropY, faceH * (1 + 2 * margin))

        let cropRect = CGRect(x: cropX, y: cropY, width: cropW, height: cropH)
        guard let cropped = cgImage.cropping(to: cropRect) else { return nil }

        let nsImage = NSImage(cgImage: cropped, size: NSSize(width: cropW, height: cropH))
        return FaceCrop(image: nsImage, boundingBox: boundingBox)
    }
}

// MARK: - Supporting Types

struct DetectedFace {
    let boundingBox: CGRect
    let smileScore: Double
}

struct FaceCrop {
    let image: NSImage?
    let boundingBox: CGRect
}

// MARK: - Sheet Wrapper (breaks up type-checker complexity)

struct FaceCompareSheet: View {
    @ObservedObject var store: PhotoStore

    var body: some View {
        let selected = Array(store.multiSelectedPhotos.prefix(6))
        if selected.count >= 2 {
            FaceCompareView(photos: selected)
                .environmentObject(store)
        } else {
            Text("2장 이상 선택해주세요")
                .frame(width: 300, height: 200)
        }
    }
}
