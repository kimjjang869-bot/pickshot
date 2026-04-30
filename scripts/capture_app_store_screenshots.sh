#!/bin/bash
# capture_app_store_screenshots.sh
# PickShot — Mac App Store 스크린샷 자동 캡처 (1280×800 base, Retina = 2560×1600)
#
# 사용법:
#   ./scripts/capture_app_store_screenshots.sh
#
# 인터랙티브 — 각 시나리오 안내 후 Enter 누르면 5초 카운트다운 → 자동 캡처
# 결과: ./AppStoreScreenshots/01_main_grid.png ~ 08_pricing.png

set -e

OUT_DIR="$(cd "$(dirname "$0")/.." && pwd)/AppStoreScreenshots"
mkdir -p "$OUT_DIR"

APP_NAME="PickShot"
TARGET_W=1280
TARGET_H=800
RETINA_W=$((TARGET_W * 2))
RETINA_H=$((TARGET_H * 2))

# 색상
BOLD=$(tput bold 2>/dev/null || echo "")
RESET=$(tput sgr0 2>/dev/null || echo "")
GREEN=$(tput setaf 2 2>/dev/null || echo "")
YELLOW=$(tput setaf 3 2>/dev/null || echo "")
RED=$(tput setaf 1 2>/dev/null || echo "")
CYAN=$(tput setaf 6 2>/dev/null || echo "")

# 시나리오: (파일명, 안내문)
SCENARIOS=(
    "01_main_grid|메인 그리드 — 1만장 폴더 + 별점/라벨 + 썸네일"
    "02_full_preview|풀 미리보기 — 사진 클릭 + 메타데이터 사이드바"
    "03_client_select|클라이언트 셀렉 — 툴바 클라이언트 메뉴 → 사진 업로드 + 링크 생성"
    "04_raw_to_jpg|RAW → JPG 변환 — 내보내기 → RAW→JPG 탭 (화보 느낌 선택)"
    "05_compare_view|비교 보기 — 2~4장 선택 후 비교 모드 (Cmd+B)"
    "06_card_backup|메모리카드 백업 — 카드 마운트 다이얼로그 또는 백업 진행 화면"
    "07_folder_browser|폴더 브라우저 — 사이드바 펼침 + 즐겨찾기 + 메타데이터 탭"
    "08_pricing|가격 — 설정 → 구독 관리 탭 또는 Pro 잠금 모달"
)

# PickShot 윈도우 ID 가져오기 (screencapture -l 용)
get_window_id() {
    local pid
    pid=$(pgrep -f "${APP_NAME}.app" | head -1)
    if [ -z "$pid" ]; then return 1; fi
    # AppKit 창 ID 추출 (가장 큰 창 = main window 가정)
    osascript <<EOF
tell application "System Events"
    tell process "$APP_NAME"
        if exists window 1 then
            return id of window 1
        end if
    end tell
end tell
EOF
}

# 윈도우를 정확히 1280×800 으로 리사이즈 + 화면 중앙 배치
resize_window() {
    osascript <<EOF 2>/dev/null
tell application "System Events"
    tell process "$APP_NAME"
        if exists window 1 then
            set position of window 1 to {100, 80}
            set size of window 1 to {$TARGET_W, $TARGET_H}
            return "OK"
        end if
    end tell
end tell
EOF
}

