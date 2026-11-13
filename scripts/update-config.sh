#!/bin/zsh
# 应用内更新（Sparkle 2）的发行配置。build-app.sh、verify-release.sh、prepare-appcast.sh、sparkle-key.sh 共用。
# 这里只有可以公开的值：feed 地址、下载地址、公钥、私钥在钥匙串里的位置。私钥本身不在任何文件里（docs/updates.md）。
# 测试用的 feed 地址、测试密钥和 ATS 例外不在这里，也不进正式构建；只写进隔离测试副本的 Info.plist（隔离测试工具不在本仓库）。

# Sparkle 版本，和 Package.swift 的 exact 版本一致（build-app.sh 核对）。
CC_SPARKLE_VERSION="2.10.1"
CC_SPARKLE_BIN="${CC_SPARKLE_BIN:-$(cd "$(dirname "${(%):-%x}")/.." && pwd)/.build/artifacts/sparkle/Sparkle/bin}"

# 正式 appcast 地址（必须 HTTPS）。所有渠道共用一个 appcast，beta 条目带 <sparkle:channel>beta</sparkle:channel>。
# 2026-11-13 起源码、下载、反馈和 appcast 统一在 xtymac/ClassicCompanion。注意 raw.githubusercontent.com 在部分地区不可达、GitHub 有几分钟缓存。
# 已发布版本里的地址以后很难改：要换地址，先发一个写着新地址的版本，旧地址保留到大家都升级。
# CONFIRMED=0 时 verify-release.sh --final 拒绝正式发布。
CC_UPDATE_FEED_URL="https://raw.githubusercontent.com/xtymac/ClassicCompanion/main/appcast.xml"
CC_UPDATE_FEED_CONFIRMED=1

# 更新包下载地址：公开下载仓库的 Release 附件，<前缀>/<标签>/<ZIP 文件名>。
CC_UPDATE_DOWNLOAD_BASE="https://github.com/xtymac/ClassicCompanion/releases/download"

# 正式 EdDSA 公钥（Info.plist 的 SUPublicEDKey）。对应的私钥在钥匙串：服务名 + 账户 production。
CC_UPDATE_PUBLIC_ED_KEY="tyx3/N3E3Ziih0psrKFGJDcEKFS0v1dlwF2RiyWPjCM="
CC_UPDATE_KEY_SERVICE="ClassicCompanion Sparkle EdDSA"
CC_UPDATE_KEY_ACCOUNT="production"
# 隔离测试（A → B）用的另一把密钥。它的公钥只写进测试副本；正式 appcast 不能用它签。
CC_UPDATE_TEST_KEY_ACCOUNT="update-test"

# 自动检查的间隔（秒）。设置页写的“每天检查一次”就是这个值。
CC_UPDATE_CHECK_INTERVAL=86400

# 渠道：版本号带预发布后缀（0.1.0-beta.2）是 beta，否则 stable。和 UpdateConfiguration.Channel.forVersion 一致（UpdateTests 核对）。
cc_update_channel() { [[ "$1" == *-* ]] && echo beta || echo stable; }
