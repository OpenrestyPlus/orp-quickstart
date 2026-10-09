#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
env_file="$root/.env"

fail() {
  printf '启动检查失败：%s\n' "$1" >&2
  exit 1
}

if [[ ! -f "$env_file" ]]; then
  fail '没有找到 .env。请先运行 cp .env.binary.example .env 并填写配置。'
fi

# Parse KEY=VALUE without sourcing JDBC URLs containing shell metacharacters.
while IFS= read -r line || [[ -n "$line" ]]; do
  line=${line%$'\r'}
  line=${line#"${line%%[![:space:]]*}"}
  [[ -z "$line" || "$line" == \#* ]] && continue
  line=${line#export }
  [[ "$line" == *=* ]] || continue

  key=${line%%=*}
  value=${line#*=}
  key=${key%"${key##*[![:space:]]}"}
  value=${value#"${value%%[![:space:]]*}"}
  value=${value%"${value##*[![:space:]]}"}
  [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue

  if [[ ${#value} -ge 2 && ( "${value:0:1}" == '"' || "${value:0:1}" == "'" ) && "${value: -1}" == "${value:0:1}" ]]; then
    value=${value:1:${#value}-2}
  fi
  if ! printenv "$key" >/dev/null 2>&1; then
    export "$key=$value"
  fi
done < "$env_file"

binary_path="${OPENRESTY_PLUS_BINARY_PATH:-bin/openresty-plus}"
[[ "$binary_path" = /* ]] || binary_path="$root/$binary_path"

action=${1:-start}
if [[ $# -gt 0 ]]; then shift; fi

parse_endpoint() {
  local endpoint=$1 default_port=$2 rest
  if [[ "$endpoint" == \[* ]]; then
    ENDPOINT_HOST=${endpoint#\[}
    ENDPOINT_HOST=${ENDPOINT_HOST%%\]*}
    rest=${endpoint#*\]}
    if [[ "$rest" == :* ]]; then ENDPOINT_PORT=${rest#:}; else ENDPOINT_PORT=$default_port; fi
  elif [[ "$endpoint" == *:* ]]; then
    ENDPOINT_HOST=${endpoint%:*}
    ENDPOINT_PORT=${endpoint##*:}
  else
    ENDPOINT_HOST=$endpoint
    ENDPOINT_PORT=$default_port
  fi

  [[ -n "$ENDPOINT_HOST" && "$ENDPOINT_PORT" =~ ^[0-9]{1,5}$ ]] || return 1
  (( 10#$ENDPOINT_PORT >= 1 && 10#$ENDPOINT_PORT <= 65535 )) || return 1
}

check_endpoint() {
  local label=$1 address=$2 default_port=$3
  parse_endpoint "$address" "$default_port" || fail "$label 地址格式无效：$address"
  nc -z -w 3 "$ENDPOINT_HOST" "$ENDPOINT_PORT" >/dev/null 2>&1 \
    || fail "$label 无法连接：$ENDPOINT_HOST:$ENDPOINT_PORT。请确认服务已启动且 .env 地址正确。"
  printf '%s 已连接：%s:%s\n' "$label" "$ENDPOINT_HOST" "$ENDPOINT_PORT"
}

check_start_config() {
  [[ -n "${OPENRESTY_DB_URL:-}" ]] || fail '.env 未配置 OPENRESTY_DB_URL。'
  [[ "$OPENRESTY_DB_URL" == jdbc:mysql://*/* ]] || fail 'OPENRESTY_DB_URL 必须是 jdbc:mysql://host:port/database 格式。'
  [[ -n "${OPENRESTY_DB_USERNAME:-}" ]] || fail '.env 未配置 OPENRESTY_DB_USERNAME。'
  [[ -n "${OPENRESTY_DB_PASSWORD:-}" ]] || fail '.env 未配置 OPENRESTY_DB_PASSWORD。'
  [[ -n "${OPENRESTY_KAFKA_BOOTSTRAP_SERVERS:-}" ]] || fail '.env 未配置 OPENRESTY_KAFKA_BOOTSTRAP_SERVERS。'
  [[ -n "${OPENRESTY_KAFKA_TOPIC:-}" ]] || fail '.env 未配置 OPENRESTY_KAFKA_TOPIC。'
  [[ -n "${OPENRESTY_REDIS_ADDR:-}" ]] || fail '.env 未配置 OPENRESTY_REDIS_ADDR。'
  [[ -n "${OPENRESTY_ADMIN_USERNAME:-}" ]] || fail '.env 未配置 OPENRESTY_ADMIN_USERNAME。'
  [[ -n "${OPENRESTY_ADMIN_PASSWORD:-}" ]] || fail '.env 未配置 OPENRESTY_ADMIN_PASSWORD。'
  [[ "${OPENRESTY_DATA_KEY:-}" =~ ^[[:xdigit:]]{64}$ ]] || fail 'OPENRESTY_DATA_KEY 必须是 64 位十六进制字符串。'
  command -v nc >/dev/null 2>&1 || fail '缺少 nc 命令，无法检查 MySQL、Kafka 和 Redis 连接。'

  local db_authority broker
  db_authority=${OPENRESTY_DB_URL#jdbc:mysql://}
  db_authority=${db_authority%%/*}
  check_endpoint 'MySQL' "$db_authority" 3306
  check_endpoint 'Redis' "$OPENRESTY_REDIS_ADDR" 6379

  local -a brokers
  IFS=',' read -r -a brokers <<< "$OPENRESTY_KAFKA_BOOTSTRAP_SERVERS"
  for broker in "${brokers[@]}"; do
    broker=${broker//[[:space:]]/}
    [[ -n "$broker" ]] || continue
    check_endpoint 'Kafka' "$broker" 9092
  done
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
