//
//  SelectionInfoBadge.swift
//  PhotoRawManager
//
//  Extracted from ContentView+SupportingViews.swift split.
//

import SwiftUI

// MARK: - Selection Info Badge

struct SelectionInfoBadge: View {
    @ObservedObject var store: PhotoStore

    var body: some View {
        let selected = store.multiSelectedPhotos
        let total = selected.count
        let ratingCounts = (1...5).map { r in selected.filter { $0.rating == r }.count }
        let unrated = selected.filter { $0.rating == 0 }.count

        HStack(spacing: 6) {
            Text("\(total)장 선택")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white)

            if total > 0 {
                Divider().frame(height: 12).background(Color.white.opacity(0.3))

                // Rating breakdown
                ForEach(1...5, id: \.self) { star in
                    if ratingCounts[star - 1] > 0 {
                        HStack(spacing: 1) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 7))
                                .foregroundColor(.yellow)
                            Text("\(star):")
                                .font(.system(size: 9))
                                .foregroundColor(.white.opacity(0.7))
                            Text("\(ratingCounts[star - 1])")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.white)
                        }
                    }
                }

                if unrated > 0 {
                    HStack(spacing: 1) {
                        Text("미분류:")
                            .font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.7))
                        Text("\(unrated)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(AppTheme.accent)
        .cornerRadius(5)
    }
}
