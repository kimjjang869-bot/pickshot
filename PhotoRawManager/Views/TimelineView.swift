import SwiftUI

struct TimelineView: View {
    @EnvironmentObject var store: PhotoStore
    @Environment(\.dismiss) var dismiss
    private var groups: [TimeGroup] { TimelineBuilder.build(photos: store.filteredPhotos.filter { !$0.isFolder && !$0.isParentFolder }) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Text("타임라인").font(.system(size: 18, weight: .bold))
                Spacer()
            }
            .overlay(alignment: .trailing) {
                HStack(spacing: 8) {
                    if !groups.isEmpty { Text("\(groups.count)개 시간대 · \(groups.reduce(0) { $0 + $1.photos.count })장").font(.system(size: 12)).foregroundColor(.secondary) }
                    Button("닫기") { dismiss() }.keyboardShortcut(.escape)
                }
            }.padding(.horizontal, 20).padding(.vertical, 12)
            Divider()
            if groups.isEmpty { emptyView } else { timelineMiniBar; Divider().opacity(0.3); ScrollView { LazyVStack(spacing: 16) { ForEach(groups) { groupRow($0) } }.padding(16) } }
        }.frame(minWidth: 700, minHeight: 500)
    }

    private var emptyView: some View {
        VStack(spacing: 12) { Spacer(); Image(systemName: "clock.arrow.circlepath").font(.system(size: 40)).foregroundColor(.secondary.opacity(0.4))
            Text("촬영 시간 정보가 있는 사진이 없습니다").font(.system(size: 14)).foregroundColor(.secondary); Spacer() }
    }

    private var timelineMiniBar: some View {
        GeometryReader { geo in
            let width = geo.size.width - 32
            HStack(spacing: 0) {
                ForEach(groups) { group in
                    let fraction = CGFloat(group.photos.count) / CGFloat(max(1, groups.reduce(0) { $0 + $1.photos.count }))
                    Rectangle().fill(group.hasSelections ? Color.green : Color.accentColor.opacity(0.5))
                        .frame(width: max(2, width * fraction), height: 24)
                        .overlay(Group { if max(2, width * fraction) > 30 { Text(group.shortLabel).font(.system(size: 8, weight: .medium)).foregroundColor(.white).lineLimit(1) } })
                        .onTapGesture { if let f = group.photos.first { store.selectPhoto(f.id, cmdKey: false) } }
                }
            }.clipShape(RoundedRectangle(cornerRadius: 4)).padding(.horizontal, 16)
        }.frame(height: 32).padding(.vertical, 4)
    }

    private func groupRow(_ group: TimeGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "clock").font(.system(size: 12)).foregroundColor(.accentColor)
                Text(group.label).font(.system(size: 14, weight: .semibold))
                Text("\(group.photos.count)장").font(.system(size: 12)).foregroundColor(.secondary)
                if group.selectedCount > 0 { HStack(spacing: 2) { Image(systemName: "checkmark.circle.fill").font(.system(size: 10)); Text("\(group.selectedCount)").font(.system(size: 11, weight: .medium)) }.foregroundColor(.green) }
                Spacer()
                if let d = group.durationText { Text(d).font(.system(size: 11)).foregroundColor(.secondary) }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 4) { ForEach(group.photos, id: \.id) { timelineThumbnail(photo: $0) } }.padding(.horizontal, 2)
            }.frame(height: 80)
        }.padding(12).background(Color.gray.opacity(0.08)).cornerRadius(8)
    }

    private func timelineThumbnail(photo: PhotoItem) -> some View {
        ZStack(alignment: .bottomLeading) {
            AsyncTimelineThumbnail(url: photo.jpgURL, size: 80)
            HStack(spacing: 2) {
                if photo.isSpacePicked { Circle().fill(Color.red).frame(width: 8, height: 8) }
                StarDisplayView(rating: photo.rating, size: 5)
            }.padding(3)
        }.frame(width: 80, height: 80).cornerRadius(4)
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(store.selectedPhotoID == photo.id ? Color.accentColor : photo.isSpacePicked ? Color.red.opacity(0.6) : Color.clear, lineWidth: store.selectedPhotoID == photo.id ? 3 : 2))
        .onTapGesture { store.selectPhoto(photo.id, cmdKey: false) }
    }
}

struct AsyncTimelineThumbnail: View {
    let url: URL; let size: CGFloat
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image = image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill).frame(width: size, height: size).clipped() }
            else { Rectangle().fill(Color.gray.opacity(0.2)).frame(width: size, height: size) }
        }.onAppear { loadThumb() }
    }
    private func loadThumb() {
        DispatchQueue.global(qos: .utility).async {
            autoreleasepool {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return }
                let opts: [NSString: Any] = [kCGImageSourceThumbnailMaxPixelSize: Int(size * 2), kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true]
                guard let cgImg = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else { return }
                let nsImg = NSImage(cgImage: cgImg, size: NSSize(width: cgImg.width, height: cgImg.height))
                DispatchQueue.main.async { self.image = nsImg }
            }
        }
    }
}

struct TimeGroup: Identifiable {
    let id = UUID(); let startDate: Date; let endDate: Date; let photos: [PhotoItem]; let label: String; let shortLabel: String
    var selectedCount: Int { photos.filter { $0.isSpacePicked }.count }
    var ratedCount: Int { photos.filter { $0.rating > 0 }.count }
    var hasSelections: Bool { selectedCount > 0 }
    var durationText: String? {
        let interval = endDate.timeIntervalSince(startDate); guard interval > 0 else { return nil }
        if interval < 60 { return "\(Int(interval))초" }; if interval < 3600 { return "\(Int(interval / 60))분" }
        return "\(Int(interval / 3600))시간 \(Int((interval.truncatingRemainder(dividingBy: 3600)) / 60))분"
    }
}

struct TimelineBuilder {
    static func build(photos: [PhotoItem], gap: TimeInterval = 300) -> [TimeGroup] {
        var dated: [(photo: PhotoItem, date: Date)] = []
        for p in photos { if let d = p.exifData?.dateTaken { dated.append((p, d)) } }
        guard !dated.isEmpty else { return [] }
        dated.sort { $0.date < $1.date }
        let fmt = DateFormatter(); fmt.locale = Locale(identifier: "ko_KR")
        var groups: [TimeGroup] = []; var cur: [PhotoItem] = [dated[0].photo]; var start = dated[0].date
        for i in 1..<dated.count {
            if dated[i].date.timeIntervalSince(dated[i-1].date) > gap {
                groups.append(makeGroup(photos: cur, start: start, end: dated[i-1].date, fmt: fmt))
                cur = [dated[i].photo]; start = dated[i].date
            } else { cur.append(dated[i].photo) }
        }
        if let lastDate = dated.last?.date {
            groups.append(makeGroup(photos: cur, start: start, end: lastDate, fmt: fmt))
        }
        return groups
    }
    private static func makeGroup(photos: [PhotoItem], start: Date, end: Date, fmt: DateFormatter) -> TimeGroup {
        fmt.dateFormat = "M월 d일 HH:mm"; let label = fmt.string(from: start)
        fmt.dateFormat = "HH:mm"; let short = fmt.string(from: start)
        return TimeGroup(startDate: start, endDate: end, photos: photos, label: label, shortLabel: short)
    }
}
