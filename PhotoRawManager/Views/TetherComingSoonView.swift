//
//  TetherComingSoonView.swift
//  PhotoRawManager
//
//  Release 빌드에서 테더링 기능이 아직 공개되지 않았을 때 보여주는 플레이스홀더.
//  AppConfig.enableTethering = false 일 때만 표시됨.
//

import SwiftUI

struct TetherComingSoonView: View {
    @EnvironmentObject var store: PhotoStore

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.08, green: 0.06, blue: 0.14),
                    Color(red: 0.04, green: 0.04, blue: 0.10)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()

                // 로고 영역
                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [Color.orange.opacity(0.3), Color.clear],
                                center: .center, startRadius: 10, endRadius: 80
                            )
                        )
                        .frame(width: 160, height: 160)

                    Image(systemName: "cable.connector")
                        .font(.system(size: 56, weight: .light))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.orange, .red],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        )
                }

                VStack(spacing: 8) {
                    Text("테더링")
                        .font(.system(size: 28, weight: .bold, design: .rounded))

                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .foregroundColor(.yellow.opacity(0.9))
                        Text("Coming Soon")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [.orange, .yellow],
                                    startPoint: .leading, endPoint: .trailing
                                )
                            )
                    }
                }

                VStack(alignment: .leading, spacing: 14) {
                    featureRow(
                        icon: "camera.aperture",
                        title: "전문 테더링 촬영",
                        subtitle: "Sony · Canon · Nikon 공식 SDK 기반"
                    )
                    featureRow(
                        icon: "slider.horizontal.below.rectangle",
                        title: "원격 설정 제어",
                        subtitle: "ISO · 조리개 · 셔터 · WB 실시간 변경"
                    )
                    featureRow(
                        icon: "eye.circle",
                        title: "라이브 뷰",
                        subtitle: "HD 실시간 프리뷰 · 초점 확인"
                    )
                    featureRow(
                        icon: "arrow.down.circle.dotted",
                        title: "자동 전송",
                        subtitle: "촬영 즉시 앱으로 입력 + 셀렉 바로 시작"
                    )
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.white.opacity(0.04))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                        )
                )
                .frame(maxWidth: 480)

                Text("곧 찾아뵙겠습니다. 업데이트 공지를 기다려주세요.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary.opacity(0.7))

                Button(action: { store.startupMode = nil }) {
                    Text("돌아가기")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 10)
                        .background(
                            Capsule().fill(Color.white.opacity(0.12))
                        )
                }
                .buttonStyle(.plain)

                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func featureRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundColor(.orange.opacity(0.8))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
    }
}
