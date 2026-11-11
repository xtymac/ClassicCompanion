#!/bin/zsh
# 把一次构建打包成 DMG、ZIP，并保存对应源码快照。只写新目录，不上传 GitHub，不覆盖已有发布目录；--notarize 会上传成品到 Apple 公证服务。
# 用法：scripts/package-release.sh [--notarize] [构建号]   默认最近一次构建
#
# 目录：
#   upload/      只有这里的文件可以上传：DMG、ZIP、每种界面语言一份试用版说明（TrialNotes.zh-Hans.md、.zh-Hant.md、.en.md、.ja.md）、SHA256SUMS。
#                不要上传整个发布目录。说明用 ASCII 文件名：GitHub 会改掉 Release 附件名里的中文。
#   local-only/  源码快照和调试符号，只留本机。
# SHA256SUMS 最后生成。加上公证后的顺序（发布回归 2026-11-08）：
#   1. 应用用 Developer ID 签名（加固运行时、时间戳）
#   2. 应用压成临时 ZIP 提交公证，等状态 Accepted
#   3. 给应用附票据
#   4. 用附了票据的应用制作 ZIP 和 DMG
#   5. DMG 签名、提交公证、等 Accepted、附票据
#   6. 最后生成 SHA256SUMS；回归和上传都用这同一份成品
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
source scripts/release-signing.sh
NOTARIZE=0
if [[ "${1:-}" == --notarize ]]; then NOTARIZE=1; shift; fi
if (( NOTARIZE )); then
  signing_preflight
  xcrun notarytool history --keychain-profile "$CC_NOTARY_PROFILE" --output-format json >/dev/null
fi

BUILD="${1:-$(<build/LATEST)}"
APP="build/$BUILD/Classic Companion.app"
if [[ ! -d "$APP" ]]; then
  echo "错误：找不到 $APP" >&2
  exit 1
fi
PLIST="$APP/Contents/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUNDLE_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
if [[ "$BUNDLE_BUILD" != "$BUILD" ]]; then
  echo "错误：应用构建号是 $BUNDLE_BUILD，不是 $BUILD" >&2
  exit 1
fi

RELEASES="$(cd .. && pwd)/ChatGPT-Classic-Companion-releases"
DEST="$RELEASES/trial-$VERSION-$BUILD"
if [[ -e "$DEST" ]]; then
  echo "错误：$DEST 已存在，不覆盖" >&2
  exit 1
fi
STEM="ClassicCompanion-$VERSION-$BUILD-arm64"
LOCAL="$DEST/local-only"
UPLOAD="$DEST/upload"
mkdir -p "$LOCAL" "$UPLOAD"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
# 不带扩展属性和资源分叉：1852 的 ZIP 带着本机来源标记 com.apple.provenance，解开有 __MACOSX（发布回归 2026-11-08）。签名不在扩展属性里，不受影响。
ditto --norsrc --noextattr --noqtn --noacl "$APP" "$STAGE/Classic Companion.app"
if (( NOTARIZE )); then
  verify_developer_signature "$STAGE/Classic Companion.app" runtime
  ditto -c -k --norsrc --noextattr --noqtn --keepParent "$STAGE/Classic Companion.app" "$LOCAL/app-submission.zip"
  notarize_file "$LOCAL/app-submission.zip" "$LOCAL/app-notary"
  xcrun stapler staple "$STAGE/Classic Companion.app"
  xcrun stapler validate "$STAGE/Classic Companion.app"
fi
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Classic Companion" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 "$UPLOAD/$STEM.dmg"
ditto -c -k --norsrc --noextattr --noqtn --noacl --keepParent "$STAGE/Classic Companion.app" "$UPLOAD/$STEM.zip"
if (( NOTARIZE )); then
  codesign --force --sign "$CC_SIGNING_IDENTITY" --timestamp "$UPLOAD/$STEM.dmg"
  verify_developer_signature "$UPLOAD/$STEM.dmg"
  notarize_file "$UPLOAD/$STEM.dmg" "$LOCAL/dmg-notary"
  xcrun stapler staple "$UPLOAD/$STEM.dmg"
  xcrun stapler validate "$UPLOAD/$STEM.dmg"
fi
NOTES=(TrialNotes.zh-Hans.md TrialNotes.zh-Hant.md TrialNotes.en.md TrialNotes.ja.md)
for notes in $NOTES; do cp "$STAGE/Classic Companion.app/Contents/Resources/$notes" "$UPLOAD/$notes"; done

# 源码快照含验收记录（有测试对话名称），只留在本机，不随试用版外发。
scripts/snapshot-source.sh "$LOCAL/source-$VERSION-$BUILD.tar.gz"
# 调试符号只留本机（用来看崩溃报告），不随试用版外发。
DSYM="$(dirname "$APP")/ClassicCompanion.dSYM"
[[ -d "$DSYM" ]] && ditto -c -k --keepParent "$DSYM" "$LOCAL/ClassicCompanion-$VERSION-$BUILD.dSYM.zip"
(cd "$UPLOAD" && shasum -a 256 "$STEM.dmg" "$STEM.zip" $NOTES > SHA256SUMS)
(cd "$LOCAL" && shasum -a 256 "source-$VERSION-$BUILD.tar.gz" > SHA256SUMS)

if (( NOTARIZE )); then
  scripts/verify-release.sh --notarized "$DEST"
fi
echo "Packaged $DEST（只上传 upload/ 里的文件）"
