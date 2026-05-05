#!/bin/bash
# bundle_dylibs.sh — PickShot.app/Contents/Frameworks/ 에 LibRaw + 의존성 동봉
# 사용법: ./scripts/bundle_dylibs.sh /path/to/PickShot.app
# 다른 Mac (homebrew 없는 환경)에서도 동작하도록 dylib 를 .app 안에 포함하고
# install_name_tool 로 @rpath 로 재작성.

set -euo pipefail

APP_PATH="${1:-}"
if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH" ]; then
    echo "Usage: $0 /path/to/PickShot.app"
    exit 1
fi

EXE_PATH="$APP_PATH/Contents/MacOS/PickShot"
FRAMEWORKS_DIR="$APP_PATH/Contents/Frameworks"

if [ ! -x "$EXE_PATH" ]; then
    echo "❌ Executable not found: $EXE_PATH"
    exit 1
fi

echo "📦 Bundling dylibs into $APP_PATH"
mkdir -p "$FRAMEWORKS_DIR"

# 동봉 대상 (homebrew 경로) — 변경되면 여기 갱신
SRC_LIBRAW="/opt/homebrew/opt/libraw/lib/libraw.25.dylib"
SRC_LIBOMP="/opt/homebrew/opt/libomp/lib/libomp.dylib"
SRC_LIBJPEG="/opt/homebrew/opt/jpeg-turbo/lib/libjpeg.8.dylib"
SRC_LIBLCMS2="/opt/homebrew/opt/little-cms2/lib/liblcms2.2.dylib"

for src in "$SRC_LIBRAW" "$SRC_LIBOMP" "$SRC_LIBJPEG" "$SRC_LIBLCMS2"; do
    if [ ! -f "$src" ]; then
        echo "❌ Source dylib not found: $src"
        exit 1
    fi
    cp -f "$src" "$FRAMEWORKS_DIR/"
done

# write 권한 부여 (homebrew 는 기본 644 read-only)
chmod -R u+w "$FRAMEWORKS_DIR"

LIBRAW="$FRAMEWORKS_DIR/libraw.25.dylib"
LIBOMP="$FRAMEWORKS_DIR/libomp.dylib"
LIBJPEG="$FRAMEWORKS_DIR/libjpeg.8.dylib"
LIBLCMS2="$FRAMEWORKS_DIR/liblcms2.2.dylib"

# 1) 각 dylib 의 install name 을 @rpath 로 재작성
echo "🔧 Rewriting install names..."
install_name_tool -id "@rpath/libraw.25.dylib"   "$LIBRAW"
install_name_tool -id "@rpath/libomp.dylib"      "$LIBOMP"
install_name_tool -id "@rpath/libjpeg.8.dylib"   "$LIBJPEG"
install_name_tool -id "@rpath/liblcms2.2.dylib"  "$LIBLCMS2"

# 2) libraw 의 dylib 의존성 경로 재작성 (homebrew → @rpath)
install_name_tool -change "/opt/homebrew/opt/libomp/lib/libomp.dylib" \
                          "@rpath/libomp.dylib" "$LIBRAW"
install_name_tool -change "/opt/homebrew/opt/jpeg-turbo/lib/libjpeg.8.dylib" \
                          "@rpath/libjpeg.8.dylib" "$LIBRAW"
install_name_tool -change "/opt/homebrew/opt/little-cms2/lib/liblcms2.2.dylib" \
                          "@rpath/liblcms2.2.dylib" "$LIBRAW"

# 3) Executable 의 libraw 참조도 @rpath 로 재작성 (otool 로 현재 경로 자동 감지)
echo "🔧 Rewriting executable's libraw reference..."
CURRENT_LIBRAW_REF=$(otool -L "$EXE_PATH" | grep -E "libraw\.25\.dylib" | head -1 | awk '{print $1}' || true)
if [ -n "$CURRENT_LIBRAW_REF" ] && [ "$CURRENT_LIBRAW_REF" != "@rpath/libraw.25.dylib" ]; then
    install_name_tool -change "$CURRENT_LIBRAW_REF" \
                              "@rpath/libraw.25.dylib" "$EXE_PATH"
    echo "   $CURRENT_LIBRAW_REF → @rpath/libraw.25.dylib"
