#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_DIR="$(cd "$MACOS_DIR/.." && pwd)"
SOURCES_DIR="$MACOS_DIR/Sources"
RESOURCES_DIR="$MACOS_DIR/Resources"
INFO_PLIST="$MACOS_DIR/Info.plist"
DIST_DIR="$MACOS_DIR/dist"

APP_NAME="动态壁纸工作室"
EXECUTABLE_NAME="DynamicWallpaperStudio"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
DEPLOYMENT_TARGET="15.0"

command -v xcrun >/dev/null 2>&1 || {
    echo "错误：找不到 xcrun。请先安装 Xcode Command Line Tools。" >&2
    exit 1
}
command -v codesign >/dev/null 2>&1 || {
    echo "错误：找不到 codesign。请先安装 Xcode Command Line Tools。" >&2
    exit 1
}

[[ -f "$INFO_PLIST" ]] || {
    echo "错误：缺少 $INFO_PLIST" >&2
    exit 1
}
[[ -f "$RESOURCES_DIR/AppIcon.icns" ]] || {
    echo "错误：缺少 $RESOURCES_DIR/AppIcon.icns" >&2
    exit 1
}

SOURCE_FILES=("$SOURCES_DIR"/*.swift)
[[ -e "${SOURCE_FILES[0]}" ]] || {
    echo "错误：$SOURCES_DIR 中没有 Swift 源文件。" >&2
    exit 1
}

SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
STAGING_ROOT="$(mktemp -d "$MACOS_DIR/.build.XXXXXX")"
trap 'rm -rf -- "$STAGING_ROOT"' EXIT

for architecture in arm64 x86_64; do
    mkdir -p "$STAGING_ROOT/$architecture"
    echo "编译 ${architecture}（macOS ${DEPLOYMENT_TARGET}+）…"
    xcrun swiftc \
        -parse-as-library \
        -target "${architecture}-apple-macosx${DEPLOYMENT_TARGET}" \
        -sdk "$SDK_PATH" \
        -O \
        -whole-module-optimization \
        -module-name "$EXECUTABLE_NAME" \
        -Xlinker -no_uuid \
        "${SOURCE_FILES[@]}" \
        -o "$STAGING_ROOT/$architecture/$EXECUTABLE_NAME"
done

STAGED_APP="$STAGING_ROOT/$APP_NAME.app"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"

xcrun lipo -create \
    "$STAGING_ROOT/arm64/$EXECUTABLE_NAME" \
    "$STAGING_ROOT/x86_64/$EXECUTABLE_NAME" \
    -output "$STAGED_APP/Contents/MacOS/$EXECUTABLE_NAME"
chmod 0755 "$STAGED_APP/Contents/MacOS/$EXECUTABLE_NAME"

install -m 0644 "$INFO_PLIST" "$STAGED_APP/Contents/Info.plist"
install -m 0644 "$RESOURCES_DIR/AppIcon.icns" "$STAGED_APP/Contents/Resources/AppIcon.icns"
install -m 0644 "$PROJECT_DIR/LICENSE" "$STAGED_APP/Contents/Resources/LICENSE.txt"
install -m 0644 "$PROJECT_DIR/NOTICE" "$STAGED_APP/Contents/Resources/NOTICE.txt"
install -m 0644 "$PROJECT_DIR/THIRD_PARTY_NOTICES.md" "$STAGED_APP/Contents/Resources/THIRD_PARTY_NOTICES.md"

starter_wallpaper="${STARTER_WALLPAPER:-}"
if [[ -z "$starter_wallpaper" && -f "$RESOURCES_DIR/StarterWallpaper.mp4" ]]; then
    starter_wallpaper="$RESOURCES_DIR/StarterWallpaper.mp4"
fi
if [[ -n "$starter_wallpaper" ]]; then
    [[ -f "$starter_wallpaper" ]] || {
        echo "错误：STARTER_WALLPAPER 不是可读取的文件：$starter_wallpaper" >&2
        exit 1
    }
    install -m 0644 "$starter_wallpaper" "$STAGED_APP/Contents/Resources/StarterWallpaper.mp4"
    echo "已加入可选的 StarterWallpaper.mp4。"
fi

plutil -lint "$STAGED_APP/Contents/Info.plist" >/dev/null
codesign --force --sign - --timestamp=none "$STAGED_APP"
codesign --verify --deep --strict "$STAGED_APP"

mkdir -p "$DIST_DIR"
if [[ -e "$APP_BUNDLE" ]]; then
    rm -rf -- "$APP_BUNDLE"
fi
mv "$STAGED_APP" "$APP_BUNDLE"

echo
echo "构建完成：$APP_BUNDLE"
file "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE_NAME"
