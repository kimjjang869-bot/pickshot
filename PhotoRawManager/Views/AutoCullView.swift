import SwiftUI
import AppKit

struct AutoCullView: View {
    @EnvironmentObject var store: PhotoStore
    @Environment(\.dismiss) var dismiss
    @State private var currentIndex: Int = 0
    @State private var image: NSImage?
    @State private var loadWorkItem: DispatchWorkItem?
    @State private var selectedCount: Int = 0
    @State private var skippedCount: Int = 0
    @State private var showAction: String? = nil
    @State private var actionTimer: DispatchWorkItem?

    private var photos: [PhotoItem] { store.filteredPhotos.filter { !$0.isFolder && !$0.isParentFolder } }
    private var currentPhoto: PhotoItem? { currentIndex >= 0 && currentIndex < photos.count ? photos[currentIndex] : nil }
    private var progress: Double { photos.isEmpty ? 0 : Double(currentIndex) / Double(photos.count) }
    private var isComplete: Bool { currentIndex >= photos.count }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if isComplete { completionView }
            else if let photo = currentPhoto {
                if let image = image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(maxWidth: .infinity, maxHeight: .infinity) }
                if photo.isSpacePicked { Rectangle().stroke(Color.red, lineWidth: 6).ignoresSafeArea() }
                if let action = showAction { actionFeedback(action) }
                VStack { topBar(photo: photo); Spacer(); bottomBar(photo: photo) }
            }
        }.frame(minWidth: 800, minHeight: 600)
        .onAppear {
            if let id = store.selectedPhotoID, let idx = photos.firstIndex(where: { $0.id == id }) { currentIndex = idx }
            loadCurrentImage()
        }
        .background(KeyCullEventHandler(onSelect: selectAndNext, onSkip: skipAndNext, onBack: goBack, onRate: setRating, onExit: { dismiss() }))
    }

    private func topBar(photo: PhotoItem) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(currentIndex + 1) / \(photos.count)").font(.system(size: 14, weight: .bold, design: .monospaced)).foregroundColor(.white)
                GeometryReader { geo in ZStack(alignment: .leading) { RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.2)); RoundedRectangle(cornerRadius: 2).fill(Color.accentColor).frame(width: geo.size.width * CGFloat(progress)) } }.frame(width: 200, height: 4)
            }
            Spacer()
            HStack(spacing: 16) {
                HStack(spacing: 4) { Image(systemName: "checkmark.circle.fill").foregroundColor(.green); Text("\(selectedCount)").font(.system(size: 13, weight: .medium, design: .monospaced)).foregroundColor(.green) }
                HStack(spacing: 4) { Image(systemName: "forward.fill").foregroundColor(.gray); Text("\(skippedCount)").font(.system(size: 13, weight: .medium, design: .monospaced)).foregroundColor(.gray) }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(photo.fileName).font(.system(size: 12, weight: .medium)).foregroundColor(.white.opacity(0.8)).lineLimit(1)
                if let q = photo.quality, q.isAnalyzed {
                    HStack(spacing: 4) { Circle().fill(q.overallGrade == .good ? Color.green : q.overallGrade == .average ? Color.orange : Color.red).frame(width: 8, height: 8)
                        Text("\(q.score)점").font(.system(size: 11, weight: .medium)).foregroundColor(.white.opacity(0.7)) }
                }
            }
            Button(action: { dismiss() }) { Image(systemName: "xmark.circle.fill").font(.system(size: 20)).foregroundColor(.white.opacity(0.6)) }.buttonStyle(.plain).padding(.leading, 12)
        }.padding(.horizontal, 20).padding(.top, 12)
    }

    private func bottomBar(photo: PhotoItem) -> some View {
        HStack(spacing: 24) {
            VStack(spacing: 2) { Image(systemName: "arrow.left").font(.system(size: 18)); Text("뒤로").font(.system(size: 10)) }.foregroundColor(.white.opacity(0.5)).onTapGesture { goBack() }
            Spacer()
            if let q = photo.quality, !q.gradingIssues.isEmpty {
                HStack(spacing: 6) { ForEach(q.gradingIssues.prefix(3)) { issue in HStack(spacing: 3) { Image(systemName: issue.severity.icon).font(.system(size: 10)).foregroundColor(issue.severity == .bad ? .red : .orange); Text(issue.message).font(.system(size: 10)).foregroundColor(.white.opacity(0.7)).lineLimit(1) } } }
            }
            Spacer()
            VStack(spacing: 2) { Image(systemName: "forward.fill").font(.system(size: 22)); Text("건너뛰기 →").font(.system(size: 10)) }.foregroundColor(.white.opacity(0.7)).onTapGesture { skipAndNext() }
            VStack(spacing: 2) { Image(systemName: "checkmark.circle.fill").font(.system(size: 28)); Text("선택 (Space)").font(.system(size: 10)) }.foregroundColor(.green).onTapGesture { selectAndNext() }
        }.padding(.horizontal, 24).padding(.bottom, 16)
    }

    private func actionFeedback(_ action: String) -> some View {
        VStack { Spacer(); HStack { Spacer()
            if action == "select" { Image(systemName: "checkmark.circle.fill").font(.system(size: 60)).foregroundColor(.green) }
            else { Image(systemName: "forward.fill").font(.system(size: 50)).foregroundColor(.gray) }
            Spacer() }; Spacer() }.allowsHitTesting(false)
    }

    private var completionView: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 48)).foregroundColor(.green)
            Text("컬링 완료!").font(.system(size: 24, weight: .bold)).foregroundColor(.white)
            HStack(spacing: 30) {
                VStack(spacing: 4) { Text("\(photos.count)").font(.system(size: 28, weight: .bold, design: .rounded)).foregroundColor(.white); Text("전체").font(.system(size: 13)).foregroundColor(.white.opacity(0.6)) }
                VStack(spacing: 4) { Text("\(selectedCount)").font(.system(size: 28, weight: .bold, design: .rounded)).foregroundColor(.green); Text("선택").font(.system(size: 13)).foregroundColor(.white.opacity(0.6)) }
                VStack(spacing: 4) { Text("\(skippedCount)").font(.system(size: 28, weight: .bold, design: .rounded)).foregroundColor(.gray); Text("건너뜀").font(.system(size: 13)).foregroundColor(.white.opacity(0.6)) }
            }
            Button("닫기") { dismiss() }.keyboardShortcut(.escape)
        }
    }

    private func selectAndNext() {
        guard let photo = currentPhoto else { return }
        // v9.1.4 (perf P3): firstIndex(where:) O(N) → _photoIndex O(1).
        //   이전엔 store.photos[idx].isSpacePicked = true 직접 변형 → didSet 폭탄 (rebuildIndex + invalidateFilterCache).
        if let idx = store._photoIndex[photo.id], idx < store.photos.count {
            store.photos[idx].isSpacePicked = true
        }
        selectedCount += 1; showFeedback("select"); advance()
    }
    private func skipAndNext() { skippedCount += 1; showFeedback("skip"); advance() }
    private func goBack() { guard currentIndex > 0 else { return }; currentIndex -= 1; loadCurrentImage(); if let p = currentPhoto { store.selectedPhotoID = p.id } }
    private func setRating(_ r: Int) { guard let p = currentPhoto else { return }; store.setRating(r, for: p.id) }
    private func advance() { currentIndex += 1; if !isComplete { loadCurrentImage(); if let p = currentPhoto { store.selectedPhotoID = p.id } } }

    private func showFeedback(_ action: String) {
        actionTimer?.cancel()
        withAnimation(.easeIn(duration: 0.15)) { showAction = action }
        let work = DispatchWorkItem { withAnimation(.easeOut(duration: 0.2)) { self.showAction = nil } }
        actionTimer = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func loadCurrentImage() {
        loadWorkItem?.cancel()
        guard let photo = currentPhoto else { return }
        let url = photo.jpgURL
        let work = DispatchWorkItem {
            autoreleasepool {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return }
                let opts: [NSString: Any] = [kCGImageSourceThumbnailMaxPixelSize: 2400, kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true]
                guard let cgImg = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else { return }
                let nsImg = NSImage(cgImage: cgImg, size: NSSize(width: cgImg.width, height: cgImg.height))
                DispatchQueue.main.async { self.image = nsImg }
            }
        }
        loadWorkItem = work; DispatchQueue.global(qos: .userInitiated).async(execute: work)
    }
}

struct KeyCullEventHandler: NSViewRepresentable {
    let onSelect: () -> Void; let onSkip: () -> Void; let onBack: () -> Void; let onRate: (Int) -> Void; let onExit: () -> Void
    func makeNSView(context: Context) -> KeyCullCaptureView {
        let v = KeyCullCaptureView(); v.onSelect = onSelect; v.onSkip = onSkip; v.onBack = onBack; v.onRate = onRate; v.onExit = onExit
        DispatchQueue.main.async { v.window?.makeFirstResponder(v) }; return v
    }
    func updateNSView(_ v: KeyCullCaptureView, context: Context) { v.onSelect = onSelect; v.onSkip = onSkip; v.onBack = onBack; v.onRate = onRate; v.onExit = onExit }
}

class KeyCullCaptureView: NSView {
    var onSelect: (() -> Void)?; var onSkip: (() -> Void)?; var onBack: (() -> Void)?; var onRate: ((Int) -> Void)?; var onExit: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49: onSelect?(); case 124: onSkip?(); case 123: onBack?(); case 53: onExit?()
        case 18: onRate?(1); case 19: onRate?(2); case 20: onRate?(3); case 21: onRate?(4); case 23: onRate?(5)
        default: super.keyDown(with: event)
        }
    }
}
