//
//  VisualSearchCropView.swift
//  PhotoRawManager
//
//  v8.7: "이 얼굴/사물 찾기" 드래그 크롭 선택 UI.
//  사진 위에 오버레이로 떠서 사용자가 드래그해서 영역 지정 → 확인 → 검색 시작.
//

import SwiftUI
import AppKit

struct VisualSearchCropView: View {
    let sourceURL: URL
    let initialMode: VisualSearchMode
    @Binding var isPresented: Bool
    let onConfirmed: (VisualSearchMode, CGRect?, String?) -> Void

    @State private var image: NSImage?
    @State private var mode: VisualSearchMode
    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?
    @State private var normalizedRect: CGRect?  // 0~1
    @State private var label: String = ""

    init(sourceURL: URL, mode: VisualSearchMode, isPresented: Binding<Bool>, onConfirmed: @escaping (VisualSearchMode, CGRect?, String?) -> Void) {
        self.sourceURL = sourceURL
        self.initialMode = mode
        self._isPresented = isPresented
        self.onConfirmed = onConfirmed
        _mode = State(initialValue: mode)
    }

    var body: some View {
        VStack(spacing: 0) {
            // 헤더
            HStack(spacing: 12) {
                Text("검색 기준 선택")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Picker("", selection: $mode) {
                    Text("얼굴").tag(VisualSearchMode.face)
                    Text("사물/장면").tag(VisualSearchMode.object)
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                .help("얼굴: 사람 식별 특화 / 사물: 부케·케이크·배경 등 범용")
            }
            .padding()

            Divider()

            // 이미지 + 드래그 오버레이
            GeometryReader { geo in
                ZStack {
                    Color.black
                    if let img = image {
                        let dispSize = calcDisplaySize(img.size, in: geo.size)
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: dispSize.width, height: dispSize.height)
                            .overlay(
                                dragOverlay(imageDisplaySize: dispSize, containerSize: geo.size)
                            )
                            .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    } else {
                        ProgressView()
                    }
                }
                .contentShape(Rectangle())
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

            Divider()

            // 하단 컨트롤
            HStack(spacing: 12) {
                TextField(placeholderLabel, text: $label)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
                    .help("예: 신부 / 부케 / 웨딩카")

                Spacer()

                Button("영역 초기화") {
                    normalizedRect = nil
                }
                .disabled(normalizedRect == nil)

                Button("취소") {
                    isPresented = false
                }

                Button(normalizedRect != nil ? "이 영역으로 검색" : "전체 사진으로 검색") {
                    onConfirmed(mode, normalizedRect, label.isEmpty ? nil : label)
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(mode == .object && normalizedRect == nil)  // 사물 검색은 크롭 필수
            }
            .padding()
        }
        .frame(minWidth: 620, minHeight: 500)
        .onAppear { loadImage() }
    }

    private var placeholderLabel: String {
        switch mode {
        case .face: return "이름 (예: 신부, 신랑)"
        case .object: return "라벨 (예: 부케, 케이크)"
        }
    }

    @ViewBuilder
    private func dragOverlay(imageDisplaySize: CGSize, containerSize: CGSize) -> some View {
        if let rect = normalizedRect {
            let pixelRect = CGRect(
                x: rect.minX * imageDisplaySize.width,
                y: rect.minY * imageDisplaySize.height,
                width: rect.width * imageDisplaySize.width,
                height: rect.height * imageDisplaySize.height
            )
            Rectangle()
                .stroke(mode == .face ? Color.orange : Color.teal, lineWidth: 2)
                .background(
                    (mode == .face ? Color.orange : Color.teal).opacity(0.15)
                )
                .frame(width: pixelRect.width, height: pixelRect.height)
                .position(x: pixelRect.midX, y: pixelRect.midY)
                .allowsHitTesting(false)
        }
    }

    private func calcDisplaySize(_ original: NSSize, in container: CGSize) -> CGSize {
        guard original.width > 0 && original.height > 0 else { return .zero }
        let scale = min(container.width / original.width, container.height / original.height)
        return CGSize(width: original.width * scale, height: original.height * scale)
    }

    private func loadImage() {
        DispatchQueue.global(qos: .userInitiated).async {
            let img = NSImage(contentsOf: sourceURL) ?? PreviewImageCache.loadOptimized(url: sourceURL, maxPixel: 1200)
            DispatchQueue.main.async {
                self.image = img
            }
        }
    }
}
