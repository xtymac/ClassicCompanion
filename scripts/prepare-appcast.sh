#!/bin/zsh
# 为一个已公证的发布目录生成更新清单（appcast）。只在本机生成和检查，不上传、不改线上 feed、不发布。
# 发布顺序和说明见 docs/updates.md "Release order"。
#
# 用法：
#   scripts/prepare-appcast.sh [--dry-run] [--base 现有appcast.xml] [--tag 标签] 发布目录 更新说明.html
#
# 正式模式（默认）：
#   1. 发布目录必须通过 verify-release.sh --final（Developer ID、公证票据、Gatekeeper、正式图标、feed 地址已确认、
#      钥匙串里有配对的更新私钥）。未公证、草稿、测试包到不了下一步。
#   2. 以线上现有 appcast 为底（--base 指定本地文件，或从 CC_UPDATE_FEED_URL 读取；404 视为第一次发布），
#      先用正式公钥验证它的签名；只放进这一个 ZIP，用 Sparkle 的 generate_appcast 加一个条目，旧条目原样保留。
#   3. 检查：feed 签名、新条目的版本/构建号/渠道/最低系统/架构/下载地址/长度/EdDSA 签名、旧条目都在、
#      全部地址是 HTTPS、没有测试地址。
#   4. 写到 发布目录/appcast/（appcast.xml 和 appcast-report.txt），并打印之后的手动发布步骤。
# --dry-run：只要求 verify-release.sh（打包流程）通过，在临时目录里走完同样的生成和检查，
#   只留下报告，不留下用正式密钥签过的清单（未公证的包不能有可发布的清单）。
#
# 更新说明：一段 HTML 片段（没有 DOCTYPE、body），四种语言各一节，带 lang="en" / "zh-Hans" / "zh-Hant" / "ja"。
# 会嵌进 appcast（Sparkle 更新窗口里显示）。
set -euo pipefail
unsetopt xtrace 2>/dev/null || true
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/update-config.sh"

DRY_RUN=0; BASE=""; TAG=""
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --base) BASE="$2"; shift 2 ;;
    --tag) TAG="$2"; shift 2 ;;
    *) echo "未知选项 $1" >&2; exit 2 ;;
  esac
done
DEST="${1:?用法：scripts/prepare-appcast.sh [--dry-run] [--base appcast.xml] [--tag 标签] 发布目录 更新说明.html}"
NOTES="${2:?缺少更新说明 HTML}"
DEST="$(cd "$DEST" && pwd)"
die() { echo "错误：$*" >&2; exit 1; }

# 私钥只在管道里（docs/updates.md "Key custody"）。
with_key() { security find-generic-password -s "$CC_UPDATE_KEY_SERVICE" -a "$CC_UPDATE_KEY_ACCOUNT" -w | "$@"; }
"$ROOT/scripts/sparkle-key.sh" exists "$CC_UPDATE_KEY_ACCOUNT" || die "钥匙串里没有正式更新私钥（$CC_UPDATE_KEY_SERVICE / $CC_UPDATE_KEY_ACCOUNT）"
[[ "$("$ROOT/scripts/sparkle-key.sh" public "$CC_UPDATE_KEY_ACCOUNT")" == "$CC_UPDATE_PUBLIC_ED_KEY" ]] ||
  die "钥匙串里的私钥和 update-config.sh 的公钥不配对"

echo "== 1. 检查发布目录"
if (( DRY_RUN )); then
  "$ROOT/scripts/verify-release.sh" "$DEST" > /dev/null || die "verify-release.sh 没通过"
  echo "打包流程检查通过（演练：不要求公证，结果不能发布）"
else
  "$ROOT/scripts/verify-release.sh" --final "$DEST" > /dev/null || die "verify-release.sh --final 没通过：未公证、草稿或测试包不能进更新清单"
  echo "正式发布检查通过"
