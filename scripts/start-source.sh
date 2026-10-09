#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"

for tool in git go node pnpm docker openssl; do
  command -v "$tool" >/dev/null 2>&1 || { printf '缺少命令：%s\n' "$tool" >&2; exit 1; }
done

ref=${ORP_SOURCE_REF:-main}
clone_component() {
  local name=$1 url=$2
  if [[ -e "$root/$name" ]]; then
    [[ -d "$root/$name/.git" ]] || { printf '%s 已存在且不是 Git 仓库，请先移走它。\n' "$name" >&2; exit 1; }
    return
  fi
  git clone --depth 1 --branch "$ref" "$url" "$root/$name"
}

clone_component orp-backend https://github.com/OpenrestyPlus/orp-backend.git
clone_component orp-frontend https://github.com/OpenrestyPlus/orp-frontend.git
clone_component orp-node-agent https://github.com/OpenrestyPlus/orp-node-agent.git
clone_component orp-nginx-importer https://github.com/OpenrestyPlus/orp-nginx-importer.git

if [[ ! -f "$root/.env" ]]; then
  cp "$root/.env.source.example" "$root/.env"
  chmod 600 "$root/.env"
  printf '已创建 .env。确认其中 MySQL 开发密码后，再次运行此脚本启动服务。\n'
  exit 0
fi

exec "$root/orp-backend/dev.sh" "$@"
