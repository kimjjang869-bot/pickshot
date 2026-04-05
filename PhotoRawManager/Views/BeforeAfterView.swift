import SwiftUI
import AppKit

struct BeforeAfterView: View {
    let beforeImage: NSImage
    let afterImage: NSImage
    let imageSize: CGSize
    @State private var sliderPosition: CGFloat = 0.5
    @State private var isVertical = false

    var body: some View {
        GeometryReader { geo in
            let size = fitSize(imageSize: imageSize, containerSize: geo.size)
            ZStack {
                Image(nsImage: afterImage).resizable().aspectRatio(contentMode: .fit).frame(width: size.width, height: size.height)
                Image(nsImage: beforeImage).resizable().aspectRatio(contentMode: .fit).frame(width: size.width, height: size.height)
                    .clipShape(SliderClipShape(position: sliderPosition, isVertical: isVertical))
                dividerLine(size: size)
                labels(size: size)
            }
            .frame(width: size.width, height: size.height)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                sliderPosition = isVertical ? max(0, min(1, v.location.y / size.height)) : max(0, min(1, v.location.x / size.width))
            })
            .overlay(alignment: .topTrailing) {
                Button(action: { withAnimation(.easeInOut(duration: 0.2)) { isVertical.toggle() } }) {
                    Image(systemName: isVertical ? "arrow.up.arrow.down" : "arrow.left.arrow.right")
                        .font(.system(size: 11)).padding(6).background(.ultraThinMaterial).clipShape(Circle())
                }.buttonStyle(.plain).padding(8)
            }
        }
    }

    @ViewBuilder private func dividerLine(size: CGSize) -> some View {
        if isVertical {
            let y = size.height * sliderPosition
            Rectangle().fill(Color.white).frame(width: size.width, height: 2).shadow(color: .black.opacity(0.5), radius: 2).position(x: size.width / 2, y: y)
            Circle().fill(Color.white).frame(width: 28, height: 28).shadow(color: .black.opacity(0.4), radius: 3)
                .overlay(VStack(spacing: 2) { Image(systemName: "chevron.up").font(.system(size: 8, weight: .bold)); Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)) }.foregroundColor(.gray))
                .position(x: size.width / 2, y: y)
        } else {
            let x = size.width * sliderPosition
            Rectangle().fill(Color.white).frame(width: 2, height: size.height).shadow(color: .black.opacity(0.5), radius: 2).position(x: x, y: size.height / 2)
            Circle().fill(Color.white).frame(width: 28, height: 28).shadow(color: .black.opacity(0.4), radius: 3)
                .overlay(HStack(spacing: 2) { Image(systemName: "chevron.left").font(.system(size: 8, weight: .bold)); Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)) }.foregroundColor(.gray))
                .position(x: x, y: size.height / 2)
        }
    }

    @ViewBuilder private func labels(size: CGSize) -> some View {
        let badge = { (text: String, icon: String) -> AnyView in
            AnyView(HStack(spacing: 3) { Image(systemName: icon).font(.system(size: 9)); Text(text).font(.system(size: 10, weight: .semibold)) }
                .padding(.horizontal, 6).padding(.vertical, 3).background(.ultraThinMaterial).clipShape(RoundedRectangle(cornerRadius: 4)))
        }
        if isVertical {
            VStack { HStack { badge("원본", "photo"); Spacer() }.padding(8).opacity(sliderPosition > 0.05 ? 1 : 0); Spacer()
                HStack { badge("보정", "photo.fill"); Spacer() }.padding(8).opacity(sliderPosition < 0.95 ? 1 : 0) }.frame(width: size.width, height: size.height)
        } else {
            HStack { VStack { badge("원본", "photo"); Spacer() }.padding(8).opacity(sliderPosition > 0.05 ? 1 : 0); Spacer()
                VStack { badge("보정", "photo.fill"); Spacer() }.padding(8).opacity(sliderPosition < 0.95 ? 1 : 0) }.frame(width: size.width, height: size.height)
        }
    }

    private func fitSize(imageSize: CGSize, containerSize: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0 else { return containerSize }
        let scale = min(containerSize.width / imageSize.width, containerSize.height / imageSize.height)
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }
}

struct SliderClipShape: Shape {
    var position: CGFloat; var isVertical: Bool
    var animatableData: CGFloat { get { position } set { position = newValue } }
    func path(in rect: CGRect) -> Path {
        var path = Path()
        if isVertical { path.addRect(CGRect(x: 0, y: 0, width: rect.width, height: rect.height * position)) }
        else { path.addRect(CGRect(x: 0, y: 0, width: rect.width * position, height: rect.height)) }
        return path
    }
}
