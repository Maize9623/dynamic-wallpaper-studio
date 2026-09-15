#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_SCRIPT="$SCRIPT_DIR/build.sh"
DIST_DIR="$MACOS_DIR/dist"
ARTIFACTS_DIR="$MACOS_DIR/artifacts"

APP_NAME="动态壁纸工作室"
EXECUTABLE_NAME="DynamicWallpaperStudio"
VERSION="2.0.0"
ARTIFACT_BASENAME="DynamicWallpaperStudio-macOS-${VERSION}-Universal"
ZIP_PATH="$ARTIFACTS_DIR/${ARTIFACT_BASENAME}.zip"
DMG_PATH="$ARTIFACTS_DIR/${ARTIFACT_BASENAME}.dmg"
CHECKSUM_PATH="$ARTIFACTS_DIR/${ARTIFACT_BASENAME}.sha256"

for required_command in \
    /usr/bin/codesign \
    /usr/bin/ditto \
    /usr/bin/hdiutil \
    /usr/bin/mktemp \
    /usr/bin/plutil \
    /usr/bin/shasum \
    /usr/bin/xcrun; do
    [[ -x "$required_command" ]] || {
        echo "错误：缺少必需命令 $required_command" >&2
        exit 1
    }
done

[[ -x "$BUILD_SCRIPT" ]] || {
    echo "错误：构建脚本不可执行：$BUILD_SCRIPT" >&2
    exit 1
}

for output_path in "$ZIP_PATH" "$DMG_PATH" "$CHECKSUM_PATH"; do
    [[ ! -e "$output_path" && ! -L "$output_path" ]] || {
        echo "错误：拒绝覆盖已有产物：$output_path" >&2
        exit 1
    }
done

/usr/bin/install -d -m 0755 "$ARTIFACTS_DIR"

STAGING_ROOT="$(/usr/bin/mktemp -d "$MACOS_DIR/.package.XXXXXX")"
case "$STAGING_ROOT" in
    "$MACOS_DIR"/.package.*) ;;
    *)
        echo "错误：临时目录不在预期位置：$STAGING_ROOT" >&2
        exit 1
        ;;
esac
MOUNT_POINT="$STAGING_ROOT/mount"
DMG_MOUNTED=0

cleanup() {
    if [[ "$DMG_MOUNTED" -eq 1 ]]; then
        /usr/bin/hdiutil detach "$MOUNT_POINT" -quiet >/dev/null 2>&1 || true
    fi
    /bin/rm -rf -- "$STAGING_ROOT"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

verify_app() {
    local app_bundle="$1"
    local require_no_starter="${2:-0}"
    local executable="$app_bundle/Contents/MacOS/$EXECUTABLE_NAME"
    local detected_version
    local architectures
    local architecture_count

    [[ -d "$app_bundle" ]] || {
        echo "错误：找不到应用包：$app_bundle" >&2
        exit 1
    }
    [[ -x "$executable" ]] || {
        echo "错误：找不到应用可执行文件：$executable" >&2
        exit 1
    }

    /usr/bin/plutil -lint "$app_bundle/Contents/Info.plist" >/dev/null
    detected_version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$app_bundle/Contents/Info.plist")"
    [[ "$detected_version" == "$VERSION" ]] || {
        echo "错误：应用版本为 $detected_version，预期为 $VERSION。" >&2
        exit 1
    }

    architectures="$(/usr/bin/xcrun lipo -archs "$executable")"
    architecture_count="$(/usr/bin/awk '{ print NF }' <<<"$architectures")"
    [[ "$architecture_count" -eq 2 ]] || {
        echo "错误：可执行文件并非仅包含 arm64 和 x86_64：$architectures" >&2
        exit 1
    }
    case " $architectures " in
        *" arm64 "*) ;;
        *)
            echo "错误：可执行文件缺少 arm64 架构：$architectures" >&2
            exit 1
            ;;
    esac
    case " $architectures " in
        *" x86_64 "*) ;;
        *)
            echo "错误：可执行文件缺少 x86_64 架构：$architectures" >&2
            exit 1
            ;;
    esac

    /usr/bin/codesign --verify --deep --strict --verbose=2 "$app_bundle"

    if [[ "$require_no_starter" -eq 1 && -e "$app_bundle/Contents/Resources/StarterWallpaper.mp4" ]]; then
        echo "错误：默认发布包中不应包含 StarterWallpaper.mp4。" >&2
        exit 1
    fi
}

echo "构建 macOS Universal 应用…"
"$BUILD_SCRIPT"

BUILT_APP="$DIST_DIR/$APP_NAME.app"
verify_app "$BUILT_APP"

PACKAGE_ROOT="$STAGING_ROOT/package"
STAGED_APP="$PACKAGE_ROOT/$APP_NAME.app"
/usr/bin/install -d -m 0755 "$PACKAGE_ROOT"
/usr/bin/ditto --norsrc --noextattr --noqtn --noacl "$BUILT_APP" "$STAGED_APP"

