#!/bin/zsh
# Sparkle 更新签名用的 EdDSA（Ed25519）密钥。说明见 docs/updates.md "Key custody"。
#
# 私钥是 32 字节 Ed25519 种子的 base64，也就是 Sparkle generate_keys -x 导出的格式，
# 只存在登录钥匙串的通用密码项里：服务名 $CC_UPDATE_KEY_SERVICE，账户 production（正式）或 update-test（隔离测试）。
# 项目的访问控制只信任 /usr/bin/security，读取时不弹钥匙串授权窗口；签名时用
#   security find-generic-password -s 服务名 -a 账户 -w | sign_update --ed-key-file - …
# 私钥不写进文件、命令行参数或环境变量，也不输出。本脚本不开 xtrace。
#
# 用法：
#   scripts/sparkle-key.sh generate <账户>   生成新密钥存进钥匙串（已有同名项时拒绝，不覆盖），输出公钥
#   scripts/sparkle-key.sh public <账户>     从钥匙串里的私钥算出公钥（Info.plist 的 SUPublicEDKey）
#   scripts/sparkle-key.sh exists <账户>     有这个密钥项时返回 0
#   scripts/sparkle-key.sh selftest <账户>   用 Sparkle 的 sign_update 签一个临时文件，再用 openssl 和公钥独立验证
#   scripts/sparkle-key.sh verify-backup <账户>  在隐藏输入里粘贴备份的私钥，只报告它和钥匙串里的是否同一把，不显示私钥
#   scripts/sparkle-key.sh import <账户>     换电脑时从备份恢复：隐藏输入私钥，核对公钥后存进钥匙串（已有同名项时拒绝）
set -euo pipefail
unsetopt xtrace 2>/dev/null || true
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/update-config.sh"

# Ed25519 私钥 PKCS#8 DER 的固定前缀，后面接 32 字节种子；公钥 SPKI DER 的前缀，后面接 32 字节公钥。
PKCS8_PREFIX=302e020100300506032b657004220420
SPKI_PREFIX=302a300506032b6570032100