# 단일 캡처 (윈도우만, 그림자 제외)
capture_window() {
    local out_path="$1"
    # PickShot 메인 윈도우 ID 찾기 — windowserver 의 window-id 가 필요.
    # screencapture -W 가 가장 안정적: 사용자가 윈도우 클릭하면 캡처. 자동화엔 부적합.
    # 대안: screencapture -l (windowID 기반).
    # AppleScript 로 PickShot 활성화 → Cmd+Shift+4 + Space + 자동 클릭은 복잡 →
    # 가장 신뢰성 높은 방법: screencapture -o (그림자 없음) + 약간 후 자동으로 윈도우 위치 캡처.

    # 단순화: PickShot 활성화 → windowID 찾기 → 캡처
    osascript -e 'tell application "'"$APP_NAME"'" to activate' 2>/dev/null
    sleep 0.5

    # GetWindowList 로 PickShot 메인 윈도우 ID 추출
    local win_id
    win_id=$(osascript <<'EOF' 2>/dev/null
use framework "Foundation"
use framework "AppKit"
use scripting additions

set foundWinId to ""
tell application "System Events"
    tell process "PickShot"
        if exists window 1 then
            set winName to name of window 1
        end if
    end tell
end tell

-- CGWindowListCopyWindowInfo via Python helper
do shell script "python3 -c '
import Quartz
wl = Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionOnScreenOnly | Quartz.kCGWindowListExcludeDesktopElements, Quartz.kCGNullWindowID)
for w in wl:
    if w.get(\"kCGWindowOwnerName\") == \"PickShot\" and w.get(\"kCGWindowLayer\", 0) == 0:
        print(w[\"kCGWindowNumber\"])
        break
'"
EOF
)

    if [ -z "$win_id" ]; then
        echo "${RED}❌ PickShot 윈도우를 찾을 수 없음${RESET}"
        return 1
    fi

    # 그림자 없이 윈도우만 캡처
    screencapture -l"$win_id" -o "$out_path"
    return $?
}

# 사이즈 검증
verify_size() {
    local path="$1"
    local w h
    w=$(sips -g pixelWidth "$path" 2>/dev/null | awk '/pixelWidth/ {print $2}')
    h=$(sips -g pixelHeight "$path" 2>/dev/null | awk '/pixelHeight/ {print $2}')
    echo "$w x $h"
    # 1280x800 또는 2560x1600 (Retina) 또는 그 사이값 모두 OK — App Store 가 요구하는 4가지 사이즈 중 하나면 통과
    if [ "$w" -ge 1280 ] && [ "$h" -ge 800 ]; then
        return 0
    fi
    return 1
}

echo ""
echo "${BOLD}${CYAN}╔════════════════════════════════════════════════════╗${RESET}"
echo "${BOLD}${CYAN}║  PickShot — App Store 스크린샷 자동 캡처              ║${RESET}"
echo "${BOLD}${CYAN}╚════════════════════════════════════════════════════╝${RESET}"
echo ""
echo "출력 경로: ${BOLD}${OUT_DIR}${RESET}"
echo "타깃 사이즈: ${BOLD}${RETINA_W}×${RETINA_H}${RESET} (1280×800 의 Retina 2x)"
echo ""

# PickShot 실행 확인
if ! pgrep -f "${APP_NAME}.app" >/dev/null; then
    echo "${YELLOW}⚠ PickShot 이 실행 중이 아닙니다. 먼저 앱을 실행해 주세요.${RESET}"
    echo "(Debug 또는 Release 빌드 둘 다 OK)"
    exit 1
fi

echo "${GREEN}✓${RESET} PickShot 실행 감지"
echo ""

# 윈도우 사이즈 셋업
echo "윈도우를 ${TARGET_W}×${TARGET_H} 로 조정 중..."
resize_window >/dev/null
sleep 1

if [ ! "$(resize_window)" = "OK" ] && [ -z "$(resize_window | grep OK)" ]; then
    echo "${YELLOW}⚠ AppleScript 로 자동 리사이즈 실패 가능 (시스템 설정 → 개인정보보호 → 손쉬운 사용 권한 확인).${RESET}"
    echo "  계속 진행 — 윈도우 사이즈가 안 맞으면 결과 PNG 가 1280×800 로 안 나올 수 있음."
fi
echo ""

# 시나리오 루프
TOTAL=${#SCENARIOS[@]}
IDX=1
for scenario in "${SCENARIOS[@]}"; do
    name="${scenario%%|*}"
    desc="${scenario##*|}"
    out_path="${OUT_DIR}/${name}.png"

    echo "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo "${BOLD}[${IDX}/${TOTAL}] ${name}${RESET}"
    echo "${CYAN}📋 ${desc}${RESET}"
    echo ""
    echo "이 화면을 PickShot 에 띄운 후 ${BOLD}Enter${RESET} 누르세요. (skip = ${BOLD}s${RESET}, quit = ${BOLD}q${RESET})"
    read -r -p "> " input
    if [ "$input" = "s" ]; then
        echo "${YELLOW}⊘ ${name} 건너뜀${RESET}"
        echo ""
        IDX=$((IDX + 1))
        continue
    fi
    if [ "$input" = "q" ]; then
        echo "${YELLOW}중단됨.${RESET}"
        break
    fi

    # 5초 카운트다운 (사용자가 마우스 치우거나 메뉴 열 시간)
    echo -n "캡처 시작: "
    for i in 5 4 3 2 1; do
        echo -n "${i}... "
        sleep 1
    done
    echo "${GREEN}📸${RESET}"

    # 캡처
    if capture_window "$out_path"; then
        size=$(verify_size "$out_path")
        if [ -f "$out_path" ]; then
            echo "${GREEN}✓ 저장: ${out_path} (${size})${RESET}"
        else
            echo "${RED}✗ 저장 실패${RESET}"
        fi
    else
        echo "${RED}✗ 캡처 실패${RESET}"
    fi
    echo ""
    IDX=$((IDX + 1))
done

echo "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
echo "${BOLD}결과:${RESET}"
ls -lh "$OUT_DIR"/*.png 2>/dev/null | awk '{print "  " $9, "—", $5}'
echo ""
echo "${GREEN}완료!${RESET} App Store Connect 에 ${BOLD}${OUT_DIR}${RESET} 의 PNG 파일들을 드래그하세요."
echo ""
echo "${YELLOW}체크:${RESET}"
echo "  • 사이즈 ${RETINA_W}×${RETINA_H} 또는 1280×800 / 1440×900 / 2560×1600 / 2880×1800 중 하나면 통과"
echo "  • 안 맞으면: ${BOLD}sips -Z 2560 ~/<path>.png${RESET} 로 비례 리사이즈"
