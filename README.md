# OpenResty Plus 快速启动

本仓库统一管理本地演示环境，提供源码启动和预编译镜像启动。OpenResty Plus 主程序已经将 Vue 管理界面嵌入 Go 可执行文件，启动后通过同一个地址提供页面和 API。

| 方式 | 用途 | 命令 |
| --- | --- | --- |
| Release 二进制启动 | 使用预编译的 Go 程序连接已配置的外部中间件 | `./quickstart.sh` |
| 源码启动 | 从 `openresty-plus` 拉取源码，在本机编译单体程序 | `./scripts/start-source.sh` |
| Compose 镜像启动 | 使用 Release/Beta 镜像启动管理平台及演示节点 | `docker compose up -d` |

镜像模式和源码模式都会在 Linux Docker Engine 上启动 MySQL、Redis、Kafka、三个 OpenResty 演示节点及 Filebeat。各服务使用 host network，主机需预留 3306、6379、8081、9092、18080–18082、18180–18182、18280–18282 端口。Docker Desktop 需要启用 Host Networking。源码模式额外需要 Go 1.26.1、Node.js 22.18+ 或 24.12+、pnpm 11.16.0。

## Release 二进制启动

准备运行环境配置：

```sh
cp .env.binary.example .env
```

编辑 `.env`，填写外部 MySQL 的 JDBC 地址、用户名和密码，Kafka broker 地址与 topic，Redis 地址，以及管理员密码和 64 位数据密钥。MySQL、Kafka 和 Redis 必须已启动，脚本会在启动前检查配置并检查对应 TCP 端口是否可达。

将 Release 中的 Linux 可执行文件放入 `bin/openresty-plus`；也可以在 `.env` 中设置 `OPENRESTY_PLUS_BINARY_URL`，让脚本下载二进制。`OPENRESTY_PLUS_BINARY_PATH` 可改为其他本地文件路径。

```sh
./quickstart.sh
./quickstart.sh status
./quickstart.sh logs -f
./quickstart.sh restart
./quickstart.sh stop
```

默认命令为后台启动，管理界面和 API 地址由 `OPENRESTY_HTTP_ADDR` 决定，默认是 http://127.0.0.1:8081。该模式只启动 OpenResty Plus 应用进程，不会启动或管理中间件容器。

## 源码启动

```sh
./scripts/start-source.sh
```

首次运行会克隆 [openresty-plus](https://github.com/OpenrestyPlus/openresty-plus) monorepo，生成本地 `.env` 中的管理员、数据库和数据加密密钥，并提示检查配置。再次运行会编译前后端单体可执行文件，构建并启动示例 OpenResty 与 Filebeat 镜像，再以前台模式运行程序。

- 管理界面和 API：http://127.0.0.1:8081
- 默认账号：`vben`；随机密码保存在 `.env` 的 `OPENRESTY_ADMIN_PASSWORD`
- OpenResty 节点：http://127.0.0.1:18080、http://127.0.0.1:18180、http://127.0.0.1:18280
- 导入器：可在镜像模式中按需启用，访问 http://127.0.0.1:8090

按 Ctrl+C 停止前台程序。源码模式的 MySQL、Redis、Kafka、OpenResty 和 Filebeat 容器会保留；运行 `docker compose --env-file .env -f docker-compose.source.yaml down` 停止容器。不要添加 `-v`，否则会删除数据库和中间件数据卷。

## Compose 镜像启动

### 1. 生成本地配置

```sh
./scripts/init-compose-env.sh
```

编辑 `.env`，确认 `OPENRESTY_PLUS_IMAGE` 使用主程序仓库的 Container Registry 地址，`RUNTIME_IMAGE` 和 `FILEBEAT_IMAGE` 使用本仓库的 Registry 地址。`IMAGE_TAG=latest` 表示稳定版，`IMAGE_TAG=beta` 表示 Beta。私有镜像仓库需先运行 `docker login <GitLab registry 地址>`。

脚本会生成管理员密码、MySQL 密码及数据密钥。`.env` 不要提交；数据库卷和 `DATA_KEY` 应一起备份，升级后继续使用原密钥。

### 2. 拉取并启动

```sh
docker compose pull
docker compose up -d
docker compose ps
```

打开 http://127.0.0.1:8081 登录。管理员账号和密码分别见 `.env` 中的 `ADMIN_USERNAME`、`ADMIN_PASSWORD`。主程序在首次启动时自动初始化数据库表结构。

OpenResty 演示节点使用主机端口 18080、18180、18280；Control API 端口为 18081、18181、18281。演示发布会通过 Docker socket 操作本地节点，并使用 `runtime/` 下的共享配置目录。Docker socket 赋予容器管理本机 Docker 的能力，只应在可信的开发或演示主机运行。

按需启动 NGINX 配置导入器：

```sh
docker compose --profile importer up -d importer
```

导入器只写入控制面资源，不会发布、校验或重载 OpenResty 配置。

查看日志及停止：

```sh
docker compose logs -f openresty-plus
docker compose down
```

`docker compose down -v` 会删除 MySQL、Redis、Kafka 数据卷。

## Release 与 Beta 镜像

`openresty-plus` monorepo 的 GitLab CI 在 `beta` 分支生成 Beta 二进制和单体应用镜像；推送 `vX.Y.Z` 或 `vX.Y.Z-beta.N` 标签时发布对应镜像并创建 Release，Release 附有可下载的 Linux 可执行文件。本仓库的 GitLab CI 发布 OpenResty Control API 与 Filebeat 演示镜像。GitLab Runner 需允许启用 TLS 的 Docker-in-Docker；首次发布前，在两个项目的 GitLab CI/CD 设置中启用 Container Registry。

如果 GitHub 是源仓库，需将两个项目同步到 GitLab 并启用 GitLab CI/CD；GitHub 上的 `.gitlab-ci.yml` 不会自行触发 GitLab Pipeline。

## 目录

```text
docker-compose.yaml            预编译镜像启动配置
docker-compose.source.yaml     本地源码模式的演示服务配置
deploy/openresty/              OpenResty 演示节点镜像与配置
deploy/filebeat/               Filebeat 演示镜像与日志采集配置
scripts/start-source.sh        获取源码、生成配置并启动源码模式
scripts/dev-source.sh          编译程序并启动本地演示环境
scripts/init-compose-env.sh    生成 Compose 镜像模式的本地密钥
scripts/deploy/                节点登记、迁移及发布运维脚本
```
