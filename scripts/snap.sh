#!/bin/bash
# snap.sh — PickShot 윈도우 캡처 (단순화 버전, 외부 의존성 X)
# 사용법: bash snap.sh 01_main_grid

NAME="${1:-screenshot}"
OUT_DIR="/Users/potokan/PhotoRawManager/AppStoreScreenshots"
mkdir -p "$OUT_DIR"

echo "5초 후 PickShot 캡처. 마우스 정리하세요."
for i in 5 4 3 2 1; do echo -n "$i... "; sleep 1; done
echo "📸"

# PickShot 활성화
osascript -e 'tell application "PickShot" to activate' 2>/dev/null
sleep 0.4

# 윈도우 좌표 + 크기 (AppleScript)
BOUNDS=$(osascript <<'EOF' 2>/dev/null
tell application "System Events"
    tell process "PickShot"
        if exists window 1 then
            set p to position of window 1
            set s to size of window 1
            return (item 1 of p as string) & " " & (item 2 of p as string) & " " & (item 1 of s as string) & " " & (item 2 of s as string)
        end if
    end tell
end tell
EOF
)

if [ -z "$BOUNDS" ]; then
    echo "❌ PickShot 윈도우 못 찾음. 앱이 실행 중인가요?"
    echo "   (시스템 설정 → 손쉬운 사용 → 터미널 권한도 확인)"
    exit 1
fi

read -r X Y W H <<< "$BOUNDS"
echo "  Window bounds: ${X},${Y} ${W}×${H}"

OUT="$OUT_DIR/${NAME}.png"
# screencapture -R "x,y,w,h" -o (그림자 제외)
screencapture -R "${X},${Y},${W},${H}" -o "$OUT"

if [ -f "$OUT" ]; then
    PX_W=$(sips -g pixelWidth "$OUT" 2>/dev/null | awk '/pixelWidth/ {print $2}')
    PX_H=$(sips -g pixelHeight "$OUT" 2>/dev/null | awk '/pixelHeight/ {print $2}')
    echo "✓ 저장: $OUT (${PX_W}×${PX_H})"
else
    echo "❌ 캡처 실패"
    exit 1
fi
