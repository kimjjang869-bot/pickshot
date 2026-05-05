#!/bin/bash
# release.sh — PickShot 통합 배포 스크립트
#
# 사용법:
#   ./scripts/release.sh <버전> [release_notes_file]
#   예) ./scripts/release.sh 9.1.5 /tmp/release_notes.md
#
# 단계:
#   1. xcodebuild archive (Release, arm64, ad-hoc)
#   2. bundle_dylibs.sh — libraw / libomp / libjpeg / liblcms2 동봉 + @rpath
#   3. Developer ID Application 으로 deep + runtime + timestamp 재서명
#   4. DMG 생성 (UDZO)
#   5. xcrun notarytool submit --wait
#   6. xcrun stapler staple
#   7. git tag + push (이미 있으면 skip)
#   8. gh release create / upload --clobber
#
# 사전 준비:
#   - notarytool keychain profile "pickshot-notary" 등록 필요:
#     xcrun notarytool store-credentials "pickshot-notary" \
#       --apple-id kimjjang869@gmail.com --team-id 322DLHS5T8
#     (한 번만 실행 → app-specific password 가 macOS 키체인에 안전 저장)
#   - gh CLI 인증 완료
#   - Developer ID Application 인증서 keychain 에 있음 (Kwangho Kim, Team 322DLHS5T8)

set -eu
# pipefail 은 의도적으로 비활성 — `... | tail -N` 에서 tail 이 SIGPIPE 받으면 전체 실패하던 문제 차단.
# 각 단계 결과 검증은 if/grep 으로 명시적으로 처리.

VERSION="${1:-}"
NOTES_FILE="${2:-}"

if [ -z "$VERSION" ]; then
    echo "Usage: $0 <version> [release_notes_file]"
    echo "예: $0 9.1.5 /tmp/release_notes.md"
    exit 1
fi

# ── 설정 (환경에 맞게 수정) ─────────────────────────────────
APPLE_ID="kimjjang869@gmail.com"
TEAM_ID="322DLHS5T8"
SIGN_IDENTITY="Developer ID Application: Kwangho Kim ($TEAM_ID)"
GH_REPO="kimjjang869-bot/pickshot"
NOTARY_PROFILE="${NOTARY_PROFILE:-pickshot-notary}"  # 키체인 프로파일 이름 — store-credentials 로 등록

# ── 경로 ───────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ARCHIVE_DIR="/tmp/pickshot_archive_$VERSION"
DMG_STAGE_DIR="/tmp/pickshot_dmg_stage_$VERSION"
APP_PATH="$ARCHIVE_DIR/PickShot.xcarchive/Products/Applications/PickShot.app"
DMG_PATH="/tmp/PickShot-$VERSION.dmg"
ENTITLEMENTS="$PROJECT_DIR/PhotoRawManager/PhotoRawManager.entitlements"

cd "$PROJECT_DIR"

# v9.1.4: 동일 볼륨명 마운트 잔존 시 hdiutil create 실패 차단.
detach_existing_mounts() {
    hdiutil info | awk -v vol="PickShot $VERSION" '$0 ~ vol {print prev} {prev=$1}' \
        | grep -E "^/dev/disk" | sort -u | while read -r dev; do
        hdiutil detach "$dev" -force >/dev/null 2>&1 || true
    done
}

# 종료 시 stage / archive 정리 (실패 시 디스크 점유 차단).
cleanup() {
    local rc=$?
    [ -d "$DMG_STAGE_DIR" ] && rm -rf "$DMG_STAGE_DIR" 2>/dev/null || true
    detach_existing_mounts
    if [ $rc -ne 0 ]; then
        echo ""
        echo "❌ 배포 실패 (exit $rc) — 부분 산출물 정리됨."
        # 실패한 DMG 는 다음 stapler 가 죽은 파일 사용 못 하게 제거.
        [ -f "$DMG_PATH" ] && rm -f "$DMG_PATH" 2>/dev/null || true
    fi
}
trap cleanup EXIT

echo ""
echo "════════════════════════════════════════════════════════════"
echo "  PickShot v$VERSION 통합 배포"
echo "════════════════════════════════════════════════════════════"
echo ""

# ── 1) Archive ──────────────────────────────────────────
echo "📦 [1/8] Release archive 빌드 (arm64, ad-hoc)..."
rm -rf "$ARCHIVE_DIR"
xcodebuild -project PhotoRawManager.xcodeproj -scheme PhotoRawManager \
    -configuration Release \
    -archivePath "$ARCHIVE_DIR/PickShot.xcarchive" archive \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=NO 2>&1 | tail -5

