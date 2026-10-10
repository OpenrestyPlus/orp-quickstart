#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source_dir="$root/openresty-plus"
compose=(docker compose --env-file "$root/.env" -f "$root/docker-compose.source.yaml" --project-directory "$root")
source "$root/scripts/lib/dependencies.sh"
quickstart_load_env "$root/.env"

with_demos=${QUICKSTART_START_DEMOS:-false}
while (($#)); do
  case "$1" in
    --with-demos) with_demos=true ;;
    --without-demos) with_demos=false ;;
    *) quickstart_fail "不支持的参数：$1（可用 --with-demos、--without-demos）" ;;
  esac
  shift
done

if [[ ! -d "$source_dir/.git" ]]; then
  printf '源码仓库不存在，请先运行 ./scripts/start-source.sh。\n' >&2
  exit 1
fi

[[ -n "${OPENRESTY_ADMIN_USERNAME:-}" ]] || quickstart_fail '.env 未配置 OPENRESTY_ADMIN_USERNAME。'
[[ -n "${OPENRESTY_ADMIN_PASSWORD:-}" ]] || quickstart_fail '.env 未配置 OPENRESTY_ADMIN_PASSWORD。'
[[ "${OPENRESTY_DATA_KEY:-}" =~ ^[[:xdigit:]]{64}$ ]] || quickstart_fail 'OPENRESTY_DATA_KEY 必须是 64 位十六进制字符串。'
quickstart_check_dependencies
quickstart_configure_filebeat_brokers

for tool in git go node pnpm docker; do
  command -v "$tool" >/dev/null 2>&1 || { printf '缺少命令：%s\n' "$tool" >&2; exit 1; }
done

printf '编译前后端单体程序……\n'
(cd "$source_dir" && ./build.sh)

if [[ "$with_demos" == true ]]; then
  printf '启动三个 OpenResty 演示节点和 Filebeat……\n'
  "${compose[@]}" --profile demos up -d --build
else
  printf '演示节点和 Filebeat 已关闭。需要时使用 --with-demos 启动。\n'
fi

printf '管理界面和 API：http://127.0.0.1:8081\n'
printf '默认管理员：%s；密码见 .env 中的 OPENRESTY_ADMIN_PASSWORD。\n' "${OPENRESTY_ADMIN_USERNAME:-admin}"
printf '按 Ctrl+C 停止应用；需要时可用 docker compose --env-file .env -f docker-compose.source.yaml --profile demos down 停止演示服务。\n'
cd "$root"
exec "$source_dir/dist/openresty-plus" run
