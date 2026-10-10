#!/usr/bin/env bash

quickstart_load_env() {
  local env_file=$1 line key value
  [[ -f "$env_file" ]] || { printf '没有找到配置文件：%s\n' "$env_file" >&2; return 1; }

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
}

quickstart_fail() {
  printf '启动检查失败：%s\n' "$1" >&2
  exit 1
}

quickstart_parse_endpoint() {
  local endpoint=$1 default_port=$2 rest
  if [[ "$endpoint" == \[* ]]; then
    QUICKSTART_ENDPOINT_HOST=${endpoint#\[}
    QUICKSTART_ENDPOINT_HOST=${QUICKSTART_ENDPOINT_HOST%%\]*}
    rest=${endpoint#*\]}
    if [[ "$rest" == :* ]]; then QUICKSTART_ENDPOINT_PORT=${rest#:}; else QUICKSTART_ENDPOINT_PORT=$default_port; fi
  elif [[ "$endpoint" == *:* ]]; then
    QUICKSTART_ENDPOINT_HOST=${endpoint%:*}
    QUICKSTART_ENDPOINT_PORT=${endpoint##*:}
  else
    QUICKSTART_ENDPOINT_HOST=$endpoint
    QUICKSTART_ENDPOINT_PORT=$default_port
  fi

  [[ -n "$QUICKSTART_ENDPOINT_HOST" && "$QUICKSTART_ENDPOINT_PORT" =~ ^[0-9]{1,5}$ ]] || return 1
  (( 10#$QUICKSTART_ENDPOINT_PORT >= 1 && 10#$QUICKSTART_ENDPOINT_PORT <= 65535 )) || return 1
}

quickstart_check_endpoint() {
  local label=$1 address=$2 default_port=$3
  quickstart_parse_endpoint "$address" "$default_port" || quickstart_fail "$label 地址格式无效：$address"
  nc -z -w 3 "$QUICKSTART_ENDPOINT_HOST" "$QUICKSTART_ENDPOINT_PORT" >/dev/null 2>&1 \
    || quickstart_fail "$label 无法连接：$QUICKSTART_ENDPOINT_HOST:$QUICKSTART_ENDPOINT_PORT。请确认服务已启动且 .env 地址正确。"
  printf '%s 已连接：%s:%s\n' "$label" "$QUICKSTART_ENDPOINT_HOST" "$QUICKSTART_ENDPOINT_PORT"
}

quickstart_check_dependencies() {
  [[ -n "${OPENRESTY_DB_URL:-}" ]] || quickstart_fail '.env 未配置 OPENRESTY_DB_URL。'
  [[ "$OPENRESTY_DB_URL" == jdbc:mysql://*/* ]] || quickstart_fail 'OPENRESTY_DB_URL 必须是 jdbc:mysql://host:port/database 格式。'
  [[ -n "${OPENRESTY_DB_USERNAME:-}" ]] || quickstart_fail '.env 未配置 OPENRESTY_DB_USERNAME。'
  [[ -n "${OPENRESTY_DB_PASSWORD:-}" ]] || quickstart_fail '.env 未配置 OPENRESTY_DB_PASSWORD。'
  [[ -n "${OPENRESTY_KAFKA_BOOTSTRAP_SERVERS:-}" ]] || quickstart_fail '.env 未配置 OPENRESTY_KAFKA_BOOTSTRAP_SERVERS。'
  [[ -n "${OPENRESTY_KAFKA_TOPIC:-}" ]] || quickstart_fail '.env 未配置 OPENRESTY_KAFKA_TOPIC。'
  [[ -n "${OPENRESTY_REDIS_ADDR:-}" ]] || quickstart_fail '.env 未配置 OPENRESTY_REDIS_ADDR。'
  command -v nc >/dev/null 2>&1 || quickstart_fail '缺少 nc 命令，无法检查 MySQL、Kafka 和 Redis 连接。'

  local db_authority broker
  db_authority=${OPENRESTY_DB_URL#jdbc:mysql://}
  db_authority=${db_authority%%/*}
  quickstart_check_endpoint 'MySQL' "$db_authority" 3306
  quickstart_check_endpoint 'Redis' "$OPENRESTY_REDIS_ADDR" 6379

  local -a brokers
  local broker_count=0
  IFS=',' read -r -a brokers <<< "$OPENRESTY_KAFKA_BOOTSTRAP_SERVERS"
  for broker in "${brokers[@]}"; do
    broker=${broker//[[:space:]]/}
    [[ -n "$broker" ]] || continue
    quickstart_check_endpoint 'Kafka' "$broker" 9092
    ((broker_count += 1))
  done
  (( broker_count > 0 )) || quickstart_fail 'OPENRESTY_KAFKA_BOOTSTRAP_SERVERS 未包含有效 broker 地址。'
}

quickstart_configure_filebeat_brokers() {
  if [[ -n "${FILEBEAT_KAFKA_HOSTS:-}" && "$FILEBEAT_KAFKA_HOSTS" != '["127.0.0.1:9092"]' ]]; then return; fi

  local broker first=true hosts='['
  local -a brokers
  IFS=',' read -r -a brokers <<< "${OPENRESTY_KAFKA_BOOTSTRAP_SERVERS:-}"
  for broker in "${brokers[@]}"; do
    broker=${broker//[[:space:]]/}
    [[ -n "$broker" ]] || continue
    [[ "$broker" != *'"'* && "$broker" != *'\'* ]] || quickstart_fail 'Kafka broker 地址不能包含引号或反斜杠。'
    if [[ "$first" == true ]]; then first=false; else hosts+=','; fi
    hosts+="\"$broker\""
  done
  hosts+=']'
  export FILEBEAT_KAFKA_HOSTS="$hosts"
}
