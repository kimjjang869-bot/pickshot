import SwiftUI

struct StatsDashboardView: View {
    @EnvironmentObject var store: PhotoStore
    @Environment(\.dismiss) var dismiss
    private var stats: SelectionStats { SelectionStats(photos: store.photos) }

    var body: some View {
        VStack(spacing: 16) {
            HStack { Text("셀렉 통계").font(.system(size: 18, weight: .bold)); Spacer(); Button("닫기") { dismiss() }.keyboardShortcut(.escape) }
            Divider()
            ScrollView {
                VStack(spacing: 16) {
                    overviewSection; Divider().opacity(0.3); ratingSection; Divider().opacity(0.3); qualitySection; Divider().opacity(0.3); fileTypeSection
                    if !stats.cameraBreakdown.isEmpty { Divider().opacity(0.3); cameraSection }
                }
            }
        }.padding(24).frame(width: 480, height: 560)
    }

    private var overviewSection: some View {
        HStack(spacing: 12) {
            statCard("\(stats.totalPhotos)", "전체", .primary); statCard("\(stats.spacePickCount)", "셀렉", .accentColor)
            statCard("\(stats.ratedCount)", "별점", .yellow); statCard("\(stats.aiPickCount)", "AI 추천", .green)
        }
    }

    private var ratingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("별점 분포").font(.system(size: 13, weight: .semibold))
            ForEach(0...5, id: \.self) { rating in
                let count = stats.ratingCounts[rating] ?? 0
                let pct = stats.totalPhotos > 0 ? Double(count) / Double(stats.totalPhotos) : 0
                HStack(spacing: 8) {
                    if rating == 0 { Text("없음").font(.system(size: 11)).frame(width: 40, alignment: .trailing) }
                    else { HStack(spacing: 1) { ForEach(0..<rating, id: \.self) { _ in Image(systemName: "star.fill").font(.system(size: 8)).foregroundColor(.yellow) } }.frame(width: 40, alignment: .trailing) }
                    barView(fraction: pct, color: rating == 0 ? .gray : .yellow)
                    Text("\(count)").font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary).frame(width: 40, alignment: .trailing)
                }
            }
        }
    }

    private var qualitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("품질 분포").font(.system(size: 13, weight: .semibold))
            if stats.analyzedCount == 0 { HStack { Image(systemName: "info.circle").foregroundColor(.secondary); Text("품질 분석을 먼저 실행하세요").font(.system(size: 12)).foregroundColor(.secondary) } }
            else {
                let items: [(String, Int, Color)] = [("좋음", stats.qualityGood, .green), ("보통", stats.qualityAverage, .orange), ("문제", stats.qualityPoor, .red), ("미분석", stats.totalPhotos - stats.analyzedCount, .gray)]
                ForEach(items, id: \.0) { label, count, color in
                    HStack(spacing: 8) { Text(label).font(.system(size: 11)).frame(width: 40, alignment: .trailing); barView(fraction: stats.totalPhotos > 0 ? Double(count) / Double(stats.totalPhotos) : 0, color: color); Text("\(count)").font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary).frame(width: 40, alignment: .trailing) }
                }
                if stats.analyzedCount > 0 { HStack { Spacer(); Text("평균 점수: \(stats.averageScore)점").font(.system(size: 12, weight: .medium)).foregroundColor(.accentColor) }.padding(.top, 4) }
            }
        }
    }

    private var fileTypeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("파일 형식").font(.system(size: 13, weight: .semibold))
            let items: [(String, Int, Color)] = [("JPG", stats.jpgOnlyCount, .blue), ("RAW+JPG", stats.rawJpgCount, .green), ("RAW", stats.rawOnlyCount, .orange), ("기타", stats.otherCount, .gray)]
            ForEach(items.filter { $0.1 > 0 }, id: \.0) { label, count, color in
                HStack(spacing: 8) { Text(label).font(.system(size: 11)).frame(width: 50, alignment: .trailing); barView(fraction: stats.totalPhotos > 0 ? Double(count) / Double(stats.totalPhotos) : 0, color: color); Text("\(count)").font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary).frame(width: 40, alignment: .trailing) }
            }
            if stats.totalSize > 0 { HStack { Spacer(); Text("총 용량: \(formatSize(stats.totalSize))").font(.system(size: 12, weight: .medium)).foregroundColor(.secondary) }.padding(.top, 4) }
        }
    }

    private var cameraSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("카메라").font(.system(size: 13, weight: .semibold))
            ForEach(stats.cameraBreakdown.sorted(by: { $0.value > $1.value }).prefix(5), id: \.key) { camera, count in
                HStack(spacing: 8) { Text(camera).font(.system(size: 11)).lineLimit(1).frame(width: 100, alignment: .trailing); barView(fraction: stats.totalPhotos > 0 ? Double(count) / Double(stats.totalPhotos) : 0, color: .accentColor); Text("\(count)").font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary).frame(width: 40, alignment: .trailing) }
            }
        }
    }

    private func statCard(_ value: String, _ label: String, _ color: Color) -> some View {
        VStack(spacing: 2) { Text(value).font(.system(size: 22, weight: .bold, design: .rounded)).foregroundColor(color); Text(label).font(.system(size: 11)).foregroundColor(.secondary) }
            .frame(maxWidth: .infinity).padding(.vertical, 10).background(Color.gray.opacity(0.1)).cornerRadius(8)
    }

    private func barView(fraction: Double, color: Color) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) { RoundedRectangle(cornerRadius: 3).fill(Color.gray.opacity(0.15)); RoundedRectangle(cornerRadius: 3).fill(color).frame(width: max(0, geo.size.width * CGFloat(fraction))) }
        }.frame(height: 14)
    }

    private func formatSize(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        return gb >= 1 ? String(format: "%.1f GB", gb) : String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }
}