# build.sh may use Resources/StarterWallpaper.mp4 as a local convenience. Public
# packages exclude it unless STARTER_WALLPAPER was explicitly supplied.
if [[ -z "${STARTER_WALLPAPER:-}" && -e "$STAGED_APP/Contents/Resources/StarterWallpaper.mp4" ]]; then
    /bin/rm -f -- "$STAGED_APP/Contents/Resources/StarterWallpaper.mp4"
    /usr/bin/codesign --force --sign - --timestamp=none "$STAGED_APP"
fi
if [[ -z "${STARTER_WALLPAPER:-}" ]]; then
    verify_app "$STAGED_APP" 1
else
    verify_app "$STAGED_APP"
fi

ZIP_TEMP="$STAGING_ROOT/${ARTIFACT_BASENAME}.zip"
echo "创建 ZIP…"
/usr/bin/ditto \
    -c -k --norsrc --noextattr --noqtn --noacl --keepParent \
    --zlibCompressionLevel 9 \
    "$STAGED_APP" \
    "$ZIP_TEMP"

ZIP_VERIFY_ROOT="$STAGING_ROOT/zip-verify"
/usr/bin/install -d -m 0755 "$ZIP_VERIFY_ROOT"
/usr/bin/ditto -x -k --norsrc --noextattr --noqtn --noacl "$ZIP_TEMP" "$ZIP_VERIFY_ROOT"
if [[ -z "${STARTER_WALLPAPER:-}" ]]; then
    verify_app "$ZIP_VERIFY_ROOT/$APP_NAME.app" 1
else
    verify_app "$ZIP_VERIFY_ROOT/$APP_NAME.app"
fi

DMG_ROOT="$STAGING_ROOT/dmg-root"
/usr/bin/install -d -m 0755 "$DMG_ROOT"
/usr/bin/ditto --norsrc --noextattr --noqtn --noacl "$STAGED_APP" "$DMG_ROOT/$APP_NAME.app"
/bin/ln -s /Applications "$DMG_ROOT/Applications"

DMG_TEMP="$STAGING_ROOT/${ARTIFACT_BASENAME}.dmg"
echo "创建 DMG…"
/usr/bin/hdiutil create \
    -quiet \
    -fs HFS+ \
    -format UDZO \
    -imagekey zlib-level=9 \
    -srcfolder "$DMG_ROOT" \
    -volname "$APP_NAME $VERSION" \
    "$DMG_TEMP"
/usr/bin/hdiutil verify "$DMG_TEMP" >/dev/null

/usr/bin/install -d -m 0755 "$MOUNT_POINT"
/usr/bin/hdiutil attach \
    -quiet \
    -readonly \
    -nobrowse \
    -mountpoint "$MOUNT_POINT" \
    "$DMG_TEMP"
DMG_MOUNTED=1
if [[ -z "${STARTER_WALLPAPER:-}" ]]; then
    verify_app "$MOUNT_POINT/$APP_NAME.app" 1
else
    verify_app "$MOUNT_POINT/$APP_NAME.app"
fi
[[ -L "$MOUNT_POINT/Applications" ]] || {
    echo "错误：DMG 中缺少 Applications 软链接。" >&2
    exit 1
}
[[ "$(/usr/bin/readlink "$MOUNT_POINT/Applications")" == "/Applications" ]] || {
    echo "错误：DMG 中的 Applications 软链接目标不正确。" >&2
    exit 1
}
/usr/bin/hdiutil detach "$MOUNT_POINT" -quiet >/dev/null
DMG_MOUNTED=0

ZIP_SHA256="$(/usr/bin/shasum -a 256 "$ZIP_TEMP" | /usr/bin/awk '{ print $1 }')"
DMG_SHA256="$(/usr/bin/shasum -a 256 "$DMG_TEMP" | /usr/bin/awk '{ print $1 }')"
CHECKSUM_TEMP="$STAGING_ROOT/${ARTIFACT_BASENAME}.sha256"
/usr/bin/printf '%s  %s\n%s  %s\n' \
    "$ZIP_SHA256" "${ARTIFACT_BASENAME}.zip" \
    "$DMG_SHA256" "${ARTIFACT_BASENAME}.dmg" \
    > "$CHECKSUM_TEMP"

# Recheck immediately before publishing the three staged files.
for output_path in "$ZIP_PATH" "$DMG_PATH" "$CHECKSUM_PATH"; do
    [[ ! -e "$output_path" && ! -L "$output_path" ]] || {
        echo "错误：拒绝覆盖并发生成的产物：$output_path" >&2
        exit 1
    }
done

/bin/chmod 0644 "$ZIP_TEMP" "$DMG_TEMP" "$CHECKSUM_TEMP"

publish_artifact() {
    local staged_path="$1"
    local final_path="$2"

    /bin/mv -n "$staged_path" "$final_path"
    [[ ! -e "$staged_path" && ! -L "$staged_path" ]] || {
        echo "错误：拒绝覆盖并发生成的产物：$final_path" >&2
        exit 1
    }
}

publish_artifact "$ZIP_TEMP" "$ZIP_PATH"
publish_artifact "$DMG_TEMP" "$DMG_PATH"
publish_artifact "$CHECKSUM_TEMP" "$CHECKSUM_PATH"

echo
echo "打包完成："
echo "  $ZIP_PATH"
echo "  $DMG_PATH"
echo "  $CHECKSUM_PATH"
echo
/bin/cat "$CHECKSUM_PATH"
