#!/bin/zsh
# 检查一个发布目录：校验值、DMG 结构、ZIP 与 DMG 内应用一致、签名、Info.plist、资源、架构和系统版本。
# 只读检查，不安装，不代替真实 UI 验证。
# 用法：scripts/verify-release.sh [--final|--notarized] 发布目录
# --notarized：验证真实签名、公证和打包，但不豁免 --final 的图标/说明门槛。
#   不带 --final：只证明打包流程正确，ad-hoc 签名和占位图标也能全过。
#   --final：正式发布才用，另外要求 Developer ID、预期 Team ID、加固运行时、时间戳、公证票据、
#            Gatekeeper 接受、正式图标、随包说明没有未定事项。任何一项不过都不能发布（发布回归 2026-11-08）。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/update-config.sh"
source "$ROOT/scripts/sparkle-embed.sh"

FINAL=0
NOTARIZED=0
if [[ "${1:-}" == --final ]]; then FINAL=1; NOTARIZED=1; shift
elif [[ "${1:-}" == --notarized ]]; then NOTARIZED=1; shift; fi
DEST="${1:?用法：scripts/verify-release.sh [--final] 发布目录}"
EXPECTED_TEAM="${CC_TEAM_ID:?Set CC_TEAM_ID to the expected signing team}"
failures=0
check() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "通过  $label"; else echo "失败  $label"; failures=$((failures + 1)); fi
}
has() { grep -qE -- "$1" <<<"$2"; }
lacks() { ! grep -qE -- "$1" "$2"; }
gatekeeper() {
  local assessment
  assessment="$(spctl --assess "$@" -vv 2>&1)" || return 1
  has 'accepted' "$assessment" && has 'source=Notarized Developer ID' "$assessment"
}

# 只有 upload/ 里的文件可以上传：恰好一个 DMG、一个 ZIP、每种界面语言一份试用版说明和 SHA256SUMS，校验值覆盖其余每个文件。文件数按 NOTES 算，不写死。
NOTES=(TrialNotes.zh-Hans.md TrialNotes.zh-Hant.md TrialNotes.en.md TrialNotes.ja.md)
LANGUAGES=(en ja zh-Hans zh-Hant)
L10N="ClassicCompanion_ClassicCompanion.bundle"
if [[ -d "$DEST/upload" ]]; then
  echo "通过  有 upload/ 目录"
  cd "$DEST/upload"
else
  echo "失败  没有 upload/ 目录（旧布局，上传时容易把 local-only/ 带出去）"; failures=$((failures + 1))
  cd "$DEST"
