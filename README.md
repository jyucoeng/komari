# komari
## 当前镜像版本 v1.2.3

## Fork 后需要改哪些

- GitHub Actions 会自动把镜像发布到当前仓库对应的 GHCR 地址：`ghcr.io/<owner>/<repo>:latest`，fork 后不用改 workflow 里的用户名或仓库名。
- Docker Compose 只需要复制 `.env.example` 为 `.env`，集中修改镜像、备份仓库、隧道域名和密码等配置。
- 自动更新脚本默认从镜像构建时写入的仓库和分支拉取脚本，fork 后不需要改脚本里的仓库名；本地自建或特殊分支可在 `docker run` 时用 `KOMARI_SOURCE_REPOSITORY`、`KOMARI_SOURCE_BRANCH` 覆盖。

## 快速开始

```bash
IMAGE="ghcr.io/your_github_username/komari:latest"
GH_BACKUP_USER="your_github_username"
GH_REPO="your_private_repo_name"
GH_PAT="your_github_personal_access_token"
GH_EMAIL="your_github_email@example.com"
ADMIN_USERNAME="yourusername"
ADMIN_PASSWORD="yourpassword"
ARGO_DOMAIN="your-argo-domain.com"
KOMARI_CLOUDFLARED_TOKEN="eyJxxxxx"

docker run -d \
  --name komari \
  --restart unless-stopped \
  -p 25774:25774 \
  -v ./komari-data:/app/data \
  -e GH_BACKUP_USER="$GH_BACKUP_USER" \
  -e GH_REPO="$GH_REPO" \
  -e GH_PAT="$GH_PAT" \
  -e GH_EMAIL="$GH_EMAIL" \
  -e ADMIN_USERNAME="$ADMIN_USERNAME" \
  -e ADMIN_PASSWORD="$ADMIN_PASSWORD" \
  -e ARGO_DOMAIN="$ARGO_DOMAIN" \
  -e KOMARI_CLOUDFLARED_TOKEN="$KOMARI_CLOUDFLARED_TOKEN" \
  "$IMAGE"
```

## 必需的环境变量

### GitHub 备份

- `GH_BACKUP_USER` - GitHub 用户名
- `GH_REPO` - 备份仓库名（私有）
- `GH_BACKUP_BRANCH` - 备份仓库分支，默认 `main`
- `GH_PAT` - GitHub Personal Access Token（需要 repo 权限）
- `GH_EMAIL` - Git 提交邮箱

### 面板登录

- `ADMIN_USERNAME` - 面板用户名
- `ADMIN_PASSWORD` - 面板密码

### Cloudflare 隧道

- `ARGO_DOMAIN` - 服务器域名
- `KOMARI_CLOUDFLARED_TOKEN` - Cloudflare 隧道认证（Token 或 JSON 格式都支持）

## 可选的环境变量

### 备份配置

- `BACKUP_TIME` - Cron 表达式，默认 `0 20 * * *`（UTC 20:00）
- `BACKUP_DAYS` - 保留备份天数，默认 `10`
- `KOMARI_LOCK_TIMEOUT_SECONDS` - 备份/还原任务锁超时时间，默认 `3600` 秒
- `NO_AUTO_RENEW` - 禁用脚本自动更新（设置为 `1` 则禁用）

### Caddy 反代配置

- `CADDY_PROXY_PORT` - Caddy 监听端口，默认 `8001`（容器内外端口一致）
- `CADDY_VERSION` - Caddy 版本，默认 `2.9.1`（如 `2.8.4`）

### 节点订阅（可选）

- `UUID` - 节点订阅 UUID（未设置则跳过订阅功能）
- `CF_IP` - CDN 优选 IP 或可用入口域名。未设置时跳过订阅生成，不会默认使用 `ARGO_DOMAIN`
- `SUB_NAME` - 订阅名称，默认 `komari`

### 脚本更新来源（可选）

- `KOMARI_SOURCE_REPOSITORY` - 自动更新脚本来源仓库，默认由镜像构建时写入，例如 `your_github_username/komari`。使用 Docker Compose 时建议保持未设置，让镜像内置值生效。
- `KOMARI_SOURCE_BRANCH` - 自动更新脚本来源分支，默认由镜像构建时写入，通常为 `main`

## 部署方案

### 推荐：使用 Cloudflare 隧道

通过隧道访问 Komari 面板和获取订阅链接，无需暴露高端口。

**完整部署命令**：

```bash
IMAGE="ghcr.io/your_github_username/komari:latest"
GH_BACKUP_USER="your_github_username"
GH_REPO="your_private_repo_name"
GH_PAT="your_github_personal_access_token"
GH_EMAIL="your_github_email@example.com"
ADMIN_USERNAME="yourusername"
ADMIN_PASSWORD="yourpassword"
ARGO_DOMAIN="your-argo-domain.com"
KOMARI_CLOUDFLARED_TOKEN="eyJxxxxx"
UUID="your-uuid-here"

docker run -d \
  --name komari \
  --restart unless-stopped \
  -p 25774:25774 \
  -v ./komari-data:/app/data \
  -e GH_BACKUP_USER="$GH_BACKUP_USER" \
  -e GH_REPO="$GH_REPO" \
  -e GH_PAT="$GH_PAT" \
  -e GH_EMAIL="$GH_EMAIL" \
  -e ADMIN_USERNAME="$ADMIN_USERNAME" \
  -e ADMIN_PASSWORD="$ADMIN_PASSWORD" \
  -e ARGO_DOMAIN="$ARGO_DOMAIN" \
  -e KOMARI_CLOUDFLARED_TOKEN="$KOMARI_CLOUDFLARED_TOKEN" \
  -e UUID="$UUID" \
  "$IMAGE"
```