fi
ZIP=("$DEST/upload/"*.zip(N))
(( ${#ZIP} == 1 )) || die "upload/ 里要恰好一个 ZIP"
ZIP="$ZIP[1]"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ditto -x -k "$ZIP" "$WORK/unzipped"
PLIST="$WORK/unzipped/Classic Companion.app/Contents/Info.plist"
pl() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST"; }
VERSION="$(pl CFBundleShortVersionString)"
BUILD="$(pl CFBundleVersion)"
MIN_OS="$(pl LSMinimumSystemVersion)"
CHANNEL="$(cc_update_channel "$VERSION")"
[[ "$(pl CCUpdateChannel)" == "$CHANNEL" ]] || die "应用里的渠道 $(pl CCUpdateChannel) 和版本号 $VERSION 不一致"
[[ "$(pl SUPublicEDKey)" == "$CC_UPDATE_PUBLIC_ED_KEY" ]] || die "应用里的公钥不是正式公钥"
[[ "$(pl SUFeedURL)" == "$CC_UPDATE_FEED_URL" ]] || die "应用里的 feed 地址不是正式地址"
TAG="${TAG:-v$VERSION}"
PREFIX="$CC_UPDATE_DOWNLOAD_BASE/$TAG/"
URL="$PREFIX${ZIP:t}"
echo "版本 $VERSION  构建 $BUILD  渠道 $CHANNEL  下载地址 $URL"

echo "== 2. 更新说明"
[[ -s "$NOTES" ]] || die "找不到更新说明 $NOTES"
! grep -qiE '<!doctype|<body' "$NOTES" || die "更新说明要是 HTML 片段（不要 DOCTYPE、body）"
for lang in en zh-Hans zh-Hant ja; do grep -q "lang=\"$lang\"" "$NOTES" || die "更新说明缺少 lang=\"$lang\" 一节"; done
! grep -qE '127\.0\.0\.1|localhost|CC Update Test|update-test' "$NOTES" || die "更新说明里有测试内容"

echo "== 3. 底稿（现有 appcast）"
STAGE="$WORK/stage"
mkdir "$STAGE"
if [[ -n "$BASE" ]]; then
  cp "$BASE" "$STAGE/appcast.xml"
  echo "用本地底稿 $BASE"
else
  code="$(curl -sS -L --proto '=https' -o "$STAGE/appcast.xml" -w '%{http_code}' "$CC_UPDATE_FEED_URL" || echo 000)"
  case "$code" in
    200) echo "读取了线上 appcast" ;;
    404) rm -f "$STAGE/appcast.xml"; echo "线上还没有 appcast：第一次发布" ;;
    *) die "读取线上 appcast 失败（HTTP $code）；可以用 --base 指定本地底稿" ;;
  esac
