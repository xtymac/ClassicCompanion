#!/bin/zsh
# 恢复已提交的流程：只查询已有应用 ID；已有 DMG ID 时也绝不重提。
# 必须在原 package-release 进程退出后运行。
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/release-signing.sh
BUILD="${1:?用法：scripts/resume-notarization.sh 构建号}"
APP="build/$BUILD/Classic Companion.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
DEST="$(cd .. && pwd)/ChatGPT-Classic-Companion-releases/trial-$VERSION-$BUILD"
LOCAL="$DEST/local-only"
UPLOAD="$DEST/upload"
STEM="ClassicCompanion-$VERSION-$BUILD-arm64"
[[ -s "$LOCAL/app-notary-submit.plist" && -s "$LOCAL/app-submission.zip" ]] || exit 1
LOCK="$LOCAL/resume.lock"
mkdir "$LOCK" || { echo '已有恢复任务或残留锁，请先核对进程。' >&2; exit 1; }
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"; rmdir "$LOCK"' EXIT

wait_existing() {
  local record="$1" request_id state
  request_id=$(/usr/libexec/PlistBuddy -c 'Print :id' "$record-submit.plist")
  while true; do
    xcrun notarytool info "$request_id" --keychain-profile "$CC_NOTARY_PROFILE" --output-format plist > "$record-info.plist"
    state=$(/usr/libexec/PlistBuddy -c 'Print :status' "$record-info.plist")
    echo "$(date '+%Y-%m-%d %H:%M:%S') $request_id: $state"
    case "$state" in
      Accepted)
        cp "$record-info.plist" "$record-result.plist"
        xcrun notarytool log "$request_id" --keychain-profile "$CC_NOTARY_PROFILE" "$record-log.json"
        return 0 ;;
      'In Progress')
        # 本地超时不改变 Apple 请求；下一轮继续 info 同一 ID。
        xcrun notarytool wait "$request_id" --keychain-profile "$CC_NOTARY_PROFILE" --timeout 60s --output-format plist > "$record-wait.plist" || true ;;
      *)
        xcrun notarytool log "$request_id" --keychain-profile "$CC_NOTARY_PROFILE" "$record-log.json" || true
        echo "公证未通过：$state" >&2; return 1 ;;
    esac
  done
}

wait_existing "$LOCAL/app-notary"
if [[ ! -s "$LOCAL/dmg-notary-submit.plist" ]]; then
  # 从已提交的原始 ZIP 恢复，而不是重新构建或读取可能改动过的应用。
  ditto -x -k "$LOCAL/app-submission.zip" "$STAGE"
  verify_developer_signature "$STAGE/Classic Companion.app" runtime
  xcrun stapler staple "$STAGE/Classic Companion.app"
  xcrun stapler validate "$STAGE/Classic Companion.app"
  if [[ ! -e "$UPLOAD/$STEM.zip" ]]; then
    ditto -c -k --norsrc --noextattr --noqtn --noacl --keepParent "$STAGE/Classic Companion.app" "$UPLOAD/$STEM.zip"
  fi
  if [[ ! -e "$UPLOAD/$STEM.dmg" ]]; then
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -quiet -volname 'Classic Companion' -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 "$UPLOAD/$STEM.dmg"
    codesign --force --sign "$CC_SIGNING_IDENTITY" --timestamp "$UPLOAD/$STEM.dmg"
  fi
  verify_developer_signature "$UPLOAD/$STEM.dmg"
  # 已有非空提交记录但无法解析时也不重提；需人工核对提交历史。
  [[ ! -e "$LOCAL/dmg-notary-submit.plist" ]] || { echo 'DMG 提交记录异常，先核对历史，禁止重提。' >&2; exit 1; }
  xcrun notarytool submit "$UPLOAD/$STEM.dmg" --keychain-profile "$CC_NOTARY_PROFILE" --output-format plist > "$LOCAL/dmg-notary-submit.plist"
fi
wait_existing "$LOCAL/dmg-notary"
xcrun stapler staple "$UPLOAD/$STEM.dmg"
xcrun stapler validate "$UPLOAD/$STEM.dmg"
# 从最终 ZIP 提取随包说明，保持验证成品一致。
mkdir "$STAGE/final"
ditto -x -k "$UPLOAD/$STEM.zip" "$STAGE/final"
NOTES=(TrialNotes.zh-Hans.md TrialNotes.zh-Hant.md TrialNotes.en.md TrialNotes.ja.md)
for notes in $NOTES; do cp "$STAGE/final/Classic Companion.app/Contents/Resources/$notes" "$UPLOAD/$notes"; done
[[ -e "$LOCAL/source-$VERSION-$BUILD.tar.gz" ]] || scripts/snapshot-source.sh "$LOCAL/source-$VERSION-$BUILD.tar.gz"
if [[ -d "build/$BUILD/ClassicCompanion.dSYM" && ! -e "$LOCAL/ClassicCompanion-$VERSION-$BUILD.dSYM.zip" ]]; then
  ditto -c -k --keepParent "build/$BUILD/ClassicCompanion.dSYM" "$LOCAL/ClassicCompanion-$VERSION-$BUILD.dSYM.zip"
fi
(cd "$LOCAL" && shasum -a 256 "source-$VERSION-$BUILD.tar.gz" > SHA256SUMS)
(cd "$UPLOAD" && shasum -a 256 "$STEM.dmg" "$STEM.zip" $NOTES > SHA256SUMS)
scripts/verify-release.sh --notarized "$DEST" | tee "$LOCAL/notarized-verification.txt"
echo "恢复公证流程完成：$DEST；未上传 GitHub。"