**架构说明**：

```
Cloudflare Tunnel（隧道）
        ↓
Caddy（反向代理，8001 端口）
    ├── / → Komari Panel（25774）
    └── /UUID → Subscription File（/tmp/list.log）
        ↓
    Komari（仪表板应用，25774）
```

**Cloudflare 隧道配置**：

在 [Cloudflare Zero Trust](https://dash.cloudflare.com/) 中配置隧道：

1. 进入 **Networks > Tunnels**，创建或选择隧道
2. 在隧道配置中添加路由规则：

```
域名: your-argo-domain.com
服务: http://localhost:8001
```

**说明**：
- Caddy 在容器内监听 **8001 端口**（默认 `CADDY_PROXY_PORT`）
- Cloudflare 隧道将 `https://your-argo-domain.com/` 转发到容器内的 Caddy
- 隧道到容器内 Caddy 使用 HTTP，公网访问仍由 Cloudflare 提供 HTTPS
- 所有流量通过隧道加密传输，不需要暴露额外的服务器端口
- 用户访问 `https://your-argo-domain.com/` → Komari 面板
- 当设置了 `UUID` 时，用户可访问 `https://your-argo-domain.com/UUID` → 获取 VLESS/VMESS 订阅链接
- 当未设置 `UUID` 时，仅可访问面板，订阅功能不可用

**如果改变 Caddy 端口**（如 `-e CADDY_PROXY_PORT="9000"`），需要同步更新 Cloudflare 隧道配置为 `http://localhost:9000`。

## 备份和还原

### 自动备份

根据 `BACKUP_TIME` 环境变量自动定时备份，备份数据包括面板配置、主题设置、服务器列表等。备份脚本会先复制一份数据快照，再把快照打包为 `komari-YYYY-MM-DD-HHMMSS.tar.gz` 上传到私有仓库。

备份仓库会同时维护：

- `latest.json` - 机器读取的最新备份索引，包含文件名、大小、sha256 和创建时间
- `README.md` - 给人看的最新备份摘要
- `komari-*.tar.gz` - 实际备份包

如果容器内有 `sqlite3`，脚本会对 `.db`、`.sqlite`、`.sqlite3` 文件先执行校验并生成一致性快照，减少运行中数据库被直接打包导致损坏的风险。备份和还原共用任务锁，避免 cron 同时执行时互相覆盖。

### 自动还原

容器会每分钟读取 GitHub 备份仓库中的 `latest.json`。自动还原不只比较文件名，还会比较 sha256；只有发现新的文件名或校验值变化时才下载并还原。

还原流程会先下载到临时文件，校验文件大小、sha256、tar 完整性和包内路径，确认只包含普通文件/目录且都在 `data/` 下后，才会替换现有数据目录。替换失败时会尝试恢复旧数据目录，避免坏包或下载失败先删掉现有数据。

**还原配置**：
- 需要设置：`GH_BACKUP_USER`、`GH_REPO`、`GH_EMAIL`、`GH_PAT`
- 如果这些变量都已设置，自动还原功能即可启用

### 手动操作

```bash
# 手动备份
docker exec komari /app/komari_bak.sh bak

# 手动还原（指定备份文件）
docker exec komari /app/restore.sh komari-2024-01-01-120000.tar.gz

# 强制还原最新备份
docker exec komari /app/restore.sh f

# 停止容器，手动还原后重启
docker stop komari
docker exec komari /app/restore.sh f
docker start komari
```

### 脚本自动更新

如果启用了自动更新功能（默认启用），容器会在每天 UTC 时间 03:30 自动从 Github 获取最新的备份、还原和订阅脚本，无需重新构建镜像。
当前自动更新范围包括 `komari_bak.sh`、`restore.sh` 和 `sub_link.sh`。
自动更新只替换脚本文件，不会主动重新生成订阅内容。订阅需要在容器启动时或手动运行 `sub_link.sh` 时生成。

**禁用自动更新**：
```bash
-e NO_AUTO_RENEW=1
```

## 进程管理

使用 Supervisor 管理后台进程（cron、komari、caddy、cloudflared）。如果某个进程意外退出会自动重启。

**进程列表**：
- `cron` - 定时备份任务
- `komari` - Komari 仪表板
- `caddy` - 反向代理和订阅文件服务器
- `cloudflared` - Cloudflare 隧道客户端

## 节点订阅工作原理

1. 容器启动时检查 `UUID`
2. 如果设置了 UUID，生成 Caddyfile 并启动 Caddy 反代
3. 如果同时设置了 UUID、ARGO_DOMAIN 和 CF_IP，调用 sub_link.sh 生成 VLESS 和 VMESS 订阅链接
4. 订阅链接保存到 `/tmp/list.log`
5. 客户端可通过 Caddy 反代访问订阅文件

**支持的协议**：
- VLESS（WebSocket + TLS）
- VMESS（WebSocket + TLS）

## 使用 Docker Compose

```bash
cp .env.example .env
# 编辑 .env 后启动
docker compose up -d
```

## 原始项目

- https://github.com/jyucoeng/komari
