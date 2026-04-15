//
//  DragHandle.swift
//  PhotoRawManager
//
//  Extracted from ContentView+SupportingViews.swift split.
//

import SwiftUI
import AppKit

// MARK: - Drag Handle

enum DragAxis {
    case horizontal, vertical
}

struct DragHandle: View {
    let axis: DragAxis
    @State private var isHovered = false

    var body: some View {
        Group {
            if axis == .horizontal {
                // Vertical divider (thin line + wide hit area)
                ZStack {
                    // Thin visible line
                    Rectangle()
                        .fill(isHovered ? Color.accentColor.opacity(0.3) : Color.gray.opacity(0.15))
                        .frame(width: 1)

                    // Grab handle (center)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(isHovered ? Color.accentColor : Color.gray.opacity(0.4))
                        .frame(width: 4, height: 40)
                }
                .frame(width: 14)  // Wide hit area for easy grabbing
                .contentShape(Rectangle())
                .onHover { isHovered = $0 }
                .cursor(.resizeLeftRight)
            } else {
                // Horizontal divider (thin line + tall hit area)
                ZStack {
                    // Thin visible line
                    Rectangle()
                        .fill(isHovered ? Color.accentColor.opacity(0.3) : Color.gray.opacity(0.15))
                        .frame(height: 1)

                    // Grab handle (center)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(isHovered ? Color.accentColor : Color.gray.opacity(0.4))
                        .frame(width: 40, height: 4)
                }
                .frame(height: 14)  // Tall hit area for easy grabbing
                .contentShape(Rectangle())
                .onHover { isHovered = $0 }
                .cursor(.resizeUpDown)
            }
        }
    }
}
