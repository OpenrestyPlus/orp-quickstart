#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
env_file="$root/.env"
source "$root/scripts/lib/dependencies.sh"

fail() {
  printf '启动检查失败：%s\n' "$1" >&2
  exit 1
}

if [[ ! -f "$env_file" ]]; then
  fail '没有找到 .env。请先运行 cp .env.binary.example .env 并填写配置。'
fi

quickstart_load_env "$env_file"

binary_path="${OPENRESTY_PLUS_BINARY_PATH:-bin/openresty-plus}"
[[ "$binary_path" = /* ]] || binary_path="$root/$binary_path"

action=${1:-start}
if [[ $# -gt 0 ]]; then shift; fi

check_start_config() {
  [[ -n "${OPENRESTY_ADMIN_USERNAME:-}" ]] || fail '.env 未配置 OPENRESTY_ADMIN_USERNAME。'
  [[ -n "${OPENRESTY_ADMIN_PASSWORD:-}" ]] || fail '.env 未配置 OPENRESTY_ADMIN_PASSWORD。'
  [[ "${OPENRESTY_DATA_KEY:-}" =~ ^[[:xdigit:]]{64}$ ]] || fail 'OPENRESTY_DATA_KEY 必须是 64 位十六进制字符串。'
  quickstart_check_dependencies
}

case "$action" in
  start|restart|run) check_start_config ;;
  status|stop|logs|version|help|--help|-h) ;;
  *) fail "不支持的命令：$action（可用 start、status、logs、restart、stop、version、help）" ;;
esac

if [[ ! -x "$binary_path" ]]; then
  binary_url=${OPENRESTY_PLUS_BINARY_URL:-}
  [[ -n "$binary_url" ]] || fail "找不到可执行文件 $binary_path。请将 Linux 二进制放到 bin/openresty-plus，或在 .env 中设置 OPENRESTY_PLUS_BINARY_URL。"
  command -v curl >/dev/null 2>&1 || fail '下载二进制需要 curl。'
  mkdir -p "$(dirname "$binary_path")"
  temporary_file="$binary_path.download.$$"
  trap 'rm -f "$temporary_file"' EXIT
  printf '正在下载 OpenResty Plus 二进制……\n'
  curl --fail --location --silent --show-error --retry 3 "$binary_url" -o "$temporary_file" \
    || fail '二进制下载失败，请检查 OPENRESTY_PLUS_BINARY_URL 和访问权限。'
  chmod 0755 "$temporary_file"
  mv "$temporary_file" "$binary_path"
  trap - EXIT
fi

cd "$root"
exec "$binary_path" "$action" "$@"
