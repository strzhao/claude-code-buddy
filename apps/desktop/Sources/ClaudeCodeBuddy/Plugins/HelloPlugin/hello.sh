#!/bin/bash
# Buddy Launcher 内置 hello plugin。
# 从 stdin 读 JSON 输入，输出 markdown 到 stdout。
# 协议：input = {"query":..., "sessionId":..., "cwd":...}
set -euo pipefail
INPUT=$(cat)
QUERY=$(echo "$INPUT" | /usr/bin/python3 -c "import sys, json; print(json.load(sys.stdin).get('query',''))")
echo "## Hello, ${QUERY}!"
echo ""
echo "这是 buddy launcher 内置的示例插件，证明插件协议工作正常。"