struct SelectionStats {
    let totalPhotos: Int, spacePickCount: Int, ratedCount: Int, aiPickCount: Int
    let ratingCounts: [Int: Int], analyzedCount: Int, qualityGood: Int, qualityAverage: Int, qualityPoor: Int, averageScore: Int
    let jpgOnlyCount: Int, rawJpgCount: Int, rawOnlyCount: Int, otherCount: Int, totalSize: Int64, cameraBreakdown: [String: Int]

    init(photos: [PhotoItem]) {
        let nonFolder = photos.filter { !$0.isFolder && !$0.isParentFolder }
        totalPhotos = nonFolder.count
        var sp = 0, rt = 0, ai = 0, ratings: [Int: Int] = [0:0,1:0,2:0,3:0,4:0,5:0]
        var an = 0, gd = 0, av = 0, pr = 0, ss = 0, jo = 0, rj = 0, ro = 0, ot = 0; var sz: Int64 = 0; var cam: [String: Int] = [:]
        for p in nonFolder {
            if p.isSpacePicked { sp += 1 }; if p.rating > 0 { rt += 1 }; if p.isAIPick { ai += 1 }
            ratings[p.rating, default: 0] += 1
            if let q = p.quality, q.isAnalyzed { an += 1; ss += q.score; switch q.overallGrade { case .good: gd += 1; case .average: av += 1; case .poor: pr += 1 } }
            if p.isRawOnly { ro += 1 } else if p.hasRAW { rj += 1 } else if p.isImageFile || p.isVideoFile || p.isGenericFile { ot += 1 } else { jo += 1 }
            sz += p.jpgFileSize + p.rawFileSize
            if let m = p.exifData?.cameraModel { cam[m, default: 0] += 1 }
        }
        spacePickCount = sp; ratedCount = rt; aiPickCount = ai; ratingCounts = ratings; analyzedCount = an
        qualityGood = gd; qualityAverage = av; qualityPoor = pr; averageScore = an > 0 ? ss / an : 0
        jpgOnlyCount = jo; rawJpgCount = rj; rawOnlyCount = ro; otherCount = ot; totalSize = sz; cameraBreakdown = cam
    }
}
