#!/bin/bash
set -euo pipefail
AGY_PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGY_VERSION="1.0.0-beta.3"
if [[ "$(uname -s)" != Darwin ]]; then
    echo '请在 Intel Mac 上运行，不能在 Linux / WSL 上生成原生 macOS 应用。'
    exit 1
fi
if [[ "$(uname -m)" != x86_64 ]]; then
    echo '此版本只生成 Intel x86_64 应用；请在 Intel Mac 上运行。'
    exit 1
fi
AGY_OS_MAJOR="$(/usr/bin/sw_vers -productVersion | /usr/bin/cut -d. -f1)"
if [[ "$AGY_OS_MAJOR" -lt 13 ]]; then echo '最低需要 macOS 13，支持 macOS 26 Tahoe。'; exit 1; fi
if ! /usr/bin/xcrun --sdk macosx --show-sdk-path >/dev/null 2>&1; then
    echo '请先完成 Apple Command Line Tools 安装，安装后重新双击本文件。'
    /usr/bin/xcode-select --install || true
    exit 1
fi
AGY_CACHE="$HOME/Library/Caches/AGY-Mac/Intel"
AGY_OUTPUT_ROOT="${AGY_MAC_OUTPUT_ROOT:-$HOME/Library/Application Support/AGY-Mac/Builds}"
mkdir -p "$AGY_CACHE" "$AGY_OUTPUT_ROOT"
AGY_OUTPUT="$(mktemp -d "$AGY_OUTPUT_ROOT/Intel-XXXXXX")"
AGY_LOG="$AGY_OUTPUT/build.log"
trap 'AGY_EXIT=$?; if [[ "$AGY_EXIT" -ne 0 ]]; then echo "未完成，请查看日志：$AGY_LOG"; tail -n 60 "$AGY_LOG" 2>/dev/null || true; if [[ -t 0 ]]; then read -r -p "按 Enter 关闭" || true; fi; fi' EXIT
if [[ -f "$AGY_PROJECT/SOURCE-SHA256SUMS" ]]; then
    echo '正在校验随包源码…'
    (cd "$AGY_PROJECT" && /usr/bin/shasum -a 256 -c SOURCE-SHA256SUMS) >"$AGY_LOG" 2>&1
fi
export MACOSX_DEPLOYMENT_TARGET=13.0
AGY_BUILD_ARGS=(--package-path "$AGY_PROJECT" --scratch-path "$AGY_CACHE/build" --configuration release --arch x86_64)
echo '正在为 Intel Mac 编译原生界面与核心逻辑…'
/usr/bin/xcrun swift test "${AGY_BUILD_ARGS[@]}" 2>&1 | tee -a "$AGY_LOG"
/usr/bin/xcrun swift build "${AGY_BUILD_ARGS[@]}" --product AGY-Mac -Xlinker -rpath -Xlinker '@executable_path/../Frameworks' 2>&1 | tee -a "$AGY_LOG"
AGY_BIN="$(/usr/bin/xcrun swift build "${AGY_BUILD_ARGS[@]}" --show-bin-path)"
AGY_EXE="$AGY_BIN/AGY-Mac"
if [[ "$(/usr/bin/lipo -archs "$AGY_EXE")" != x86_64 ]]; then echo '产物架构不是纯 x86_64，已停止。'; exit 1; fi
AGY_APP="$AGY_OUTPUT/AGY-Mac.app"
AGY_RESOURCES="$AGY_APP/Contents/Resources"
mkdir -p "$AGY_APP/Contents/MacOS" "$AGY_RESOURCES" "$AGY_APP/Contents/Frameworks"
cp "$AGY_EXE" "$AGY_APP/Contents/MacOS/AGY-Mac"
cp "$AGY_PROJECT/Info.plist" "$AGY_APP/Contents/Info.plist"
cp "$AGY_PROJECT/Brand/Mark.png" "$AGY_RESOURCES/Mark.png"
cp "$AGY_PROJECT/THIRD_PARTY_NOTICES.md" "$AGY_RESOURCES/THIRD_PARTY_NOTICES.md"
AGY_ICONSET="$AGY_OUTPUT/AppIcon.iconset"
mkdir -p "$AGY_ICONSET"
for AGY_SIZE in 16 32 128 256 512; do
    /usr/bin/sips -z "$AGY_SIZE" "$AGY_SIZE" "$AGY_PROJECT/Brand/Mark.png" --out "$AGY_ICONSET/icon_${AGY_SIZE}x${AGY_SIZE}.png" >>"$AGY_LOG" 2>&1
    AGY_DOUBLE=$((AGY_SIZE * 2))
    /usr/bin/sips -z "$AGY_DOUBLE" "$AGY_DOUBLE" "$AGY_PROJECT/Brand/Mark.png" --out "$AGY_ICONSET/icon_${AGY_SIZE}x${AGY_SIZE}@2x.png" >>"$AGY_LOG" 2>&1
done
/usr/bin/iconutil -c icns "$AGY_ICONSET" -o "$AGY_RESOURCES/AppIcon.icns" >>"$AGY_LOG" 2>&1
if /usr/bin/xcrun --find swift-stdlib-tool >/dev/null 2>&1; then
    /usr/bin/xcrun swift-stdlib-tool --copy --platform macosx --scan-executable "$AGY_APP/Contents/MacOS/AGY-Mac" --destination "$AGY_APP/Contents/Frameworks" --sign - >>"$AGY_LOG" 2>&1
fi
/usr/bin/codesign --force --deep --sign - --identifier com.ddyec.agy-mac "$AGY_APP" >>"$AGY_LOG" 2>&1
/usr/bin/codesign --verify --deep --strict "$AGY_APP" >>"$AGY_LOG" 2>&1
/usr/bin/plutil -lint "$AGY_APP/Contents/Info.plist" >>"$AGY_LOG" 2>&1
AGY_ZIP="$AGY_OUTPUT/AGY-Mac-$AGY_VERSION-macos-x86_64.zip"
/usr/bin/ditto -c -k --keepParent "$AGY_APP" "$AGY_ZIP"
/usr/bin/shasum -a 256 "$AGY_ZIP" >"$AGY_OUTPUT/SHA256SUMS.txt"
printf '{"architecture":"x86_64","minimumMacOS":"13.0","builtOnMac":true,"nativeUIVisuallyVerified":false}\n' >"$AGY_OUTPUT/build-report.json"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then printf 'app=%s\nzip=%s\noutput=%s\n' "$AGY_APP" "$AGY_ZIP" "$AGY_OUTPUT" >>"$GITHUB_OUTPUT"; fi
echo "Intel Mac 应用已生成：$AGY_APP"
echo "运行包：$AGY_ZIP"
echo '现在启动新版。首次填写与 iPhone / PC 相同的服务器地址和连接密钥。'
if [[ "${AGY_MAC_NO_LAUNCH:-0}" != 1 ]]; then
    /usr/bin/open -R "$AGY_APP"
    /usr/bin/open "$AGY_APP"
fi
