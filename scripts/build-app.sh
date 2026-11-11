#!/bin/zsh
# 构建 Classic Companion.app。
# 用法：scripts/build-app.sh [debug|release]   默认 release
# 每次用新的构建号输出到 build/<构建号>/，不覆盖已有构建。
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
[[ "$CONFIG" == release || "$CONFIG" == debug ]] || { echo "配置必须为 debug 或 release" >&2; exit 1; }
source scripts/release-signing.sh
SIGNING_MODE="${CC_SIGNING_MODE:-$( [[ "$CONFIG" == release ]] && echo developer-id || echo adhoc )}"
[[ "$SIGNING_MODE" == developer-id || "$SIGNING_MODE" == adhoc ]] || exit 1
if [[ "$SIGNING_MODE" == developer-id ]]; then signing_preflight; fi
EXECUTABLE="ClassicCompanion"
BUNDLE_ID="local.classiccompanion.ClassicCompanion"   # 不要改：登录数据按它存放
VERSION="0.1.0-beta.1"   # 用户定（发布回归 2026-11-08）；GitHub 标签 v0.1.0-beta.1，标为 Pre-release
MIN_MACOS="15.0"
BUILD_STAMP="$(date +%Y%m%d.%H%M)"
OUT_DIR="build/$BUILD_STAMP"
APP="$OUT_DIR/Classic Companion.app"
ICON_STATUS="$(<assets/icon/STATUS)"

if [[ -e "$OUT_DIR" ]]; then
  echo "错误：$OUT_DIR 已存在，不覆盖。等到下一分钟再构建。" >&2
  exit 1
fi

swift build -c "$CONFIG" --arch arm64
BIN_DIR="$(swift build -c "$CONFIG" --arch arm64 --show-bin-path)"
BIN="$BIN_DIR/$EXECUTABLE"
# 界面文字（en、ja、zh-Hans、zh-Hant）：swift build 按 Package.swift 的 resources 生成资源包。
L10N_BUNDLE="ClassicCompanion_ClassicCompanion.bundle"
LANGUAGES=(en ja zh-Hans zh-Hant)

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$EXECUTABLE"
# 去掉指向 Xcode 的 rpath：安装后的应用不依赖开发环境。
for rpath in ${(f)"$(otool -l "$APP/Contents/MacOS/$EXECUTABLE" | awk '$1 == "path" && $2 ~ /^\/Applications\/Xcode/ {print $2}')"}; do
  install_name_tool -delete_rpath "$rpath" "$APP/Contents/MacOS/$EXECUTABLE" 2>/dev/null
done
# 发布的二进制不留调试映射：里面是本机源码和 .o 的路径（1852 有 47 处，发布回归 2026-11-08）。
# 先把调试符号另存到 build/<构建号>/（只留本机，用来看崩溃报告），再去掉。
dsymutil "$APP/Contents/MacOS/$EXECUTABLE" -o "$OUT_DIR/$EXECUTABLE.dSYM"
strip -S "$APP/Contents/MacOS/$EXECUTABLE"
# 应用图标直接用设计交付的 icns（镂空闪电团子 design/lightning-outline/final，2026-11-09 用户定），不在构建里重新导出，避免被别的源图或占位图覆盖。
[[ -s assets/icon/AppIcon.icns ]] || { echo "错误：缺少 assets/icon/AppIcon.icns" >&2; exit 1; }
cp assets/icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cmp -s assets/icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns" || { echo "错误：应用里的图标和 assets/icon/AppIcon.icns 不一致" >&2; exit 1; }
cp assets/icon/MenuBarIconTemplate.png "assets/icon/MenuBarIconTemplate@2x.png" "$APP/Contents/Resources/"
# 资源包放在 Contents/Resources/，代码（L10n.locateResources）在这里找。不放应用根目录：那里只能有 Contents，签名不合规。
# 不用 SwiftPM 的 Bundle.module：它只找应用根目录和本机构建目录，找不到就崩溃。
ditto "$BIN_DIR/$L10N_BUNDLE" "$APP/Contents/Resources/$L10N_BUNDLE"
diff -r "$BIN_DIR/$L10N_BUNDLE" "$APP/Contents/Resources/$L10N_BUNDLE" >/dev/null || { echo "错误：应用里的语言资源和构建结果不一致" >&2; exit 1; }
for lang in $LANGUAGES; do
  for table in Localizable.strings Localizable.stringsdict; do
    f="$APP/Contents/Resources/$L10N_BUNDLE/Contents/Resources/$lang.lproj/$table"
    [[ -s "$f" ]] && plutil -lint -s "$f" || { echo "错误：缺少或无法读取 $lang.lproj/$table" >&2; exit 1; }
  done
