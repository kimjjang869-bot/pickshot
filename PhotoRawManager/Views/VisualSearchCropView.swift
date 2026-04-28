//
//  VisualSearchCropView.swift
//  PhotoRawManager
//
//  v8.7: "이 얼굴/사물 찾기" 드래그 크롭 선택 UI (멀티샷 수집 지원).
//  사용 흐름:
//   1) 첫 이미지에서 영역 드래그 → "샷 추가" → 하단 스트립에 누적
//   2) "다른 사진 추가" → NSOpenPanel 로 다른 사진 선택 → 다시 드래그
//   3) 정면/옆/뒷면 샷 모아서 → "검색 시작"
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Vision

struct VisualSearchCropShot: Identifiable {
    let id = UUID()
    let url: URL
    let rect: CGRect?  // nil = 전체 이미지
}

struct VisualSearchCropView: View {
    let sourceURL: URL
    let initialMode: VisualSearchMode
    let presetLabel: String?
    let folderPhotos: [URL]  // v8.7: 앱 내 사진 피커 (현재 폴더)
    let onClose: () -> Void  // 창 닫기 콜백 (NSWindow 제어)
    /// 콜백: (mode, 수집된 샷들, label) — 한번에 여러 레퍼런스 등록
    let onConfirmedMulti: (VisualSearchMode, [VisualSearchCropShot], String?) -> Void

    @State private var currentURL: URL
    @State private var image: NSImage?
    @State private var mode: VisualSearchMode
    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?
    @State private var normalizedRect: CGRect?  // 0~1
    @State private var label: String = ""
    @State private var collectedShots: [VisualSearchCropShot] = []

    init(
        sourceURL: URL,
        mode: VisualSearchMode,
        presetLabel: String? = nil,
        folderPhotos: [URL] = [],
        onClose: @escaping () -> Void,
        onConfirmedMulti: @escaping (VisualSearchMode, [VisualSearchCropShot], String?) -> Void
    ) {
        self.sourceURL = sourceURL
        self.initialMode = mode
        self.presetLabel = presetLabel
        self.folderPhotos = folderPhotos
        self.onClose = onClose
        self.onConfirmedMulti = onConfirmedMulti
        _currentURL = State(initialValue: sourceURL)
        _mode = State(initialValue: mode)
        _label = State(initialValue: presetLabel ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            // 헤더
            HStack(spacing: 12) {
                Text("검색 기준 선택")
                    .font(.system(size: 15, weight: .semibold))
                Text("— 정면/옆면/뒷면 여러 샷 등록 가능")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                Picker("", selection: $mode) {
                    Text("얼굴").tag(VisualSearchMode.face)
                    Text("사물/장면").tag(VisualSearchMode.object)
                    Text("같은 옷").tag(VisualSearchMode.clothing)
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
                .help("얼굴: 사람 식별 / 사물: 부케·케이크·배경 / 같은 옷: 상체 CLIP 매칭")
            }
            .padding()

            Divider()

            HStack(spacing: 0) {
            // 이미지 + 드래그 오버레이 (썸네일 뷰에서 드래그&드롭으로 샷 추가 가능)
            GeometryReader { geo in
                ZStack {
                    Color.black
                    if let img = image {
                        let dispSize = calcDisplaySize(img.size, in: geo.size)
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: dispSize.width, height: dispSize.height)
                            .overlay(dragOverlay(imageDisplaySize: dispSize))
                            .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    } else {
                        ProgressView()
                    }
                }
                .contentShape(Rectangle())
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    // 썸네일 뷰에서 드래그된 파일 URL 수신
                    guard let provider = providers.first else { return false }
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        guard let url = url else { return }
                        DispatchQueue.main.async { handleDroppedURL(url) }
                    }
                    return true
                }
                .gesture(
                    DragGesture(minimumDistance: 5)
                        .onChanged { value in
                            let dispSize = calcDisplaySize(image?.size ?? .zero, in: geo.size)
                            let offsetX = (geo.size.width - dispSize.width) / 2
                            let offsetY = (geo.size.height - dispSize.height) / 2
                            let start = CGPoint(
                                x: max(0, min(dispSize.width, value.startLocation.x - offsetX)),
                                y: max(0, min(dispSize.height, value.startLocation.y - offsetY))
                            )
                            let cur = CGPoint(
                                x: max(0, min(dispSize.width, value.location.x - offsetX)),
                                y: max(0, min(dispSize.height, value.location.y - offsetY))
                            )
                            dragStart = start
                            dragCurrent = cur
                            if dispSize.width > 0 && dispSize.height > 0 {
                                normalizedRect = CGRect(
                                    x: min(start.x, cur.x) / dispSize.width,
                                    y: min(start.y, cur.y) / dispSize.height,
                                    width: abs(cur.x - start.x) / dispSize.width,
                                    height: abs(cur.y - start.y) / dispSize.height
                                )
                            }
                        }
                        .onEnded { _ in
                            dragStart = nil
                            dragCurrent = nil
                        }
                )
            }
            } // HStack 끝 (좌측 피커 + 메인)