fi
upload_ok() {
  local all=(*(ND)) dmg=(*.dmg(N)) zip=(*.zip(N))   # ND：连隐藏文件和子目录一起数
  (( ${#all} == 3 + ${#NOTES} && ${#dmg} == 1 && ${#zip} == 1 )) && [[ -f SHA256SUMS ]] || return 1
  local n; for n in $NOTES; do [[ -f "$n" ]] || return 1; done
  [[ "$(awk '{print $2}' SHA256SUMS | sort)" == "$(print -l $dmg $zip $NOTES | sort)" ]]
}
check "上传目录只有 DMG、ZIP、${#NOTES} 份试用版说明、SHA256SUMS（共 $((3 + ${#NOTES})) 个），校验值覆盖全部" upload_ok
check "SHA256SUMS" shasum -a 256 -c SHA256SUMS
DMG=(*.dmg(N)); ZIP=(*.zip(N))
if (( ${#DMG} != 1 || ${#ZIP} != 1 )); then
  echo "失败  需要恰好一个 DMG 和一个 ZIP"
  exit 1
fi

WORK="$(mktemp -d)"
MOUNT="$WORK/mount"
mkdir "$MOUNT"
trap 'hdiutil detach -quiet "$MOUNT" 2>/dev/null || true; rm -rf "$WORK"' EXIT
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$MOUNT" "$DMG[1]"
APP="$MOUNT/Classic Companion.app"
PLIST="$APP/Contents/Info.plist"
BIN="$APP/Contents/MacOS/ClassicCompanion"
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null; }

check "DMG 含应用" test -d "$APP"
[[ "$(readlink "$MOUNT/Applications")" == /Applications ]]; check "DMG 含 Applications 快捷方式" test "$?" -eq 0
ditto -x -k "$ZIP[1]" "$WORK/zip"
check "ZIP 内应用与 DMG 一致" diff -r "$APP" "$WORK/zip/Classic Companion.app"
check "签名完整" codesign --verify --deep --strict "$APP"
check "资源 AppIcon.icns" test -s "$APP/Contents/Resources/AppIcon.icns"
for n in $NOTES; do
  check "资源 $n" test -s "$APP/Contents/Resources/$n"
  check "上传的 $n 和应用里的一致" cmp -s "$n" "$APP/Contents/Resources/$n"
done
# 界面语言资源：资源包在 Contents/Resources/（L10n.locateResources 在这里找），每种语言的表都在且能读，键数一样。
L10N_RES="$APP/Contents/Resources/$L10N/Contents/Resources"
check "资源 语言资源包" test -d "$L10N_RES"
key_counts=()
for lang in $LANGUAGES; do
  for table in Localizable.strings Localizable.stringsdict; do
    check "资源 $lang.lproj/$table 可读" plutil -lint -s "$L10N_RES/$lang.lproj/$table"
  done
  key_counts+=("$(plutil -convert json -o - "$L10N_RES/$lang.lproj/Localizable.strings" 2>/dev/null | /usr/bin/python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null || echo 0)")
done
[[ ${#key_counts} == ${#LANGUAGES} && ${key_counts[1]} -gt 100 && ${#${(u)key_counts}} == 1 ]]
check "${#LANGUAGES} 种语言的字符串表键数一样（${(j:/:)key_counts}）" test "$?" -eq 0
[[ "$(plist CFBundleDevelopmentRegion)" == en ]]; check "Info.plist 开发语言 en" test "$?" -eq 0
[[ "$(plist CFBundleLocalizations | tr -d ' ' | grep -v '^Array\|^}' | sort | tr '\n' ' ')" == "en ja zh-Hans zh-Hant " ]]
check "Info.plist 声明 en、ja、zh-Hans、zh-Hant" test "$?" -eq 0
check "资源 菜单栏图标 1x" test -s "$APP/Contents/Resources/MenuBarIconTemplate.png"
check "资源 菜单栏图标 2x" test -s "$APP/Contents/Resources/MenuBarIconTemplate@2x.png"
! plist LSUIElement >/dev/null; check "没有 LSUIElement" test "$?" -eq 0
[[ "$(plist CFBundleIdentifier)" == local.classiccompanion.ClassicCompanion ]]; check "Bundle ID 未变（登录数据按它存放）" test "$?" -eq 0
[[ "$(plist CFBundleIconFile)" == AppIcon ]]; check "Info.plist 指向图标" test "$?" -eq 0
[[ "$(lipo -archs "$BIN")" == arm64 ]]; check "架构只有 arm64" test "$?" -eq 0

BINARY_MIN="$(vtool -show-build "$BIN" | awk '/minos/ {print $2}')"
[[ "$BINARY_MIN" == "$(plist LSMinimumSystemVersion)" ]]; check "二进制最低系统与 Info.plist 一致" test "$?" -eq 0
BUILD="$(plist CFBundleVersion)"
for n in $NOTES; do
  grep -q "$BUILD" "$APP/Contents/Resources/$n"; check "$n 的构建号与应用一致" test "$?" -eq 0
done
# 系统之外只允许应用自带的 Sparkle.framework（应用内更新）。
if otool -L "$BIN" | tail -n +2 | awk '{print $1}' | grep -Ev '^(/usr/lib/|/System/Library/|@rpath/Sparkle\.framework/Versions/B/Sparkle$)' >/dev/null; then
  echo "失败  存在系统和自带 Sparkle 之外的动态库依赖"; failures=$((failures + 1))
else
  echo "通过  动态库只依赖系统和自带的 Sparkle"
fi
RPATHS="$(otool -l "$BIN" | awk '$1 == "cmd" && $2 == "LC_RPATH" {getline; getline; print $2}' | sort | tr '\n' ' ')"
[[ "$RPATHS" == "/usr/lib/swift @executable_path/../Frameworks " || "$RPATHS" == "@executable_path/../Frameworks /usr/lib/swift " ]]
check "rpath 只有系统 Swift 库和 Contents/Frameworks（$RPATHS）" test "$?" -eq 0

# 应用内更新（docs/updates.md）：框架结构和签名、正式 feed、公钥、渠道、不自动安装。
SPARKLE_PROBLEMS="$(check_sparkle_embedding "$APP" $( (( NOTARIZED )) && echo "$EXPECTED_TEAM") 2>&1 >/dev/null || true)"
[[ -z "$SPARKLE_PROBLEMS" ]]; check "更新：Sparkle.framework 结构、arm64、逐层签名${SPARKLE_PROBLEMS:+（$SPARKLE_PROBLEMS）}" test "$?" -eq 0
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Frameworks/Sparkle.framework/Resources/Info.plist" 2>/dev/null)" == "$CC_SPARKLE_VERSION" ]]
check "更新：Sparkle 版本 $CC_SPARKLE_VERSION" test "$?" -eq 0
check "更新：附有 Sparkle 的 MIT 许可声明（Contents/Resources/Licenses/Sparkle-LICENSE.txt）" grep -q "Permission is hereby granted" "$APP/Contents/Resources/Licenses/Sparkle-LICENSE.txt"
FEED="$(plist SUFeedURL || true)"
[[ "$FEED" == "$CC_UPDATE_FEED_URL" && "$FEED" == https://* ]]; check "更新：feed 是正式的 HTTPS 地址（$FEED）" test "$?" -eq 0
check "更新：没有测试 feed、本机地址" lacks '127\.0\.0\.1|localhost|update-test|CC Update Test' "$PLIST"
! plist NSAppTransportSecurity >/dev/null; check "更新：没有 ATS 例外" test "$?" -eq 0
[[ "$(plist SUPublicEDKey)" == "$CC_UPDATE_PUBLIC_ED_KEY" ]]; check "更新：公钥是正式公钥" test "$?" -eq 0
[[ "$(plist CCUpdateChannel)" == "$(cc_update_channel "$(plist CFBundleShortVersionString)")" ]]
check "更新：渠道 $(plist CCUpdateChannel) 与版本号 $(plist CFBundleShortVersionString) 一致" test "$?" -eq 0
[[ "$(plist SUAllowsAutomaticUpdates)" == false && "$(plist SURequireSignedFeed)" == true && "$(plist SUVerifyUpdateBeforeExtraction)" == true ]]
check "更新：不自动安装、appcast 必须签名、先验签再解压" test "$?" -eq 0
! plist SUAutomaticallyUpdate >/dev/null && ! plist SUEnableAutomaticChecks >/dev/null
check "更新：不预设自动下载和自动检查（第二次启动时询问）" test "$?" -eq 0
# 按字节查整个应用，不用 strings：本机的 strings 看不到符号字符串表，1852 里 47 处本机路径它报 0（发布回归 2026-11-08）。
if LC_ALL=C grep -rlaq "$HOME" "$APP"; then
  echo "失败  应用含本机用户目录路径"; failures=$((failures + 1))
else
  echo "通过  应用不含本机用户目录路径"
fi
# 管道里不用 grep -q：pipefail 下 grep 提前退出会让前面的命令收到 SIGPIPE，整条管道算失败，检查就成了假通过。
if nm -ap "$BIN" 2>/dev/null | grep -E ' (SO|OSO|SOL) ' >/dev/null; then
  echo "失败  二进制留着调试映射（源文件和 .o 路径）"; failures=$((failures + 1))
else
  echo "通过  二进制没有调试映射"
fi
# 用户选“收起两项”（发布回归 2026-11-08）：发布版不带 DebugDriver（它收 local.classiccompanion.debug 通知、往网页发鼠标事件）。
if LC_ALL=C grep -aE 'local\.classiccompanion\.debug|debugDriver' "$BIN" >/dev/null; then
  echo "失败  发布版还带着 DebugDriver"; failures=$((failures + 1))
else
  echo "通过  发布版不带 DebugDriver"
fi
if unzip -l "$ZIP[1]" | grep '__MACOSX/' >/dev/null; then
  echo "失败  ZIP 带本机扩展属性（__MACOSX）"; failures=$((failures + 1))
else
  echo "通过  ZIP 不带扩展属性"
fi

if (( NOTARIZED )); then
  APP_SIG="$(codesign -dvv "$APP" 2>&1)"
  DMG_SIG="$(codesign -dvv "$DMG[1]" 2>&1 || true)"
  check "正式：应用是 Developer ID Application 签名" has '^Authority=Developer ID Application: ' "$APP_SIG"
  check "正式：Team ID 是 $EXPECTED_TEAM" has "^TeamIdentifier=$EXPECTED_TEAM\$" "$APP_SIG"
  check "正式：加固运行时" has 'flags=0x[0-9a-f]+\([^)]*runtime' "$APP_SIG"
  check "正式：签名带安全时间戳" has '^Timestamp=' "$APP_SIG"
  check "正式：DMG 应用附了公证票据" xcrun stapler validate "$APP"
  check "正式：ZIP 应用附了公证票据" xcrun stapler validate "$WORK/zip/Classic Companion.app"
  check "正式：DMG 是 Developer ID Application 签名" has '^Authority=Developer ID Application: ' "$DMG_SIG"
  check "正式：DMG Team ID 正确" has "^TeamIdentifier=$EXPECTED_TEAM\$" "$DMG_SIG"
  check "正式：DMG 带安全时间戳" has '^Timestamp=' "$DMG_SIG"
  check "正式：DMG 签名完整" codesign --verify --strict "$DMG[1]"
  check "正式：DMG 附了公证票据" xcrun stapler validate "$DMG[1]"
  check "正式：Gatekeeper 接受应用（已公证的 Developer ID）" gatekeeper --type execute "$APP"
  check "正式：Gatekeeper 来源是已公证" has 'source=Notarized Developer ID' "$(spctl --assess --type execute -vv "$APP" 2>&1)"
  check "正式：Gatekeeper 接受 DMG" gatekeeper --type open --context context:primary-signature "$DMG[1]"
fi
if (( FINAL )); then
  check "正式：图标状态是 final" test "$(plist CCIconStatus)" = final
  check "正式：更新 feed 地址已确认（scripts/update-config.sh CC_UPDATE_FEED_CONFIRMED=1）" test "$CC_UPDATE_FEED_CONFIRMED" = 1
  [[ "$("$ROOT/scripts/sparkle-key.sh" public "$CC_UPDATE_KEY_ACCOUNT" 2>/dev/null)" == "$(plist SUPublicEDKey)" ]]
  check "正式：钥匙串里有和应用公钥配对的更新私钥（以后能给这个版本发更新）" test "$?" -eq 0
  for n in $NOTES; do
    check "正式：$n 没有未定事项（未签名、占位图标、反馈地址未定）" lacks '没有 Developer ID|临时占位|尚未确定|沒有 Developer ID|暫時佔位|尚未確定|has no Developer ID|placeholder icon|Developer ID の署名と Apple の公証がなく|仮のアイコン' "$APP/Contents/Resources/$n"
  done
fi

echo
echo "检查模式：$( (( FINAL )) && echo 正式发布 || { (( NOTARIZED )) && echo 已公证流程验证（不代表可以发布） || echo 打包流程（不代表可以发布）; })"
echo "版本 $(plist CFBundleShortVersionString)  构建 $BUILD  最低 macOS $BINARY_MIN  图标状态 $(plist CCIconStatus)"
echo "签名：$(codesign -dv "$APP" 2>&1 | grep -E '^(Signature|Authority|TeamIdentifier|Timestamp)=' )"
echo "Gatekeeper：$(spctl --assess --type execute -vv "$APP" 2>&1 | head -2 | tr '\n' ' ')"
(( failures == 0 )) || { echo "有 $failures 项失败" >&2; exit 1; }