fi

# 4) Executable 에 @loader_path/../Frameworks rpath 가 있는지 확인하고 없으면 추가
if ! otool -l "$EXE_PATH" | grep -A2 LC_RPATH | grep -q "@loader_path/../Frameworks"; then
    install_name_tool -add_rpath "@loader_path/../Frameworks" "$EXE_PATH" 2>/dev/null || true
    echo "   added rpath @loader_path/../Frameworks"
fi

# 5) Re-codesign (linker 가 install_name 변경 후 서명 무효화) — ad-hoc 으로 충분
echo "✍️  Re-signing..."
codesign --force --sign - --timestamp=none "$LIBRAW"
codesign --force --sign - --timestamp=none "$LIBOMP"
codesign --force --sign - --timestamp=none "$LIBJPEG"
codesign --force --sign - --timestamp=none "$LIBLCMS2"
codesign --force --sign - --timestamp=none --preserve-metadata=entitlements "$EXE_PATH"
codesign --force --sign - --timestamp=none --deep "$APP_PATH"

# 6) 추가 — debug.dylib 가 있으면 거기도 libraw 참조 재작성 (Debug 빌드 호환)
DEBUG_DYLIB="$APP_PATH/Contents/MacOS/PickShot.debug.dylib"
if [ -f "$DEBUG_DYLIB" ]; then
    DEBUG_LIBRAW_REF=$(otool -L "$DEBUG_DYLIB" | grep -E "libraw\.25\.dylib" | head -1 | awk '{print $1}' || true)
    if [ -n "$DEBUG_LIBRAW_REF" ] && [ "$DEBUG_LIBRAW_REF" != "@rpath/libraw.25.dylib" ]; then
        install_name_tool -change "$DEBUG_LIBRAW_REF" \
                                  "@rpath/libraw.25.dylib" "$DEBUG_DYLIB"
        codesign --force --sign - --timestamp=none "$DEBUG_DYLIB"
        echo "🔧 debug.dylib libraw → @rpath"
    fi
fi

# 7) 검증
echo "✅ Verification:"
echo "   --- libraw.25.dylib 의존성:"
otool -L "$LIBRAW" | grep -E "(libraw|libomp|libjpeg|liblcms2)" | sed 's/^/      /' || true
echo "   --- 실행파일 libraw 참조:"
otool -L "$EXE_PATH" | grep -E "libraw" | sed 's/^/      /' || echo "      (no direct libraw ref — debug.dylib 가짐)"
echo "   --- codesign:"
codesign --verify --verbose=2 "$APP_PATH" 2>&1 | head -3 | sed 's/^/      /'

# 8) v9.1.4: /opt/homebrew 경로 잔존 검증 — libraw 업그레이드 또는 새 brew 의존성
#   추가 시 누락 즉시 감지. 다른 머신에서 missing dylib 크래시 차단.
echo "🔍 Homebrew 경로 잔존 검사..."
LEAKED_BIN=$(otool -L "$EXE_PATH" 2>/dev/null | grep "/opt/homebrew" || true)
LEAKED_LIBS=""
for lib in "$FRAMEWORKS_DIR"/*.dylib; do
    [ -f "$lib" ] || continue
    leak=$(otool -L "$lib" 2>/dev/null | grep "/opt/homebrew" || true)
    if [ -n "$leak" ]; then
        LEAKED_LIBS="$LEAKED_LIBS\n   $(basename "$lib"):\n$leak"
    fi
done
if [ -n "$LEAKED_BIN" ] || [ -n "$LEAKED_LIBS" ]; then
    echo "❌ Homebrew 경로 누출 감지 — 다른 Mac 에서 missing dylib 크래시 발생!"
    [ -n "$LEAKED_BIN" ] && echo "   실행파일:" && echo "$LEAKED_BIN"
    [ -n "$LEAKED_LIBS" ] && echo -e "$LEAKED_LIBS"
    echo ""
    echo "   해결: bundle_dylibs.sh 에 누락된 의존성을 SRC_LIBXXX 로 추가하고 install_name_tool -change 라인 추가."
    exit 1
fi
echo "   ✓ /opt/homebrew 참조 0건"

echo "✨ Done — dylibs bundled and code-signed."