usage() { sed -n '2,19p' "$0" >&2; exit 2; }
[[ $# == 2 ]] || usage
COMMAND="$1"
ACCOUNT="$2"
[[ "$ACCOUNT" == "$CC_UPDATE_KEY_ACCOUNT" || "$ACCOUNT" == "$CC_UPDATE_TEST_KEY_ACCOUNT" ]] || {
  echo "账户只能是 $CC_UPDATE_KEY_ACCOUNT 或 $CC_UPDATE_TEST_KEY_ACCOUNT" >&2; exit 2
}

exists() { security find-generic-password -s "$CC_UPDATE_KEY_SERVICE" -a "$ACCOUNT" >/dev/null 2>&1; }

# 私钥只在管道里流动。
read_seed() { security find-generic-password -s "$CC_UPDATE_KEY_SERVICE" -a "$ACCOUNT" -w; }

# 标准输入的私钥（base64 种子）→ 公钥 base64。
seed_to_public() {
  { echo "$PKCS8_PREFIX" | xxd -r -p; base64 -d; } |
    openssl pkey -inform DER -pubout -outform DER | tail -c 32 | base64
}

public_key() { read_seed | seed_to_public; }

# 这个账户应有的公钥：正式密钥以 update-config.sh 里写进应用的为准，测试密钥没有固定值。
expected_public() {
  [[ "$ACCOUNT" == "$CC_UPDATE_KEY_ACCOUNT" ]] && echo "$CC_UPDATE_PUBLIC_ED_KEY" || true
}

# 隐藏输入读一把备份的私钥到全局变量 seed，检查格式。不回显，不写文件。
read_backup_seed() {
  [[ -t 0 ]] || { echo "请在终端里直接运行，私钥从隐藏输入读取" >&2; exit 2; }
  seed=""
  read -rs "seed?粘贴备份的私钥（44 个字符，输入不显示），回车结束："
  echo >&2
  seed="${seed//[[:space:]]/}"
  local bytes
  bytes="$(printf '%s' "$seed" | base64 -d 2>/dev/null | wc -c | tr -d ' ')" || bytes=0
  if [[ ${#seed} != 44 || "$bytes" != 32 ]]; then
    unset seed
    echo "格式不对：应是 44 个字符的 base64（32 字节 Ed25519 种子），即钥匙串项里显示的密码。" >&2
    exit 1
  fi
}

case "$COMMAND" in
  exists) exists ;;
  public)
    exists || { echo "钥匙串里没有 $CC_UPDATE_KEY_SERVICE / $ACCOUNT" >&2; exit 1; }
    public_key ;;
  generate)
    if exists; then
      echo "钥匙串里已有 $CC_UPDATE_KEY_SERVICE / $ACCOUNT，不覆盖。换密钥会让已安装的版本收不到更新，见 docs/updates.md。" >&2
      exit 1
    fi
    # seed 只在这个 shell 的变量里；printf 是 zsh 内建命令，不会出现在进程参数里。
    # security -i 从标准输入读命令，私钥同样不进进程参数。
    seed="$(openssl genpkey -algorithm ed25519 -outform DER | tail -c 32 | base64)"
    [[ ${#seed} == 44 ]] || { echo "生成密钥失败" >&2; exit 1; }
    printf 'add-generic-password -s "%s" -a "%s" -l "%s" -j "%s" -w "%s" -T /usr/bin/security\n' \
      "$CC_UPDATE_KEY_SERVICE" "$ACCOUNT" "$CC_UPDATE_KEY_SERVICE ($ACCOUNT)" \
      "Classic Companion Sparkle EdDSA private key (base64 Ed25519 seed). Do not export to Git or logs. See docs/updates.md." \
      "$seed" | security -i >/dev/null 2>&1   # 出错时 security 可能回显整条命令（含私钥），所以连错误输出一起丢掉，结果靠下面的 exists 判断
    unset seed
    exists || { echo "存进钥匙串失败" >&2; exit 1; }
    public_key ;;
  selftest)
    exists || { echo "钥匙串里没有 $CC_UPDATE_KEY_SERVICE / $ACCOUNT" >&2; exit 1; }
    work="$(mktemp -d)"
    trap 'rm -rf "$work"' EXIT
    head -c 4096 /dev/urandom > "$work/sample"
    signature="$(read_seed | "$CC_SPARKLE_BIN/sign_update" --ed-key-file - -p "$work/sample")"
    echo "$signature" | base64 -d > "$work/sample.sig"
    { echo "$SPKI_PREFIX" | xxd -r -p; public_key | base64 -d; } > "$work/public.der"
    openssl pkeyutl -verify -pubin -inkey "$work/public.der" -keyform DER -rawin -in "$work/sample" -sigfile "$work/sample.sig" >/dev/null
    # 改一个字节必须验不过。
    printf 'x' | dd of="$work/sample" bs=1 seek=0 conv=notrunc 2>/dev/null
    if openssl pkeyutl -verify -pubin -inkey "$work/public.der" -keyform DER -rawin -in "$work/sample" -sigfile "$work/sample.sig" >/dev/null 2>&1; then
      echo "失败：改过的文件也验证通过" >&2; exit 1
    fi
    echo "通过  $ACCOUNT：sign_update 的签名能用公钥 $(public_key) 验证，改动后的文件验证失败" ;;
  verify-backup)
    exists || { echo "钥匙串里没有 $CC_UPDATE_KEY_SERVICE / $ACCOUNT" >&2; exit 1; }
    read_backup_seed
    backup_public="$(printf '%s' "$seed" | seed_to_public)"
    unset seed
    if [[ "$backup_public" == "$(public_key)" ]]; then
      echo "一致  $ACCOUNT：备份的私钥和钥匙串里的是同一把（公钥 $backup_public）"
    else
      echo "不一致  $ACCOUNT：备份的私钥不是钥匙串里这一把，请重新备份" >&2; exit 1
    fi ;;
  import)
    if exists; then
      echo "钥匙串里已有 $CC_UPDATE_KEY_SERVICE / $ACCOUNT，不覆盖。要核对备份请用 verify-backup。" >&2; exit 1
    fi
    read_backup_seed
    backup_public="$(printf '%s' "$seed" | seed_to_public)"
    expected="$(expected_public)"
    if [[ -n "$expected" && "$backup_public" != "$expected" ]]; then
      unset seed
      echo "这把私钥对应的公钥不是应用里的 SUPublicEDKey（$expected），没有导入。" >&2; exit 1
    fi
    printf 'add-generic-password -s "%s" -a "%s" -l "%s" -j "%s" -w "%s" -T /usr/bin/security\n' \
      "$CC_UPDATE_KEY_SERVICE" "$ACCOUNT" "$CC_UPDATE_KEY_SERVICE ($ACCOUNT)" \
      "Classic Companion Sparkle EdDSA private key (base64 Ed25519 seed). Do not export to Git or logs. See docs/updates.md." \
      "$seed" | security -i >/dev/null 2>&1   # 同 generate：错误输出可能含私钥，丢掉，结果靠 exists 判断
    unset seed
    exists || { echo "存进钥匙串失败" >&2; exit 1; }
    [[ "$(public_key)" == "$backup_public" ]] || { echo "导入后读出的公钥不一致" >&2; exit 1; }
    echo "已导入  $ACCOUNT：公钥 $backup_public" ;;
  *) usage ;;
esac
