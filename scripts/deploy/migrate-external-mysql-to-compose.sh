#!/usr/bin/env bash
set -euo pipefail

# Imports the external MySQL database into the local Compose MySQL instance.
# It only reads the source and refuses to overwrite a non-empty local schema.
project_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
workspace_dir="$(cd "$project_dir/.." && pwd)"
env_file="${project_dir}/.env"
compose_file="${project_dir}/docker-compose.source.yaml"
if [[ ! -f "$env_file" && -f "$workspace_dir/.env" ]]; then
  env_file="$workspace_dir/.env"
fi

if [[ ! -f "$env_file" ]]; then
  echo "Missing $env_file; copy .env.example and fill the external source database values." >&2
  exit 1
fi

dotenv_value() {
  local key="$1" value
  value=$(awk -v key="$key" 'index($0, key "=") == 1 { sub("^[^=]*=", ""); print; exit }' "$env_file")
  if [[ -n "$value" ]]; then printf '%s' "$value"; else printenv "$key" 2>/dev/null || true; fi
}

# Do not source .env: JDBC query strings contain '&', which is shell syntax.
source_url="${MIGRATION_SOURCE_DB_URL:-$(dotenv_value MIGRATION_SOURCE_DB_URL)}"
source_url="${source_url:-$(dotenv_value OPENRESTY_DB_URL)}"
source_user="${MIGRATION_SOURCE_DB_USERNAME:-$(dotenv_value MIGRATION_SOURCE_DB_USERNAME)}"
source_user="${source_user:-$(dotenv_value OPENRESTY_DB_USERNAME)}"
source_password="${MIGRATION_SOURCE_DB_PASSWORD:-$(dotenv_value MIGRATION_SOURCE_DB_PASSWORD)}"
source_password="${source_password:-$(dotenv_value OPENRESTY_DB_PASSWORD)}"
if [[ -z "$source_url" || -z "$source_user" ]]; then
  echo "Set MIGRATION_SOURCE_DB_URL and MIGRATION_SOURCE_DB_USERNAME (or existing OPENRESTY_DB_* values)." >&2
  exit 1
fi

source_url=${source_url#jdbc:}
source_url=${source_url%%\?*}
source_host_port=${source_url#mysql://}
source_host_port=${source_host_port%%/*}
source_database=${source_url##*/}
source_database=${source_database%%\?*}
source_host=${source_host_port%%:*}
source_port=${source_host_port##*:}
[[ "$source_host" == "$source_port" ]] && source_port=3306

local_database=${MYSQL_DATABASE:-$(dotenv_value MYSQL_DATABASE)}
local_database=${local_database:-openresty-plus}
local_port=${MYSQL_PORT:-$(dotenv_value MYSQL_PORT)}
local_port=${local_port:-3306}
local_user=${MYSQL_USER:-$(dotenv_value MYSQL_USER)}
local_user=${local_user:-openresty-plus}
local_password=${MYSQL_PASSWORD:-$(dotenv_value MYSQL_PASSWORD)}
local_password=${local_password:-openresty-plus-local}
local_root_password=${MYSQL_ROOT_PASSWORD:-$(dotenv_value MYSQL_ROOT_PASSWORD)}
local_root_password=${local_root_password:-openresty-plus-root}

if [[ "$source_database" == "$local_database" && "$source_port" == "$local_port" && \
  ( "$source_host" == "127.0.0.1" || "$source_host" == "localhost" || "$source_host" == "::1" ) ]]; then
  echo "Migration source and local target both point to $source_host:$source_port/$source_database. Set MIGRATION_SOURCE_DB_URL to the external source database." >&2
  exit 1
fi

dump_file=$(mktemp "${TMPDIR:-/tmp}/openresty-plus-mysql-XXXXXX.sql")
trap 'rm -f "$dump_file"' EXIT

cd "$project_dir"
docker compose --env-file "$env_file" -f "$compose_file" --project-directory "$project_dir" up -d mysql
compose=(docker compose --env-file "$env_file" -f "$compose_file" --project-directory "$project_dir")
until "${compose[@]}" exec -T mysql mysqladmin ping -h 127.0.0.1 -uroot -p"$local_root_password" --silent >/dev/null 2>&1; do sleep 2; done

existing_tables=$("${compose[@]}" exec -T mysql mysql -N -s -u"$local_user" -p"$local_password" "$local_database" -e 'SHOW TABLES' | wc -l | tr -d ' ')
if [[ "$existing_tables" != "0" ]]; then
  echo "Local schema $local_database already has $existing_tables table(s); refusing to overwrite it." >&2
  exit 1
fi

docker run --rm --network host -e MYSQL_PWD="$source_password" mysql:8.4 \
  mysqldump -h"$source_host" -P"$source_port" -u"$source_user" --single-transaction --routines --events --triggers --no-tablespaces --set-gtid-purged=OFF "$source_database" >"$dump_file"

source_tables=$(docker run --rm --network host -e MYSQL_PWD="$source_password" mysql:8.4 \
  mysql -N -s -h"$source_host" -P"$source_port" -u"$source_user" "$source_database" -e 'SHOW TABLES')
if [[ -z "$source_tables" ]]; then
  echo "Source schema $source_database contains no tables; refusing to report an empty migration as successful." >&2
  exit 1
fi

for table in $source_tables; do
  if ! rg -q "CREATE TABLE \`$table\`" "$dump_file"; then
    echo "Export is missing the CREATE TABLE statement for $table; refusing to import an incomplete dump." >&2
    exit 1
  fi
done

"${compose[@]}" exec -T mysql mysql -u"$local_user" -p"$local_password" "$local_database" <"$dump_file"

target_tables=$("${compose[@]}" exec -T mysql mysql -N -s -u"$local_user" -p"$local_password" "$local_database" -e 'SHOW TABLES')
for table in $source_tables; do
  if ! printf '%s\n' "$target_tables" | rg -qx "$table"; then
    echo "Migration verification failed: table $table was not created in local schema $local_database." >&2
    exit 1
  fi
done

source_table_count=$(printf '%s\n' "$source_tables" | wc -l | tr -d ' ')
target_table_count=$(printf '%s\n' "$target_tables" | wc -l | tr -d ' ')
if [[ "$source_table_count" != "$target_table_count" ]]; then
  echo "Migration verification failed: source=$source_table_count tables, local=$target_table_count tables." >&2
  exit 1
fi

while IFS= read -r table; do
  [[ -n "$table" ]] || continue
  source_rows=$(docker run --rm --network host -e MYSQL_PWD="$source_password" mysql:8.4 \
    mysql -N -s -h"$source_host" -P"$source_port" -u"$source_user" "$source_database" -e "SELECT COUNT(*) FROM \`$table\`")
  target_rows=$("${compose[@]}" exec -T mysql mysql -N -s -u"$local_user" -p"$local_password" "$local_database" -e "SELECT COUNT(*) FROM \`$table\`")
  if [[ "$source_rows" != "$target_rows" ]]; then
    echo "Migration verification failed for $table: source=$source_rows rows, local=$target_rows rows." >&2
    exit 1
  fi
done <<<"$source_tables"

echo "Migration completed and verified: $source_table_count tables imported into local MySQL database $local_database."
