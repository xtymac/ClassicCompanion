#!/bin/zsh
# 把 Sparkle.framework 放进应用并按 Sparkle 文档签名。由 build-app.sh 和隔离测试工具 source。
# 依据：Sparkle 文档 “Sandboxing”（非沙盒应用可以去掉 XPC Services）和
# “Code signing … outside of Xcode”（由内到外逐个签 Autoupdate、Updater.app、框架，不用 --deep）。

# SwiftPM 按 Sparkle 包里写的校验值下载的官方 XCFramework（不用 swift build 输出目录里的副本）。
SPARKLE_FRAMEWORK_SOURCE="${SPARKLE_FRAMEWORK_SOURCE:-$(cd "$(dirname "${(%):-%x}")/.." && pwd)/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework}"

# embed_sparkle <app> <期望的 Sparkle 版本>
embed_sparkle() {
  local app="$1" expected="$2" fw="$1/Contents/Frameworks/Sparkle.framework" version
  [[ -d "$SPARKLE_FRAMEWORK_SOURCE" ]] || { echo "错误：找不到 Sparkle.framework（先 swift build）" >&2; return 1; }
  version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SPARKLE_FRAMEWORK_SOURCE/Resources/Info.plist")"
  [[ "$version" == "$expected" ]] || { echo "错误：Sparkle 版本 $version，配置要求 $expected" >&2; return 1; }
  mkdir -p "$app/Contents/Frameworks"
  # ditto 保留框架里的符号链接（Versions/Current 等）。
  ditto "$SPARKLE_FRAMEWORK_SOURCE" "$fw"
  # 应用没有沙盒：Sparkle 文档说明这时不需要、也不会用 Downloader.xpc 和 Installer.xpc。
  rm -rf "$fw/Versions/B/XPCServices"
  # 应用只支持 Apple 芯片：框架里的可执行文件只留 arm64（原来是 x86_64 + arm64）。
  local f
  for f in "$fw/Versions/B/Sparkle" "$fw/Versions/B/Autoupdate" "$fw/Versions/B/Updater.app/Contents/MacOS/Updater"; do
    [[ -f "$f" ]] || { echo "错误：Sparkle.framework 里缺少 ${f#$fw/}" >&2; return 1; }
    if [[ "$(lipo -archs "$f")" != arm64 ]]; then
      lipo -thin arm64 "$f" -output "$f.arm64" && mv "$f.arm64" "$f"
    fi
  done
  # 只有这三个 Mach-O；多出来的说明 Sparkle 的结构变了，要重新核对签名步骤。
  local machos=(${(f)"$(/usr/bin/find "$fw" -type f -perm -u+x -exec sh -c 'lipo -archs "$1" >/dev/null 2>&1 && echo "$1"' _ {} \;)"})
  (( ${#machos} == 3 )) || { echo "错误：Sparkle.framework 里有 ${#machos} 个可执行文件，预期 3 个" >&2; return 1; }
}

# fix_rpaths <可执行文件>：只留系统 Swift 库和 Contents/Frameworks。
# 去掉 Xcode 工具链、本机构建目录（PackageFrameworks）和 @loader_path，安装后的应用不依赖开发环境和本机路径。
fix_rpaths() {
  local bin="$1" rpath
  for rpath in ${(f)"$(otool -l "$bin" | awk '$1 == "cmd" && $2 == "LC_RPATH" {getline; getline; print $2}')"}; do
    [[ -z "$rpath" || "$rpath" == /usr/lib/swift ]] && continue
    install_name_tool -delete_rpath "$rpath" "$bin"
  done
  install_name_tool -add_rpath @executable_path/../Frameworks "$bin"
}

# sign_sparkle_app <app> <签名身份或 ->：由内到外签名。Developer ID 带加固运行时和安全时间戳；ad-hoc 和以前的构建一样不带。
sign_sparkle_app() {
  local app="$1" identity="$2" fw="$1/Contents/Frameworks/Sparkle.framework"
  local opts=(--force --sign "$identity")
  if [[ "$identity" == - ]]; then opts+=(--timestamp=none); else opts+=(--options runtime --timestamp); fi
  if [[ -d "$fw" ]]; then
    # Autoupdate 原来的 com.apple.application-identifier 权限不保留：它是受限权限，Developer ID 签名带上它反而不能启动（Sparkle 文档的命令也不保留）。
    codesign "${opts[@]}" "$fw/Versions/B/Autoupdate" || return 1
    codesign "${opts[@]}" "$fw/Versions/B/Updater.app" || return 1
    codesign "${opts[@]}" "$fw" || return 1
  fi
  codesign "${opts[@]}" "$app" || return 1
}

# check_sparkle_embedding <app> [Team ID]：只读检查结构、架构、签名和链接路径。返回非 0 表示有问题，问题写到标准错误。
check_sparkle_embedding() {
  local app="$1" team="${2:-}" fw="$1/Contents/Frameworks/Sparkle.framework" bin="$1/Contents/MacOS/ClassicCompanion" bad=0 part sig
  [[ -d "$fw" ]] || { echo "缺少 Contents/Frameworks/Sparkle.framework" >&2; return 1; }
  [[ "$(readlink "$fw/Versions/Current")" == B ]] || { echo "Versions/Current 不是指向 B 的符号链接" >&2; bad=1; }
  [[ ! -e "$fw/Versions/B/XPCServices" ]] || { echo "还带着 XPCServices" >&2; bad=1; }
  for part in "$fw/Versions/B/Sparkle" "$fw/Versions/B/Autoupdate" "$fw/Versions/B/Updater.app/Contents/MacOS/Updater"; do
    [[ "$(lipo -archs "$part" 2>/dev/null)" == arm64 ]] || { echo "${part#$app/} 不是只有 arm64" >&2; bad=1; }
  done
  otool -L "$bin" | grep -q '@rpath/Sparkle.framework/Versions/B/Sparkle' || { echo "主程序没有链接 Sparkle" >&2; bad=1; }
  local rpaths="$(otool -l "$bin" | awk '$1 == "cmd" && $2 == "LC_RPATH" {getline; getline; print $2}' | sort | tr '\n' ' ')"
  [[ "$rpaths" == "/usr/lib/swift @executable_path/../Frameworks " || "$rpaths" == "@executable_path/../Frameworks /usr/lib/swift " ]] ||
    { echo "rpath 不对：$rpaths" >&2; bad=1; }
  for part in "$fw/Versions/B/Autoupdate" "$fw/Versions/B/Updater.app" "$fw"; do
    codesign --verify --strict "$part" 2>/dev/null || { echo "${part#$app/} 签名不完整" >&2; bad=1; continue; }
    if [[ -n "$team" ]]; then
      sig="$(codesign -dvv "$part" 2>&1)"
      grep -q '^Authority=Developer ID Application: ' <<<"$sig" && grep -qx "TeamIdentifier=$team" <<<"$sig" &&
        grep -q '^Timestamp=' <<<"$sig" && grep -qE 'flags=0x[0-9a-f]+\([^)]*runtime' <<<"$sig" ||
        { echo "${part#$app/} 不是 Team $team 的 Developer ID（加固运行时、时间戳）签名" >&2; bad=1; }
    fi
  done
  codesign --verify --deep --strict "$app" 2>/dev/null || { echo "应用签名（--deep --strict）不完整" >&2; bad=1; }
  return $bad
}