if [ ! -d "$APP_PATH" ]; then
    echo "❌ Archive 실패: $APP_PATH 없음"
    exit 1
fi
echo "✅ Archive 완료: $APP_PATH"

# ── 2) bundle_dylibs ────────────────────────────────────
echo ""
echo "📦 [2/8] dylib 동봉 (libraw, libomp, libjpeg, liblcms2)..."
bash "$SCRIPT_DIR/bundle_dylibs.sh" "$APP_PATH" 2>&1 | tail -5
echo "✅ dylib 동봉 완료"

# ── 3) Developer ID 재서명 ───────────────────────────────
echo ""
echo "✍️  [3/8] Developer ID Application 으로 재서명..."
codesign --deep --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$SIGN_IDENTITY" \
    "$APP_PATH" 2>&1 | tail -3
codesign --verify --deep --strict --verbose=2 "$APP_PATH" 2>&1 | tail -2
echo "✅ 서명 완료"

# ── 4) DMG 생성 ─────────────────────────────────────────
echo ""
echo "💿 [4/8] DMG 생성..."
detach_existing_mounts  # 같은 볼륨명 잔존 시 detach (재배포 안전)
rm -rf "$DMG_STAGE_DIR"
mkdir -p "$DMG_STAGE_DIR"
cp -R "$APP_PATH" "$DMG_STAGE_DIR/"
ln -sfn /Applications "$DMG_STAGE_DIR/Applications"
rm -f "$DMG_PATH"
hdiutil create -volname "PickShot $VERSION" -srcfolder "$DMG_STAGE_DIR" \
    -ov -format UDZO "$DMG_PATH" 2>&1 | tail -3
DMG_SIZE=$(ls -lh "$DMG_PATH" | awk '{print $5}')
echo "✅ DMG: $DMG_PATH ($DMG_SIZE)"

# ── 5) Notarize ────────────────────────────────────────
echo ""
echo "🍎 [5/8] Apple notary 제출 (대기 5~10분)..."
xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait 2>&1 | tee /tmp/notary_$VERSION.log

if ! grep -q "status: Accepted" /tmp/notary_$VERSION.log; then
    echo "❌ Notarization 실패. 로그 확인: /tmp/notary_$VERSION.log"
    SUB_ID=$(grep -m1 "id:" /tmp/notary_$VERSION.log | awk '{print $2}')
    if [ -n "$SUB_ID" ]; then
        echo "상세 로그:"
        xcrun notarytool log "$SUB_ID" --keychain-profile "$NOTARY_PROFILE"
    fi
    exit 1
fi
echo "✅ Notarization Accepted"

# ── 6) Stapler ─────────────────────────────────────────
echo ""
echo "📎 [6/8] 공증 티켓 부착..."
xcrun stapler staple "$DMG_PATH" 2>&1 | tail -2
xcrun stapler validate "$DMG_PATH" 2>&1 | tail -1
echo "✅ Staple 완료"

# ── 7) Git tag ──────────────────────────────────────────
echo ""
echo "🏷  [7/8] Git tag v$VERSION..."
if git rev-parse "v$VERSION" >/dev/null 2>&1; then
    echo "(tag v$VERSION 이미 존재 — skip)"
else
    git tag "v$VERSION"
    git push origin "v$VERSION" 2>&1 | tail -2
    echo "✅ tag push 완료"
fi

# ── 8) GitHub Release ──────────────────────────────────
echo ""
echo "🚀 [8/8] GitHub Release 업로드..."
if gh release view "v$VERSION" --repo "$GH_REPO" >/dev/null 2>&1; then
    echo "(release v$VERSION 이미 존재 — DMG 만 교체)"
    gh release upload "v$VERSION" "$DMG_PATH" --clobber --repo "$GH_REPO" 2>&1 | tail -2
else
    if [ -n "$NOTES_FILE" ] && [ -f "$NOTES_FILE" ]; then
        gh release create "v$VERSION" "$DMG_PATH" \
            --title "PickShot v$VERSION" \
            --notes-file "$NOTES_FILE" \
            --latest --repo "$GH_REPO" 2>&1 | tail -2
    else
        gh release create "v$VERSION" "$DMG_PATH" \
            --title "PickShot v$VERSION" \
            --notes "v$VERSION 핫픽스" \
            --latest --repo "$GH_REPO" 2>&1 | tail -2
    fi
fi
echo "✅ Release 업로드 완료"

echo ""
echo "════════════════════════════════════════════════════════════"
echo "  🎉 v$VERSION 배포 완료"
echo "  📥 https://github.com/$GH_REPO/releases/tag/v$VERSION"
echo "════════════════════════════════════════════════════════════"
