#!/bin/zsh
# 由发布脚本 source；不读取、输出或保存密码。
CC_TEAM_ID="${CC_TEAM_ID:-}"
CC_SIGNING_IDENTITY="${CC_SIGNING_IDENTITY:-}"
CC_NOTARY_PROFILE="${CC_NOTARY_PROFILE:-}"

signing_preflight() {
  [[ -n "$CC_TEAM_ID" && -n "$CC_SIGNING_IDENTITY" ]] || { echo "Set CC_TEAM_ID and CC_SIGNING_IDENTITY for Developer ID builds." >&2; return 1; }
  local identities
  identities="$(security find-identity -v -p codesigning)" || return 1
  [[ "$identities" == *"\"$CC_SIGNING_IDENTITY\""* ]] || {
    echo "缺少有效签名身份：$CC_SIGNING_IDENTITY" >&2; return 1
  }
}

verify_developer_signature() {
  local signature
  codesign --verify --strict "$1" || return 1
  signature="$(codesign -dvv "$1" 2>&1)" || return 1
  grep -q '^Authority=Developer ID Application: ' <<<"$signature" &&
    grep -qx "TeamIdentifier=$CC_TEAM_ID" <<<"$signature" &&
    grep -q '^Timestamp=' <<<"$signature" || return 1
  if [[ "${2:-}" == runtime ]]; then
    grep -qE 'flags=0x[0-9a-f]+\([^)]*runtime' <<<"$signature" || return 1
  fi
}

notarize_file() {
  [[ -n "$CC_NOTARY_PROFILE" ]] || { echo "Set CC_NOTARY_PROFILE to your Keychain profile." >&2; return 1; }
  local artifact="$1" record="$2" submission_id result
  # ID 先落盘；断网/超时后可用 info/wait 查询，避免丢失已提交任务。
  xcrun notarytool submit "$artifact" --keychain-profile "$CC_NOTARY_PROFILE" \
    --output-format plist > "$record-submit.plist" || return 1
  submission_id=$(/usr/libexec/PlistBuddy -c 'Print :id' "$record-submit.plist") || return 1
  echo "公证提交：$submission_id；记录：$record-submit.plist"
  xcrun notarytool wait "$submission_id" --keychain-profile "$CC_NOTARY_PROFILE" \
    --timeout 30m --output-format plist > "$record-result.plist" || {
    echo "公证尚未成功完成。用 notarytool info/wait 查询 $submission_id，不要直接重新提交。" >&2
    return 1
  }
  result=$(/usr/libexec/PlistBuddy -c 'Print :status' "$record-result.plist") || return 1
  xcrun notarytool log "$submission_id" --keychain-profile "$CC_NOTARY_PROFILE" \
    "$record-log.json" || return 1
  [[ "$result" == Accepted ]] || { echo "公证失败：$result（查看 $record-log.json）" >&2; return 1; }
}
