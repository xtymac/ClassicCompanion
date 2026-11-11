#!/bin/zsh
# 保存当前源码、测试、脚本和文档，作为 Git 版本记录之外的发布快照。
# 用法：scripts/snapshot-source.sh 输出路径.tar.gz
set -euo pipefail
cd "$(dirname "$0")/.."
tar -czf "$1" --exclude ./.git --exclude ./.build --exclude ./build --exclude ./.playwright-mcp --exclude .DS_Store .
