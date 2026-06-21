# komari

基于 `ghcr.io/komari-monitor/komari` 的容器封装，加入 Cloudflare Tunnel、Caddy 反代、VLESS/VMESS 订阅、GitHub 私库备份/还原和脚本自动更新。

## Fork 后需要改哪些

- 源码仓库默认值集中在 `repo.conf`，普通 fork 只改这个文件即可。
  `repo.conf` 只决定脚本自动更新从哪个源码仓库拉取，和 Komari 程序版本无关。
- GitHub Actions 会自动发布到当前仓库对应的 GHCR 地址：`ghcr.io/<owner>/<repo>:latest`。
- Docker Compose 复制 `.env.example` 为 `.env` 后，集中修改镜像、备份仓库、隧道域名、密码和订阅配置。
- 自动更新脚本默认从 `repo.conf` 中的 `KOMARI_SOURCE_REPOSITORY`、`KOMARI_SOURCE_BRANCH` 拉取脚本；部署时仍可用同名环境变量临时覆盖。

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
- `KOMARI_LOCK_TIMEOUT_SECONDS` - 备份/还原任务僵死锁清理时间，默认 `60` 秒。正在运行的任务会按 PID 识别并跳过，不会被这个超时误清理
- `NO_AUTO_RENEW` - 设置为 `1` 时禁用每日脚本自动更新

### 版本和脚本来源

- `KOMARI_VERSION` - 构建镜像时使用的上游 `ghcr.io/komari-monitor/komari` 镜像 tag；为空或未指定时使用 `latest`。它只影响打包时选择哪个上游 Komari 版本，不影响 `repo.conf`
- `KOMARI_SOURCE_REPOSITORY` - 自动更新脚本来源仓库，默认来自 `repo.conf`
- `KOMARI_SOURCE_BRANCH` - 自动更新脚本来源分支，默认来自 `repo.conf`

GitHub Actions 手动触发时可以填写 `komari_version` 来构建指定上游版本；push 构建默认使用 `latest`。

### Caddy 和订阅

- `CADDY_PROXY_PORT` - Caddy 监听端口，默认 `8001`
- `CADDY_VERSION` - Caddy 版本，默认 `2.9.1`
- `UUID` - 订阅 UUID；为空或 `0` 时不启用订阅
- `CF_IP` - CDN 优选 IP 或可用入口域名，默认 `ip.sb`，不会默认使用 `ARGO_DOMAIN`
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

### 备份私库准备

先在 GitHub 创建一个私有仓库，专门保存 Komari 备份文件。容器启动时需要配置下面这些变量，变量完整时才会启用自动备份和自动还原：

```bash
-e GH_BACKUP_USER="你的 GitHub 用户名" \
-e GH_REPO="你的备份私库名" \
-e GH_BACKUP_BRANCH="main" \
-e GH_PAT="你的 GitHub PAT" \
-e GH_EMAIL="你的 Git 提交邮箱"
```

`GH_PAT` 需要能读写这个备份私库。建议只给备份私库授权，不要把公开源码仓库和备份仓库混用。

备份仓库中会生成这些文件：

- `komari-YYYY-MM-DD-HHMMSS.tar.gz` - 实际数据包，内容是 `/app/data`
- `latest.json` - 最新备份索引，记录文件名、大小、sha256 和创建时间
- `README.md` - 人可读的最新备份摘要，也可以用来触发立即备份

### 自动备份

`BACKUP_TIME` 控制定时备份，格式是 5 段 cron 表达式。默认每天执行一次：

```bash
-e BACKUP_TIME="0 20 * * *"
```

常用例子：

```bash
# 每小时一次
-e BACKUP_TIME="0 */1 * * *"

# 每 10 分钟一次
-e BACKUP_TIME="*/10 * * * *"
```

保留天数由 `BACKUP_DAYS` 控制，默认保留 10 天。备份和还原共用一把锁，正在运行的任务会跳过下一轮，异常遗留锁默认 60 秒后清理。

查看自动备份日志：

```bash
docker exec komari tail -n 100 /tmp/backup.log
```

### 立即备份

容器运行后，可以手动立刻备份一次：

```bash
docker exec komari /app/backup.sh
```

如果是在容器内部执行，使用：

```bash
bash /app/backup.sh
```

备份成功后，私库会出现新的 `komari-*.tar.gz`，并同步更新 `latest.json` 和 `README.md`。

### README 触发立即备份

也可以直接在备份私库的 `README.md` 第一行写入以下任意一种内容：

```text
backup
backup now
now
立即备份
```

容器每分钟运行的自动检查会识别这个指令，然后执行一次立即备份。备份完成后，脚本会把 `README.md` 改回最新备份摘要。

### 自动还原

容器启动时会先检查远程备份，之后每分钟执行一次：

```bash
docker exec komari /app/restore.sh a
```

自动还原读取顺序是：

1. 优先读取 `latest.json`
2. `latest.json` 不可用时读取备份私库 `README.md`
3. 最后回退到备份仓库文件列表里的最新 `komari-*.tar.gz`

脚本会比较本地记录和远程备份的文件名、sha256。只有远程出现新的备份时，才会下载并还原。还原成功后会尝试重启 Komari 进程让数据生效。

查看自动还原日志：

```bash
docker exec komari tail -n 100 /tmp/restore-cron.log
docker exec komari tail -n 100 /tmp/restore.log
```

### 手动还原

强制还原 `latest.json` 或 `README.md` 指向的最新备份：

```bash
docker exec komari /app/restore.sh f
```

列出备份文件并交互选择一个版本还原：

```bash
docker exec -it komari /app/restore.sh
```

指定某个备份文件还原：

```bash
docker exec komari /app/restore.sh komari-2024-01-01-120000.tar.gz
```

还原时脚本会先下载到临时文件，校验大小、sha256、tar 完整性和包内路径，确认只包含 `data/` 下的普通文件/目录后才替换现有数据目录。替换失败会尝试回滚旧数据。

如果还原成功但面板没有立刻刷新，可以手动重启容器：

```bash
docker restart komari
```

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
