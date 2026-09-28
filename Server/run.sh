#!/usr/bin/env bash
# QQ排程助手 · 服务端启动脚本
# 用法:  bash run.sh                 # 使用 Server/server.json 中的 host/port（首次运行自动生成配置）
#        bash run.sh --port 9000     # 临时改端口（更多参数: python3 server.py --help）
set -euo pipefail
cd "$(dirname "$0")"
exec python3 server.py "$@"
