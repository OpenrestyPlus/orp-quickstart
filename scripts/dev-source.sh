#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source_dir="$root/openresty-plus"
compose=(docker compose --env-file "$root/.env" -f "$root/docker-compose.source.yaml" --project-directory "$root")

if [[ ! -d "$source_dir/.git" ]]; then
  printf '源码仓库不存在，请先运行 ./scripts/start-source.sh。\n' >&2
  exit 1
fi

mysql_root_password=$(awk -F= '$1 == "MYSQL_ROOT_PASSWORD" {sub(/^[^=]*=/, ""); print; exit}' "$root/.env")
if [[ -z "$mysql_root_password" ]]; then
  printf '.env 中未配置 MYSQL_ROOT_PASSWORD。\n' >&2
  exit 1
fi

printf '编译前后端单体程序……\n'
(cd "$source_dir" && ./build.sh)

printf '启动 MySQL、Redis、Kafka、OpenResty 示例节点和 Filebeat……\n'
"${compose[@]}" up -d --build mysql redis kafka openresty-east-1 openresty-east-2 openresty-east-3 filebeat-east-1 filebeat-east-2 filebeat-east-3

printf '等待 MySQL 就绪……\n'
mysql_ready=false
for _ in {1..60}; do
  if "${compose[@]}" exec -T mysql mysqladmin ping -h 127.0.0.1 \
    -uroot -p"$mysql_root_password" --silent >/dev/null 2>&1; then
    mysql_ready=true
    break
  fi
  sleep 2
done
if [[ "$mysql_ready" != true ]]; then
  printf 'MySQL 未能在 120 秒内就绪，请查看：docker compose -f docker-compose.source.yaml logs mysql\n' >&2
  exit 1
fi

printf '管理界面和 API：http://127.0.0.1:8081\n'
admin_username=$(awk -F= '$1 == "OPENRESTY_ADMIN_USERNAME" {sub(/^[^=]*=/, ""); print; exit}' "$root/.env")
printf '默认管理员：%s；密码见 .env 中的 OPENRESTY_ADMIN_PASSWORD。\n' "${admin_username:-vben}"
printf '按 Ctrl+C 停止应用；保留的示例服务可用 docker compose -f docker-compose.source.yaml down 停止。\n'
cd "$root"
exec "$source_dir/dist/openresty-plus" run
