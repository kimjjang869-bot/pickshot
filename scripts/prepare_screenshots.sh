#!/bin/bash
# App Store 스크린샷 준비 스크립트
#
# 사용법:
#   1. PickShot 앱에서 Cmd+Shift+4 로 창 영역 스크린샷 10개 촬영
#   2. ~/Desktop/pickshot_screenshots/ 폴더에 원본 저장 (1.png ~ 10.png)
#   3. 이 스크립트 실행
#
#   또는 Cmd+Shift+3 전체 화면으로 찍어서 리사이즈

set -e

SRC_DIR="$HOME/Desktop/pickshot_screenshots"
OUT_DIR="$HOME/Desktop/pickshot_screenshots_appstore"

# App Store Connect 권장 Mac 해상도
TARGET_WIDTH=2880
TARGET_HEIGHT=1800

if [ ! -d "$SRC_DIR" ]; then
    echo "❌ 원본 폴더 없음: $SRC_DIR"
    echo ""
    echo "사용법:"
    echo "  1. mkdir -p $SRC_DIR"
    echo "  2. 스크린샷 10장을 1.png ~ 10.png 로 저장"
    echo "  3. 이 스크립트 재실행"
    exit 1
fi

mkdir -p "$OUT_DIR"

count=0
for src in "$SRC_DIR"/*.png "$SRC_DIR"/*.jpg "$SRC_DIR"/*.jpeg; do
    [ -f "$src" ] || continue
    count=$((count + 1))

    name=$(basename "$src")
    out="$OUT_DIR/${name%.*}.png"

    # sips 으로 리사이즈 (긴 변 기준)
    sips -Z $TARGET_WIDTH "$src" --out "$out" > /dev/null 2>&1 || {
        echo "⚠️  $name 처리 실패 (원본 복사)"
        cp "$src" "$out"
    }

    # 실제 크기 확인
    dims=$(sips -g pixelWidth -g pixelHeight "$out" 2>/dev/null | grep -E 'pixel(Width|Height)' | awk '{print $2}' | paste -sd x -)
    size=$(du -h "$out" | cut -f1)
    echo "✅ $name → $dims ($size)"
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "스크린샷 $count 개 준비 완료"
echo "출력: $OUT_DIR"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "다음 단계:"
echo "1. $OUT_DIR 폴더 확인"
echo "2. App Store Connect 에서 앱 버전 → 미리보기 및 스크린샷 → 업로드"
echo ""
echo "권장 순서 (docs/APP_STORE_SUBMISSION.md 참조):"
echo "  1. 메인 뷰 (폴더 + 썸네일 + 프리뷰)"
echo "  2. 전체화면 컬링 모드 (Cmd+F)"
echo "  3. 레이팅/컬러 라벨 적용"
echo "  4. JPG+RAW 매칭"
echo "  5. EXIF 정보"
echo "  6. 내보내기 (커스텀 폴더명)"
echo "  7. 비디오 플레이어 + LUT"
echo "  8. 메모리카드 백업"
echo "  9. G셀렉 설정"
echo " 10. 설정 화면"
