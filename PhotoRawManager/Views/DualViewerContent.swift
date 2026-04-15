//
//  DualViewerContent.swift
//  PhotoRawManager
//
//  Extracted from ContentView.swift split.
//

import SwiftUI

struct DualViewerContent: View {
    @EnvironmentObject var store: PhotoStore

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let photo = store.selectedPhoto, !photo.isFolder, !photo.isParentFolder {
                PhotoPreviewView(photo: photo)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "display.2").font(.system(size: 48)).foregroundColor(.gray)
                    Text("메인 뷰어에서 사진을 선택하세요").font(.system(size: 16)).foregroundColor(.gray)
                }
            }
        }
    }
}