            Divider()

            // 수집된 샷 스트립 — 클릭: 해당 샷 재표시 / X: 삭제 / 작은 박스: 선택된 얼굴 영역
            if !collectedShots.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(collectedShots) { shot in
                            CollectedShotCell(
                                shot: shot,
                                mode: mode,
                                isCurrent: shot.url == currentURL && shot.rect == normalizedRect,
                                onSelect: {
                                    // 해당 샷 메인 뷰에 재표시
                                    currentURL = shot.url
                                    normalizedRect = shot.rect
                                    image = nil
                                    loadImage()
                                },
                                onDelete: {
                                    collectedShots.removeAll { $0.id == shot.id }
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .background(Color.black.opacity(0.2))
                Divider()
            }

            // 하단 컨트롤
            HStack(spacing: 12) {
                TextField(placeholderLabel, text: $label)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 180)
                    .help("예: 신부 / 부케 / 웨딩카")

                // 샷 추가 (현재 영역을 수집 스트립에 추가)
                Button(action: addCurrentShot) {
                    Label("샷 추가", systemImage: "plus.circle")
                }
                .disabled(normalizedRect == nil && mode == .object)
                .help("현재 영역을 정면/옆/뒷면 샷 중 하나로 추가")

                // 자동 얼굴 감지 — 얼굴 모드에서만 의미
                if mode == .face {
                    Button(action: autoDetectFace) {
                        Label("자동 얼굴 감지", systemImage: "face.smiling")
                    }
                    .help("현재 사진에서 가장 큰 얼굴을 찾아 박스 자동 표시")
                }

                Spacer()

                Button("영역 초기화") {
                    normalizedRect = nil
                }
                .disabled(normalizedRect == nil)

                Button("취소") {
                    onClose()
                }

                Button(confirmButtonTitle) {
                    confirmAndSearch()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canConfirm)
            }
            .padding()
        }
        .frame(minWidth: 720, minHeight: 540)
        .onAppear { loadImage() }
    }

    private var placeholderLabel: String {
        switch mode {
        case .face: return "이름 (예: 우리 아이, 신부)"
        case .object: return "라벨 (예: 부케, 에펠탑)"
        case .clothing: return "의상 라벨 (예: 파란 셔츠, 신랑 턱시도)"
        }
    }

    private var canConfirm: Bool {
        // 수집된 샷이 있거나, 현재 영역이 선택된 상태 (object 는 영역 필수)
        if !collectedShots.isEmpty { return true }
        if mode == .object { return normalizedRect != nil }
        return true  // face / clothing 은 전체 사진도 허용 (자동 torso 검출)
    }

    private var confirmButtonTitle: String {
        // 수집된 샷 개수를 정확히 표시. 현재 미수집 영역은 별도 표기.
        if !collectedShots.isEmpty {
            return "검색 시작 (\(collectedShots.count)장)"
        } else {
            return normalizedRect != nil ? "이 영역으로 검색" : "전체 사진으로 검색"
        }
    }

    @ViewBuilder
    private func dragOverlay(imageDisplaySize: CGSize) -> some View {
        if let rect = normalizedRect {
            let pixelRect = CGRect(
                x: rect.minX * imageDisplaySize.width,
                y: rect.minY * imageDisplaySize.height,
                width: rect.width * imageDisplaySize.width,
                height: rect.height * imageDisplaySize.height
            )
            // 박스 + 상단 우측 X 삭제 버튼
            ZStack {
                Rectangle()
                    .stroke(mode == .face ? Color.orange : Color.teal, lineWidth: 2)
                    .background(
                        (mode == .face ? Color.orange : Color.teal).opacity(0.15)
                    )
                    .allowsHitTesting(false)

                // X 버튼 — 박스 우측 상단에 위치. hit testing 활성.
                Button(action: { normalizedRect = nil }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.white)
                        .shadow(color: .black.opacity(0.6), radius: 3)
                }
                .buttonStyle(.plain)
                .help("박스 제거")
                .position(x: pixelRect.width - 10, y: 10)
            }
            .frame(width: pixelRect.width, height: pixelRect.height)
            .position(x: pixelRect.midX, y: pixelRect.midY)
        }
    }

    /// 자동 얼굴 감지 — 현재 이미지에서 가장 큰 얼굴을 찾아 normalizedRect 에 설정
    private func autoDetectFace() {
        guard let img = image,
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let req = VNDetectFaceRectanglesRequest()
            if #available(macOS 13.0, *) {
                req.revision = VNDetectFaceRectanglesRequestRevision3
            }
            let handler = VNImageRequestHandler(cgImage: cg, options: [:])
            try? handler.perform([req])
            let faces = (req.results ?? []).filter { $0.confidence > 0.5 }
            // 가장 큰 얼굴
            let best = faces.max { a, b in
                (a.boundingBox.width * a.boundingBox.height) < (b.boundingBox.width * b.boundingBox.height)
            }
            DispatchQueue.main.async {
                guard let face = best else {
                    NSSound.beep()
                    return
                }
                // Vision 좌표계는 좌하단 원점 → 좌상단 원점으로 변환
                let bb = face.boundingBox
                // 20% 패딩 추가해서 얼굴보다 약간 넓게 (턱/머리 포함)
                let padding: CGFloat = 0.15
                var padded = CGRect(
                    x: max(0, bb.minX - bb.width * padding),
                    y: max(0, (1.0 - bb.maxY) - bb.height * padding),  // y-flip
                    width: min(1.0, bb.width * (1 + 2 * padding)),
                    height: min(1.0, bb.height * (1 + 2 * padding))
                )
                padded = padded.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                normalizedRect = padded
            }
        }
    }

    private func calcDisplaySize(_ original: NSSize, in container: CGSize) -> CGSize {
        guard original.width > 0 && original.height > 0 else { return .zero }
        let scale = min(container.width / original.width, container.height / original.height)
        return CGSize(width: original.width * scale, height: original.height * scale)
    }

    private func loadImage() {
        DispatchQueue.global(qos: .userInitiated).async { [currentURL] in
            let img = NSImage(contentsOf: currentURL) ?? PreviewImageCache.loadOptimized(url: currentURL, maxPixel: 1200)
            DispatchQueue.main.async {
                self.image = img
                // v8.7: 얼굴 모드에서 이미지 로드되면 자동 얼굴 감지 (박스 자동 표시)
                //       이미 영역이 수동 지정돼 있으면 덮어쓰지 않음
                if self.mode == .face && self.normalizedRect == nil && img != nil {
                    self.autoDetectFace()
                }
            }
        }
    }

    private func shotPreviewImage(_ shot: VisualSearchCropShot) -> NSImage? {
        guard let cg = VisualSearchService.loadCroppedCGImage(url: shot.url, rect: shot.rect, maxPixel: 120) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private func addCurrentShot() {
        let shot = VisualSearchCropShot(url: currentURL, rect: normalizedRect)
        collectedShots.append(shot)
        normalizedRect = nil  // 다음 샷 위해 영역 리셋
    }

    /// 썸네일 뷰에서 드래그&드롭 = 즉시 샷 추가 (전체 이미지 기준) + 메인 뷰로 전환.
    /// 사용자가 구체적 영역을 지정하고 싶으면 드롭 후 영역 드래그 → "샷 추가" 로 region 샷 별도 추가.
    private func handleDroppedURL(_ url: URL) {
        // 현재 영역이 있으면 먼저 해당 샷도 수집 (잃지 않도록)
        if normalizedRect != nil {
            addCurrentShot()
        }
        // 드롭된 사진을 전체 이미지 기준 샷으로 즉시 추가 (중복 방지)
        if !collectedShots.contains(where: { $0.url == url && $0.rect == nil }) {
            collectedShots.append(VisualSearchCropShot(url: url, rect: nil))
        }
        // 메인 뷰 전환 — 영역 추가로 세분화 원할 때 사용
        currentURL = url
        image = nil
        normalizedRect = nil
        loadImage()
    }

    /// 썸네일용 — 전체 이미지 (크롭 안함)
    private func shotFullImage(_ shot: VisualSearchCropShot) -> NSImage? {
        guard let cg = VisualSearchService.loadCroppedCGImage(url: shot.url, rect: nil, maxPixel: 200) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private func confirmAndSearch() {
        // 수집된 샷이 없을 때만 현재 상태로 1개 추가
        if collectedShots.isEmpty {
            if normalizedRect != nil {
                addCurrentShot()
            } else if mode == .face {
                // face 모드에서 영역 없이 확인 → 전체 이미지 1샷으로 등록
                collectedShots.append(VisualSearchCropShot(url: currentURL, rect: nil))
            }
        }
        // 샷이 이미 수집돼 있으면 현재 영역은 무시 — "샷 추가" 버튼을 명시적으로 눌러야 포함
        onConfirmedMulti(mode, collectedShots, label.isEmpty ? nil : label)
        onClose()
    }
}

// MARK: - 수집된 샷 셀 (클릭 재표시 + 선택 영역 박스 + 삭제)

struct CollectedShotCell: View {
    let shot: VisualSearchCropShot
    let mode: VisualSearchMode
    let isCurrent: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    @State private var fullImage: NSImage?

    private var strokeColor: Color { mode == .face ? .orange : .teal }

    var body: some View {
        // 클릭 영역(썸네일 전체) + 상단우측 삭제 버튼. ZStack + onTapGesture 로 Button 중첩 이슈 회피.
        ZStack(alignment: .topTrailing) {
            thumbnailContent
                .frame(width: 72, height: 54)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isCurrent ? Color.accentColor : strokeColor.opacity(0.5), lineWidth: isCurrent ? 2.5 : 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6))
                .onTapGesture { onSelect() }

            // 삭제 버튼 — Button 하나만 (중첩 없음)
            Button(action: onDelete) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white)
                    .background(Circle().fill(Color.red).frame(width: 16, height: 16))
                    .shadow(color: .black.opacity(0.5), radius: 2)
            }
            .buttonStyle(.plain)
            .help("이 샷 삭제")
            .offset(x: 8, y: -8)
        }
        .padding(.trailing, 4)  // 삭제 버튼 overflow 공간
        .padding(.top, 4)
        .onAppear { loadThumbIfNeeded() }
    }

    @ViewBuilder
    private var thumbnailContent: some View {
        if let img = fullImage {
            GeometryReader { geo in
                // v8.7 fix: aspectRatio(.fit) 로 원본 비율 유지 → 박스 좌표가 정확하게 일치
                let imgAspect = img.size.width / max(img.size.height, 0.01)
                let containerAspect = geo.size.width / max(geo.size.height, 0.01)
                let displaySize: CGSize = {
                    if imgAspect > containerAspect {
                        // 이미지가 더 넓음 → 너비 맞춤
                        return CGSize(width: geo.size.width, height: geo.size.width / imgAspect)
                    } else {
                        return CGSize(width: geo.size.height * imgAspect, height: geo.size.height)
                    }
                }()
                let offsetX = (geo.size.width - displaySize.width) / 2
                let offsetY = (geo.size.height - displaySize.height) / 2

                ZStack {
                    Color.black.opacity(0.3)
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: displaySize.width, height: displaySize.height)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)

                    if let rect = shot.rect {
                        let x = offsetX + rect.minX * displaySize.width
                        let y = offsetY + rect.minY * displaySize.height
                        let w = rect.width * displaySize.width
                        let h = rect.height * displaySize.height
                        Rectangle()
                            .stroke(strokeColor, lineWidth: 1.5)
                            .frame(width: w, height: h)
                            .position(x: x + w/2, y: y + h/2)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        } else {
            Rectangle()
                .fill(Color.gray.opacity(0.2))
                .overlay(ProgressView().scaleEffect(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func loadThumbIfNeeded() {
        if fullImage != nil { return }
        // 1) 메모리 썸네일 캐시
        if let t = ThumbnailCache.shared.get(shot.url) {
            fullImage = t
            return
        }
        // 2) 디스크 썸네일 캐시
        if let d = DiskThumbnailCache.shared.getByPath(url: shot.url) {
            fullImage = d
            return
        }
        // 3) 백그라운드 로드
        DispatchQueue.global(qos: .userInitiated).async {
            let cg = VisualSearchService.loadCroppedCGImage(url: shot.url, rect: nil, maxPixel: 240)
            let ns = cg.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
            let fallback = ns ?? PreviewImageCache.loadOptimized(url: shot.url, maxPixel: 240)
            DispatchQueue.main.async {
                fullImage = fallback
                fputs("[VS] CollectedShotCell loaded \(shot.url.lastPathComponent): \(fallback != nil ? "OK" : "FAIL")\n", stderr)
            }
        }
    }
}

