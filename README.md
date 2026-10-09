# OpenResty Plus 快速启动

本仓库提供两种启动方式：源码联调，以及使用 GitLab Container Registry 中预编译镜像的 Docker Compose 启动。

## 选择启动方式

| 方式 | 适用场景 | 入口 |
| --- | --- | --- |
| 源码启动 | 本地开发、调试或修改代码 | `./scripts/start-source.sh` |
| Compose 镜像启动 | 快速体验已构建的控制面、前端和三节点演示环境 | `docker compose up -d` |

镜像启动方式使用 Linux Docker Engine 的 host network，控制面通过 Docker socket 管理本地演示节点。Docker Desktop 用户需要启用 Host Networking；推荐在 Linux 主机上运行。它会占用 3306、6379、8081、9092、18080–18082、18180–18182、18280–18282、8080 端口。

## 源码启动

需要 Git、Go 1.26.1、Node.js 22.18+ 或 24+、pnpm 11.16.0、Docker Compose 和 OpenSSL。

```sh
./scripts/start-source.sh
```

首次运行会克隆 backend、frontend、node-agent 和 nginx-importer 到本仓库目录下，并创建本地 `.env`。检查或修改 MySQL 本地开发密码后再次运行脚本。脚本随后调用 backend 仓库已有的 `dev.sh`，启动 Go 控制面、MySQL、Redis、Kafka、三个 OpenResty 示例节点和 Vite 前端。

- 前端：http://127.0.0.1:5666
- 控制面健康检查：http://127.0.0.1:8081/healthz
- 默认账号：`vben`；本地密码由启动脚本保存在 `runtime/dev/admin-password`
- 导入器：进入 `orp-nginx-importer/`，运行 `npm --prefix web install` 后执行 `./dev.sh`，访问 http://127.0.0.1:8091

停止源码模式的前端进程会停止 Go 控制面；数据库和中间件容器会保留。需要停止它们时，在 `orp-backend/` 执行 `docker compose --env-file ../.env -f docker-compose.yaml down`。保留数据时不要添加 `-v`。

Node Agent 需要外部节点的 mTLS 证书和 Agent 配置，详见 `orp-node-agent/README.md`；当前 Agent 只提供心跳和固定 reload 任务，还没有接入候选配置校验或发布批次。

## Compose 镜像启动

### 1. 配置镜像地址并生成本地密钥

```sh
./scripts/init-compose-env.sh
```

编辑 `.env`，将 `BACKEND_IMAGE`、`RUNTIME_IMAGE`、`FRONTEND_IMAGE` 和可选的 `IMPORTER_IMAGE` 改为各 GitLab 项目 Container Registry 显示的地址。确认 `IMAGE_TAG`：`latest` 使用最近稳定版本，`beta` 使用 Beta 分支构建。私有镜像仓库先执行 `docker login <GitLab registry 地址>`。

`init-compose-env.sh` 会生成本地管理员密码和 32 字节数据加密密钥；`.env` 不要提交到版本库。请将生成的密钥和数据库卷一并备份，后续升级必须沿用同一个 `OPENRESTY_DATA_KEY`。

### 2. 启动服务

```sh
docker compose pull
docker compose up -d
docker compose ps
```

打开 http://127.0.0.1:8080 登录。管理员账号为 `vben`，密码保存在 `.env` 的 `OPENRESTY_ADMIN_PASSWORD`。

控制面会自动初始化空数据库的表结构。首次使用时在界面创建 Center；之后可登记本地演示节点。三个 OpenResty 节点端口为 18080、18180、18280。发布演示依赖 Docker socket 和共享的 `runtime/` 配置目录，因此不要移除 backend 服务中的 socket 和目录挂载。

此 Compose 配置把宿主 Docker socket 提供给控制面，以支持本地演示节点状态和发布操作；Docker socket 赋予容器管理本机 Docker 的权限。仅在受信任的本地开发或演示主机运行，不要直接用于生产环境。

可选启动 NGINX 配置导入器：

```sh
docker compose --profile importer up -d importer
```

访问 http://127.0.0.1:8090。导入器只写入控制面资源，不会发布、校验或重载节点配置。

查看日志及停止：

```sh
docker compose logs -f backend
docker compose down
```

`docker compose down -v` 会删除 MySQL、Redis、Kafka 数据卷，请谨慎使用。

## Release 和 Beta 制品

每个独立项目的 `.gitlab-ci.yml` 在 `beta` 分支构建并推送 `beta` 与 `beta-<提交短 SHA>` 镜像；`vX.Y.Z` 和 `vX.Y.Z-beta.N` 标签推送对应版本镜像并创建 GitLab Release。backend 还发布 `openresty` 运行时镜像；node-agent 发布 Linux amd64 二进制压缩包。

CI 使用项目内置的 GitLab Container Registry 变量，无需把 Registry 凭据写入仓库。GitLab Runner 必须允许启用 TLS 的 Docker-in-Docker（Docker executor 使用 privileged 模式及 `/certs/client` 共享卷）。若 GitHub 是主仓库，请将仓库同步或镜像到 GitLab 并在 GitLab 启用 CI/CD；`.gitlab-ci.yml` 放在 GitHub 上本身不会启动 GitLab Pipeline。

首次发布前，在每个项目的 GitLab CI/CD 设置中启用 Container Registry。快速启动镜像模式要求 backend、frontend 和 backend 的 OpenResty 运行时镜像具有相同的 `IMAGE_TAG`。

## 目录

```text
docker-compose.yaml          预编译镜像启动配置
.env.compose.example         镜像地址与 Compose 参数模板
scripts/start-source.sh      拉取源码并启动本地开发环境
scripts/init-compose-env.sh  初始化镜像模式密钥与 .env
gateway/nginx.conf           前端与 Go API 同源入口
```
