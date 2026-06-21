# komari

基于 `ghcr.io/komari-monitor/komari` 的容器封装，加入 Cloudflare Tunnel、Caddy 反代、VLESS/VMESS 订阅、GitHub 私库备份/还原和脚本自动更新。

## Fork 后需要改哪些

- 源码仓库默认值集中在 `repo.conf`，普通 fork 只改这个文件即可。
- GitHub Actions 会自动发布到当前仓库对应的 GHCR 地址：`ghcr.io/<owner>/<repo>:latest`。
- Docker Compose 复制 `.env.example` 为 `.env` 后，集中修改镜像、备份仓库、隧道域名、密码和订阅配置。
- 自动更新脚本会从 `repo.conf` 或镜像构建时写入的 `KOMARI_SOURCE_REPOSITORY`、`KOMARI_SOURCE_BRANCH` 拉取脚本。

## 快速开始

```bash
IMAGE="ghcr.io/hynize/komari:latest"
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

## 环境变量

### 必需

- `ADMIN_USERNAME` - 面板用户名
- `ADMIN_PASSWORD` - 面板密码
- `ARGO_DOMAIN` - Cloudflare Tunnel 域名
- `KOMARI_CLOUDFLARED_TOKEN` - Cloudflare Tunnel Token 或 JSON 凭据

### GitHub 备份

备份变量完整时才启用自动备份和自动还原。

- `GH_BACKUP_USER` - GitHub 用户名
- `GH_REPO` - 备份仓库名，建议私有仓库
- `GH_BACKUP_BRANCH` - 备份仓库分支，默认 `main`
- `GH_PAT` - GitHub Personal Access Token，需要仓库读写权限
- `GH_EMAIL` - Git 提交邮箱

### 备份和更新

- `BACKUP_TIME` - 5 段 cron 表达式，默认 `0 20 * * *`。例如每小时一次：`0 */1 * * *`
- `BACKUP_DAYS` - 备份保留天数，默认 `10`
- `KOMARI_LOCK_TIMEOUT_SECONDS` - 备份/还原任务锁超时时间，默认 `3600` 秒
- `NO_AUTO_RENEW` - 设置为 `1` 时禁用每日脚本自动更新

### 版本和脚本来源

- `KOMARI_VERSION` - 构建镜像时使用的上游 Komari 镜像 tag；为空或未指定时使用 `latest`
- `KOMARI_SOURCE_REPOSITORY` - 自动更新脚本来源仓库，默认来自 `repo.conf` 或构建参数
- `KOMARI_SOURCE_BRANCH` - 自动更新脚本来源分支，默认 `main`

GitHub Actions 手动触发时可以填写 `komari_version` 来构建指定上游版本；push 构建默认使用 `latest`。

### Caddy 和订阅

- `CADDY_PROXY_PORT` - Caddy 监听端口，默认 `8001`
- `CADDY_VERSION` - Caddy 版本，默认 `2.9.1`
- `UUID` - 订阅 UUID；为空或 `0` 时不启用订阅
- `CF_IP` - CDN 优选 IP 或可用入口域名；为空时跳过订阅生成，不会默认使用 `ARGO_DOMAIN`
- `SUB_NAME` - 订阅名称，默认 `komari`
- `XRAY_VLESS_PORT` - 容器内 VLESS WebSocket 后端端口，默认 `8002`
- `XRAY_VMESS_PORT` - 容器内 VMESS WebSocket 后端端口，默认 `8003`

### Web SSH / 远程功能

- `KOMARI_DISABLE_WEB_SSH` - 默认 `1`，启动前尝试关闭 Web SSH/终端能力。设为 `0` 可开放
- `KOMARI_DISABLE_REMOTE` - 默认 `1`，启动前尝试关闭远程命令能力。设为 `0` 可开放

如果上游 Komari 版本支持 `--disable-web-ssh` 参数，启动脚本会自动追加；不支持时不会强行传参，避免旧版本启动失败。

## Cloudflare Tunnel 架构

Cloudflare Tunnel 只需要把域名转发到容器内 Caddy：

```text
your-argo-domain.com -> http://localhost:8001
```

容器内部流量：

```text
Cloudflare Tunnel
        ↓
Caddy (:8001)
    ├── /      -> Komari 面板 (:25774)
    ├── /UUID  -> 订阅文件 (/tmp/list.log)
    ├── /vls*  -> Xray VLESS WS (:8002)
    └── /vms*  -> Xray VMESS WS (:8003)
```

此前订阅测速为 `-1` 的主要原因是订阅里生成了 `/vls`、`/vms`，但容器没有对应后端和 Caddy 转发。现在设置 `UUID` 后会生成 Xray 配置并启动本地 VLESS/VMESS WebSocket 后端。

## 备份和还原

### 自动备份

`backup.sh` 会把 `/app/data` 做一致性快照，打包为 `komari-YYYY-MM-DD-HHMMSS.tar.gz` 上传到备份私库，并维护：

- `latest.json` - 机器读取的最新备份索引，包含文件名、大小、sha256 和创建时间
- `README.md` - 给人看的最新备份摘要，也可作为恢复索引
- `komari-*.tar.gz` - 实际备份包

Cron 会按 `BACKUP_TIME` 执行：

```bash
docker exec komari /app/backup.sh bak
```

### README 触发立即备份

把备份私库 `README.md` 第一行改为以下任意一种，下一次自动还原检查会立即执行备份：

```text
backup
backup now
now
立即备份
```

### 自动还原

容器每分钟执行 `restore.sh a`。它会优先读取 `latest.json`，如果缺失或格式无效，再从备份私库 `README.md` 解析最新备份文件，最后才回退到文件列表。

自动还原会比较本地记录与远程文件名/sha256，只有远程出现新备份时才恢复。

### 手动操作

```bash
# 立即备份
docker exec komari /app/backup.sh

# 也可通过 restore.sh 触发备份
docker exec komari /app/restore.sh backup

# 不带参数列出备份文件并选择还原
docker exec -it komari /app/restore.sh

# 手动还原指定备份文件
docker exec komari /app/restore.sh komari-2024-01-01-120000.tar.gz

# 强制还原 latest.json/README.md 指向的最新备份
docker exec komari /app/restore.sh f
```

还原流程会先下载到临时文件，校验大小、sha256、tar 完整性和包内路径，确认只包含 `data/` 下的普通文件/目录后才替换现有数据目录。替换失败会尝试回滚旧数据。

## 脚本自动更新

默认每天 UTC 03:30 从源码仓库更新：

- `repo.conf`
- `backup.sh`
- `restore.sh`
- `sub_link.sh`

自动更新只替换脚本文件，不会主动重新生成订阅。订阅在容器启动时生成，也可手动运行：

```bash
docker exec komari /app/sub_link.sh
```

## 使用 Docker Compose

```bash
cp .env.example .env
# 编辑 .env 后启动
docker compose up -d
```

## 原始项目

- https://github.com/komari-monitor/komari