done
# 试用版说明：docs/ 里的原稿 → 应用里的文件（TrialNotes.text 按界面语言读）。
NOTES=(
  zh-Hans docs/trial-notes.md         TrialNotes.zh-Hans.md
  zh-Hant docs/trial-notes.zh-Hant.md TrialNotes.zh-Hant.md
  en      docs/trial-notes.en.md      TrialNotes.en.md
  ja      docs/trial-notes.ja.md      TrialNotes.ja.md
)
for lang source target in $NOTES; do
  sed -e "s/{{VERSION}}/$VERSION/g" -e "s/{{BUILD}}/$BUILD_STAMP/g" "$source" > "$APP/Contents/Resources/$target"
  grep -q "$BUILD_STAMP" "$APP/Contents/Resources/$target" || { echo "错误：$target 没有构建号" >&2; exit 1; }
done

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>ja</string><string>zh-Hans</string><string>zh-Hant</string></array>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Classic Companion</string>
  <key>CFBundleDisplayName</key><string>Classic Companion</string>
  <key>CFBundleExecutable</key><string>$EXECUTABLE</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_STAMP</string>
  <key>CCIconStatus</key><string>$ICON_STATUS</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
PLIST

if [[ "$SIGNING_MODE" == adhoc ]]; then
  # 说明模板按正式发布写（Developer ID + 公证，只有 package-release.sh --notarize 且 verify-release.sh --final 通过的包才能发）。
  # ad-hoc 构建改回实话；改后的句子 verify-release.sh --final 会拦下（发布回归 2026-11-08）。每种语言各一句。
  typeset -A SIGNED UNSIGNED
  SIGNED[TrialNotes.zh-Hans.md]='本版使用 Developer ID 签名，并经过 Apple 公证。第一次打开时，macOS 可能会弹出安全确认，确认是 Classic Companion 后选择打开即可。如果 macOS 提示无法打开，请不要更改系统的安全设置，可以到 Issues 反馈。'
  UNSIGNED[TrialNotes.zh-Hans.md]='本版没有 Developer ID 签名和 Apple 公证，只供本机测试。'
  SIGNED[TrialNotes.zh-Hant.md]='本版使用 Developer ID 簽署，並經過 Apple 公證。第一次打開時，macOS 可能會要求安全確認，確認是 Classic Companion 後選擇打開即可。如果 macOS 提示無法打開，請不要更改系統的安全設定，可以到 Issues 回饋。'
  UNSIGNED[TrialNotes.zh-Hant.md]='本版沒有 Developer ID 簽署和 Apple 公證，只供本機測試。'
  SIGNED[TrialNotes.en.md]='This build is signed with Developer ID and notarized by Apple. The first time you open it, macOS may ask you to confirm; check that it’s Classic Companion and choose to open it. If macOS says the app can’t be opened, don’t change your Mac’s security settings; please report it on Issues instead.'
  UNSIGNED[TrialNotes.en.md]='This build has no Developer ID signature or Apple notarization and is for local testing only.'
  SIGNED[TrialNotes.ja.md]='このビルドは Developer ID で署名され、Apple の公証を受けています。初めて開くとき、macOS が確認を求めることがあります。Classic Companion であることを確かめてから開いてください。開けないと表示された場合は、Mac のセキュリティ設定を変更せず、Issues でお知らせください。'
  UNSIGNED[TrialNotes.ja.md]='このビルドには Developer ID の署名と Apple の公証がなく、このマシンでのテスト専用です。'
  for target in ${(k)SIGNED}; do
    f="$APP/Contents/Resources/$target"
    content="$(<"$f")"
    [[ "$content" == *"${SIGNED[$target]}"* ]] || { echo "错误：$target 里找不到签名说明句" >&2; exit 1; }
    print -r -- "${content//${(b)SIGNED[$target]}/${UNSIGNED[$target]}}" > "$f"
    grep -qF -- "${UNSIGNED[$target]}" "$f" || { echo "错误：ad-hoc 构建的 $target 没改成未签名" >&2; exit 1; }
  done
fi
if [[ "$SIGNING_MODE" == developer-id ]]; then
  codesign --force --sign "$CC_SIGNING_IDENTITY" --options runtime --timestamp "$APP"
  verify_developer_signature "$APP" runtime
else
  codesign --force --sign - --timestamp=none "$APP"
fi
codesign --verify --deep --strict "$APP"
echo "$BUILD_STAMP" > build/LATEST

if [[ "$ICON_STATUS" != final ]]; then
  echo "注意：图标状态为 $ICON_STATUS，当前是临时占位图标，不是最终图标。"
fi
echo "Built $APP  version=$VERSION build=$BUILD_STAMP"