fi
OLD_VERSIONS=(); OLD_SIGNATURES=()
if [[ -f "$STAGE/appcast.xml" ]]; then
  with_key "$CC_SPARKLE_BIN/sign_update" --verify --ed-key-file - "$STAGE/appcast.xml" >/dev/null 2>&1 ||
    die "现有 appcast 的签名用正式公钥验证不过，不在它上面继续"
  OLD_VERSIONS=(${(f)"$(grep -o '<sparkle:version>[^<]*' "$STAGE/appcast.xml" | sed 's/<sparkle:version>//')"})
  OLD_SIGNATURES=(${(f)"$(grep -o 'sparkle:edSignature="[^"]*"' "$STAGE/appcast.xml" || true)"})
  (( ${OLD_VERSIONS[(Ie)$BUILD]} == 0 )) || die "appcast 里已经有构建 $BUILD"
fi

echo "== 4. generate_appcast（Sparkle $CC_SPARKLE_VERSION）"
cp "$ZIP" "$STAGE/"
cp "$NOTES" "$STAGE/${ZIP:t:r}.html"
args=(--download-url-prefix "$PREFIX" --maximum-deltas 0 --maximum-versions 0 --embed-release-notes)
[[ "$CHANNEL" == beta ]] && args+=(--channel beta)
output="$(with_key "$CC_SPARKLE_BIN/generate_appcast" --ed-key-file - "${args[@]}" "$STAGE" 2>&1)" || die "generate_appcast 失败：$output"
! grep -qi 'does not match\|error' <<<"$output" || die "generate_appcast 报告问题：$output"
FEED="$STAGE/appcast.xml"

echo "== 5. 检查生成的 appcast"
failures=0
check() { local label="$1"; shift; if "$@" >/dev/null 2>&1; then echo "通过  $label"; else echo "失败  $label"; failures=$((failures + 1)); fi; }
# 只解析刚由 generate_appcast 在本机生成的文件（没有外部实体）。
item="$(/usr/bin/python3 -I - "$FEED" "$BUILD" <<'PY'
import sys, xml.etree.ElementTree as ET
S = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
path, build = sys.argv[1:]
items = [i for i in ET.parse(path).getroot().iter("item") if i.findtext(S + "version") == build]
if len(items) != 1:
    sys.exit(1)
i = items[0]
e = i.find("enclosure")
print("\t".join([
    i.findtext(S + "shortVersionString") or "", i.findtext(S + "channel") or "",
    i.findtext(S + "minimumSystemVersion") or "", i.findtext(S + "hardwareRequirements") or "",
    e.get("url") or "", e.get("length") or "", e.get(S + "edSignature") or "",
    "yes" if (i.findtext("description") or "").strip() else "no",
]))
PY
)" || die "新条目没有生成或者重复"
IFS=$'\t' read -r short chan minos hw url length sig desc <<<"$item"
check "feed 签名用正式公钥验证通过" with_key "$CC_SPARKLE_BIN/sign_update" --verify --ed-key-file - "$FEED"
check "新条目版本 $short / 构建 $BUILD" test "$short" = "$VERSION"
if [[ "$CHANNEL" == beta ]]; then check "新条目在 beta 渠道" test "$chan" = beta
else check "新条目在默认渠道（正式版）" test -z "$chan"; fi
check "最低系统 $minos 和应用一致" test "$minos" = "$MIN_OS"
check "架构要求 arm64" test "$hw" = arm64
check "下载地址 $url" test "$url" = "$URL"
check "长度和 ZIP 一致" test "$length" = "$(stat -f %z "$ZIP")"
check "更新包 EdDSA 签名用正式公钥验证通过" with_key "$CC_SPARKLE_BIN/sign_update" --verify --ed-key-file - "$ZIP" "$sig"
check "嵌入了更新说明" test "$desc" = yes
check "全部地址是 HTTPS" test -z "$(grep -oE '(url|href|src)="[^"]*"|<(link|sparkle:releaseNotesLink|sparkle:fullReleaseNotesLink)[^>]*>[^<]*' "$FEED" | grep -v 'https://' || true)"
check "没有测试地址和测试名字" test -z "$(grep -E '127\.0\.0\.1|localhost|CCUpdateTest|CC Update Test|update-test' "$FEED" || true)"
for v in $OLD_VERSIONS; do check "旧条目 $v 还在" grep -q "<sparkle:version>$v</sparkle:version>" "$FEED"; done
for sig in $OLD_SIGNATURES; do check "旧条目的更新包签名没变（${sig:21:12}…）" grep -qF -- "$sig" "$FEED"; done
(( failures == 0 )) || die "有 $failures 项检查失败"

summary="版本 $VERSION（构建 $BUILD），渠道 $CHANNEL，下载 $URL，条目数 $(grep -c '<item>' "$FEED")"
if (( DRY_RUN )); then
  REPORT="$DEST/local-only/appcast-dryrun-report.txt"
  { echo "演练（不能发布）$(date '+%Y-%m-%d %H:%M')"; echo "$summary"; echo "所有检查通过；用正式密钥签过的清单已删除。"; } > "$REPORT"
  echo
  echo "演练完成：$summary"
  echo "报告：$REPORT（没有留下可发布的清单）"
  exit 0
fi

OUT="$DEST/appcast"
[[ ! -e "$OUT" ]] || die "$OUT 已存在，不覆盖"
mkdir "$OUT"
cp "$FEED" "$OUT/appcast.xml"
{ echo "$(date '+%Y-%m-%d %H:%M')  $summary"; echo "feed：$CC_UPDATE_FEED_URL"; } > "$OUT/appcast-report.txt"
cat <<NEXT

更新清单已生成：$OUT/appcast.xml（只在本机，没有上传）
$summary

之后的步骤（手动，按顺序；见 docs/updates.md "Release order"）：
  1. 在 xtymac/ClassicCompanion 发布 $TAG，附件用 $DEST/upload/ 里的文件（ZIP 必须是这一个，不能重新打包）。
  2. 确认下载地址可用且内容一致：
       curl -fsSL -o /tmp/cc-check.zip "$URL" && shasum -a 256 /tmp/cc-check.zip（和 upload/SHA256SUMS 对照）
  3. 最后才发布 appcast：把 $OUT/appcast.xml 原样放到 $CC_UPDATE_FEED_URL（不要再手改；要改就重新生成）。
  4. 发布后：curl -fsSL "$CC_UPDATE_FEED_URL" | diff - "$OUT/appcast.xml"
NEXT
