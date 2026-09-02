#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "YConnect 开发模式：Keychain、Application Support 与全部客户端配置均使用隔离空间。" >&2
exec swift run --package-path "$PROJECT_ROOT/darwin" YConnect --development "$@"
