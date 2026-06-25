# Komari

基于 Komari 的增强封装，集成 Cloudflare Tunnel、Caddy 反代、VLESS/VMESS 订阅、GitHub 备份和脚本自动更新。

## 📚 快速导航

- **[架构说明](#0-架构说明)** - 了解系统架构
- **[1. Fork 后的操作](#1-fork-后的操作)** - 修改配置并发布镜像
- **[2. 前置准备](#2-前置准备)** - 配置 Cloudflare Tunnel
- **[3. 快速开始](#3-快速开始)** - 选择部署方式
- **[4. 部署指南](#4-部署指南)** - 详细部署步骤
- **[5. 备份和还原](#5-备份和还原)** - 备份管理
- **[6. 更新和卸载](#6-更新和卸载)** - 维护操作
- **[7. 故障排查](#7-故障排查)** - 常见问题解决
- **[8. 环境变量参考](#8-环境变量参考)** - 配置文档
- **[9. 安全防护](#9-安全防护)** - 安全建议

---

<a id="0-架构说明"></a>

## 架构说明

Cloudflare Tunnel 只需要把域名转发到容器内 Caddy，Caddy 负责路由转发到各个服务：

**Cloudflare Tunnel 配置：**
```
Public hostname: your-domain.com
Type: HTTP
URL: http://localhost:8001
```

**容器内部流量路由：**
```
Cloudflare Tunnel
        ↓
Caddy (:8001)
    ├── /       → Komari 面板 (:25774)
    ├── /UUID   → 订阅文件 (/tmp/list.log)
    ├── /vls*   → Xray VLESS WS (:8002)
    └── /vms*   → Xray VMESS WS (:8003)
```

---

<a id="1-fork-后的操作"></a>

## 1. Fork 后的操作

### 第一步：修改源码仓库配置

Fork 本仓库后，编辑 `repo.conf` 文件，将 `jyucoeng` 改为你的 GitHub 用户名：

```bash
# repo.conf 修改前
KOMARI_PROJECT_OWNER="${KOMARI_PROJECT_OWNER:-jyucoeng}"

# repo.conf 修改后
KOMARI_PROJECT_OWNER="${KOMARI_PROJECT_OWNER:-YOUR_USERNAME}"
```

### 第二步：构建和发布镜像

#### 自动构建（推荐）

GitHub Actions 会自动：
1. 检测 `main` 分支的推送
2. 构建 Docker 镜像
3. 发布到 `ghcr.io/YOUR_USERNAME/komari:latest`

只需 push 代码即可，无需手动操作。

---

<a id="2-前置准备"></a>

## 2. 前置准备：Cloudflare Tunnel 配置

#### 0. 启用 gRPC 支持

1. 登录 [Cloudflare Dashboard](https://dash.cloudflare.com/)
2. 选择你要使用的域名
3. 进入 **网络** 选项
4. 找到 **gRPC** 开关，将其启用打开

#### 1. 创建 Cloudflare Tunnel

1. 登录 [Cloudflare Dashboard](https://dash.cloudflare.com/)
2. 进入 **Zero Trust** → **Networks** → **Tunnels**
3. 点击 **Create a tunnel**，给隧道命名（如 `komari`）
4. 选择 **Any OS**（推荐）

#### 2. 获取隧道凭据

**Token 格式（推荐）**
- 复制 Token，格式为 `eyJ...`
- 用于 `KOMARI_CLOUDFLARED_TOKEN` 环境变量

**JSON 格式（备选）**
- 下载 `.json` 凭据文件，将完整内容复制到 `KOMARI_CLOUDFLARED_TOKEN`

#### 3. 配置隧道路由

在 Cloudflare Tunnel 控制面板添加：
```
Public hostname: your-domain.com
Type: HTTP
URL: localhost:8001
```

#### 4. GitHub 授权准备

为 Komari 创建 GitHub OAuth 应用，用于面板登录授权认证：

获取 github 认证授权: https://github.com/settings/applications/new

**填写应用信息**（假设你的 Komari 主页域名为 `komari.xxxx.nyc.mn`）：

- **Application name**: `komari`
- **Homepage URL**: `https://komari.xxxx.nyc.mn/`
- **Application description**: `Komari Dashboard`
- **Authorization callback URL**: `https://komari.xxxx.nyc.mn/api/oauth_callback`

创建后，你将获得：
- **Client ID**
- **Client Secret**

在 Komari 面板设置中配置这两个值即可启用 GitHub 登录授权。

#### 5. 获取 GitHub 的 PAT (Personal Access Token)

用于 GitHub 备份和自动更新功能：

1. 访问 [GitHub Personal Access Tokens](https://github.com/settings/tokens/new)
2. 设置 Token 名称（如 `komari-backup`）
3. 选择过期时间（建议不设置过期或设置较长时间）
4. 选择所需的权限范围：
   - ✅ **repo** - 完整的仓库访问权限
   - ✅ **workflow** - 工作流文件管理权限
5. 点击 **Generate token**
6. 复制生成的 token（只会显示一次，务必保管好）

将这个 PAT 作为 `GH_PAT` 环境变量使用。

---

<a id="3-快速开始"></a>

## 3. 快速开始

### 部署方式选择

选择适合你的部署方式：

- **[方式一：Docker Compose](#方式一docker-compose推荐)** (推荐) - 一键部署，开箱即用，容器化隔离
- **[方式二：Docker Run](#方式二docker-run)** - 单条命令启动，无需 docker-compose.yml
- **[方式三：VPS 原生安装](#方式三vps-原生安装无-docker-环境)** - 性能最优，需要 Linux/macOS，直接运行服务

---

<a id="4-部署指南"></a>

## 4. 部署指南

<a id="方式一docker-compose推荐"></a>

### 方式一：Docker Compose（推荐）

#### 使用 docker-compose.yml

项目中已包含 `docker-compose.yml`，其中标注了必填和可选配置。

#### 修改配置

编辑项目根目录的 `docker-compose.yml`，修改以下必填项：

```yaml
environment:
  # ===== 必填配置 =====

  # 面板登录凭证（必填）
  ADMIN_USERNAME: "yourusername"          # 改为你的用户名
  ADMIN_PASSWORD: "yourpassword"          # 改为你的密码

  # Cloudflare 隧道配置（必填，从前置步骤获取）
  ARGO_DOMAIN: "your-domain.com"
  KOMARI_CLOUDFLARED_TOKEN: "eyJxxxxx"

  # GitHub 备份配置（必填，全部填写才启用备份）
  GH_BACKUP_USER: "your_github_username"
  GH_REPO: "komari"
  GH_BACKUP_BRANCH: "main"
  GH_PAT: "ghp_xxxxxxxxxxxxxxxx"
  GH_EMAIL: "your-email@example.com"

  # ===== 可选配置 =====

  # 节点订阅（可选，设置 UUID 才启用）
  UUID: ""                                # 改为你的 UUID 以启用订阅
  CF_IP: "ip.sb"                          # 连接地址，可填优选 IP/域名
  SUB_NAME: "komari"
```

**提示：** 完整的 `docker-compose.yml` 模板已在项目中提供，直接编辑该文件中的环境变量即可。所有必填项需要完整填写，可选项可根据需要启用。

#### 启动容器

```bash
# 启动
docker compose up -d

# 查看日志
docker compose logs -f

# 等待启动完成（约 30-40 秒）
```

访问 `https://your-domain.com` 使用 Komari 面板。

---

<a id="方式二docker-run"></a>

### 方式二：Docker Run

#### 创建存储目录

```bash
mkdir -p ~/komari-data
```

#### 启动容器（完整配置）

```bash
docker run -d \
  --name komari \
  -p 25774:25774 \
  --restart unless-stopped \
  -e ADMIN_USERNAME="yourusername" \
  -e ADMIN_PASSWORD="yourpassword" \
  -e ARGO_DOMAIN="your-domain.com" \
  -e KOMARI_CLOUDFLARED_TOKEN="eyJxxxxx" \
  -e GH_BACKUP_USER="your_github_username" \
  -e GH_REPO="komari-backup" \
  -e GH_BACKUP_BRANCH="main" \
  -e GH_PAT="ghp_xxxxxxxxxxxxxxxx" \
  -e GH_EMAIL="your-email@example.com" \
  -e BACKUP_TIME="0 20 * * *" \
  -e BACKUP_DAYS="10" \
  -e KOMARI_DISABLE_WEB_SSH="1" \
  -e KOMARI_DISABLE_REMOTE="1" \
  -e UUID="" \
  -e CF_IP="ip.sb" \
  -e SUB_NAME="komari" \
  -v ~/komari-data:/app/data \
  ghcr.io/jyucoeng/komari:latest
```

#### 查看日志

```bash
docker logs -f komari
```

#### 停止容器

```bash
docker stop komari
docker rm komari
```

#### 重启容器

```bash
docker restart komari
```

---

<a id="方式三vps-原生安装无-docker-环境"></a>

### 方式三：VPS 原生安装（无 Docker 环境）

#### 一键安装

```bash
git clone https://github.com/jyucoeng/komari.git && cd komari && sudo bash install.sh
```

按照菜单选择 **普通 Linux/VPS 安装**，输入配置信息。

#### 安装位置

- 安装目录：`/opt/komari`
- 配置文件：`/opt/komari/conf/.env`
- 日志目录：`/opt/komari/logs`
- 数据目录：`/opt/komari/data`

#### 配置修改

如需修改配置，编辑：

```bash
sudo nano /opt/komari/conf/.env
```

修改后重启服务：

```bash
sudo systemctl restart komari
```

---

<a id="5-备份和还原"></a>

## 5. 备份和还原

### 快速导航

选择你的环境：

- **[Docker 环境](#docker-环境-备份还原)**（Docker Compose 和 Docker Run 通用）
- **[VPS 原生环境](#vps-原生环境)**（无 Docker）
- **[备份库 README 手动操作](#备份库-readme-手动操作)**

---

<a id="docker-环境-备份还原"></a>

### 通用说明

GitHub 备份库的 `README.md` 第一行用于控制自动备份/还原行为：

**自动还原模式** - README 第一行填备份文件名：
```markdown
komari-2024-12-15-200000.tar.gz
```
服务启动时自动下载并还原。

**自动备份模式** - README 第一行填关键词：
```markdown
backup now
```
支持的关键词：`backup` / `backup now` / `立即备份`
服务启动时自动执行备份。

定时备份每次成功运行都会生成新的 `komari-*.tar.gz` 并更新备份库 README；不会因为数据未变化就跳过提交。`BACKUP_TIME` 使用 UTC，例如 `0 */8 * * *` 对应北京时间 08:00、16:00、00:00。

---

<a id="docker-环境-备份还原"></a>

### Docker 环境

#### 手动备份

```bash
docker exec komari /app/backup.sh
```

#### 手动还原

**方式 1：交互式选择**

```bash
docker exec -it komari /app/restore.sh
```

**方式 2：直接指定文件**

```bash
docker exec komari /app/restore.sh komari-2024-12-15-200000.tar.gz
```

**方式 3：强制还原备份库 README 第一行指定的文件**

```bash
docker exec komari /app/restore.sh f
```

#### 查看日志

```bash
docker exec komari cat /etc/crontabs/root
docker exec komari tail -f /tmp/backup.log
docker exec komari tail -f /tmp/restore-cron.log
```

Docker 还原完成后脚本只会尝试重启 Komari 进程，不会主动重启 cloudflared；若平台日志里出现历史 `Connection terminated`，通常是容器/隧道进程被重启时的连接关闭日志。

---

<a id="vps-原生环境"></a>

### VPS 原生环境

适用于 **VPS 原生安装**（无 Docker）部署方式。

#### 手动备份

```bash
komari-cli backup
# 或
bash /opt/komari/scripts/backup.sh
```

#### 手动还原

**方式 1：交互式选择**

```bash
komari-cli restore
```

**方式 2：直接指定文件**

```bash
komari-cli restore komari-2024-12-15-200000.tar.gz
```

**方式 3：强制还原备份库 README 第一行指定的文件**

```bash
komari-cli restore f
```

#### 查看日志

```bash
tail -f /opt/komari/logs/backup.log
tail -f /opt/komari/logs/restore-cron.log
```

---

<a id="备份库-readme-手动操作"></a>

### 备份库 README 手动操作

#### 设置自动还原

编辑备份仓库 `README.md` 第一行为备份文件名，服务启动时自动还原：

```markdown
# Komari 备份管理

还原版本：komari-2024-12-15-200000.tar.gz

## 备份列表

| 文件名 | 备份时间 | 大小 |
|---|---|---|
| komari-2024-12-15-200000.tar.gz | 2024-12-15 20:00 | 50MB |
| komari-2024-12-14-200000.tar.gz | 2024-12-14 20:00 | 48MB |
```

#### 设置自动备份

编辑备份仓库 `README.md` 第一行为关键词，服务启动时自动备份：

```markdown
backup

最后备份时间：2024-12-15 20:00:00 UTC
```

#### 常见问题

| 问题 | 答案 |
|---|---|
| 如何快速还原最新备份？ | 编辑备份库 README 第一行为备份文件名，服务启动自动还原 |
| 备份保留多久？ | 由 `BACKUP_DAYS` 控制，默认 10 天，过期自动删除 |
| 能否修改备份时间？ | 可以，修改 `BACKUP_TIME`（UTC cron 表达式） |
| 是否支持手动触发备份？ | 支持，使用对应环境的命令立即执行备份 |

---

<a id="6-更新和卸载"></a>

## 6. 更新和卸载

### 快速导航

选择你的环境：

- **[Docker 环境](#docker-环境-更新卸载)**（Docker Compose 和 Docker Run 通用）
- **[VPS 原生环境](#vps-原生环境-更新卸载)**（无 Docker）

---

<a id="docker-环境-更新卸载"></a>

### Docker 环境（更新和卸载）

适用于 **Docker Compose** 和 **Docker Run** 部署方式。

#### 更新容器镜像

```bash
# 拉取最新镜像
docker pull ghcr.io/jyucoeng/komari:latest

# 如果使用 Docker Compose，重启容器
docker compose down
docker compose up -d

# 如果使用 Docker Run，需要删除旧容器后重新启动
docker stop komari
docker rm komari
docker run -d \
  --name komari \
  -p 25774:25774 \
  --restart unless-stopped \
  -e ADMIN_USERNAME="yourusername" \
  -e ADMIN_PASSWORD="yourpassword" \
  -e ARGO_DOMAIN="your-domain.com" \
  -e KOMARI_CLOUDFLARED_TOKEN="eyJxxxxx" \
  -e GH_BACKUP_USER="your_github_username" \
  -e GH_REPO="komari-backup" \
  -e GH_BACKUP_BRANCH="main" \
  -e GH_PAT="ghp_xxxxxxxxxxxxxxxx" \
  -e GH_EMAIL="your-email@example.com" \
  -e BACKUP_TIME="0 20 * * *" \
  -e BACKUP_DAYS="10" \
  -e KOMARI_LOCK_TIMEOUT_SECONDS="60" \
  -e NO_AUTO_RENEW="" \
  -e CADDY_PROXY_PORT="8001" \
  -e CADDY_VERSION="2.9.1" \
  -e KOMARI_DISABLE_WEB_SSH="1" \
  -e KOMARI_DISABLE_REMOTE="1" \
  -e UUID="" \
  -e CF_IP="ip.sb" \
  -e SUB_NAME="komari" \
  -v ~/komari-data:/app/data \
  ghcr.io/jyucoeng/komari:latest
```

#### 查看日志和状态

```bash
# Docker Compose 方式
docker compose logs -f

# Docker Run 方式
docker logs -f komari

# 只看 Caddy 日志
docker logs -f komari | grep caddy

# 查看订阅日志
docker exec komari tail -f /tmp/list.log

# 查看容器状态
docker ps | grep komari
```

#### 完全卸载

**Docker Compose 方式：**

```bash
# 停止容器
docker compose down

# 删除数据卷（删除所有数据，谨慎操作）
docker volume rm komari_komari-data

# 删除配置目录
rm -rf komari-data
```

**Docker Run 方式：**

```bash
# 停止并删除容器
docker stop komari
docker rm komari

# 删除镜像（可选）
docker rmi ghcr.io/jyucoeng/komari:latest

# 删除数据目录（谨慎操作）
rm -rf ~/komari-data
```

---

<a id="vps-原生环境-更新卸载"></a>

### VPS 原生环境（更新和卸载）

适用于 **VPS 原生安装**（无 Docker）部署方式。

#### 常用命令

```bash
# 查看 Komari 进程状态
komari-cli status

# 查看详细日志
komari-cli logs komari
komari-cli logs caddy
komari-cli logs cron

# 重启服务
sudo systemctl restart komari
```

#### 系统日志位置

```bash
# Komari 主程序
tail -f /opt/komari/logs/komari.log

# Caddy 反代
tail -f /opt/komari/logs/caddy.log

# 备份日志
tail -f /opt/komari/logs/backup.log

# 还原日志
tail -f /opt/komari/logs/restore-cron.log

# 脚本更新日志
tail -f /opt/komari/logs/renew.log
```

#### 脚本自动更新

默认每天 UTC 03:30 自动更新脚本文件：
- `backup.sh`
- `restore.sh`
- `renew.sh`
- `sub_link.sh`

手动触发更新：

```bash
komari-cli update
```

查看更新日志：

```bash
tail -f /opt/komari/logs/renew.log
```

禁用自动更新，编辑 `/opt/komari/conf/.env`：

```bash
NO_AUTO_RENEW=1
```

#### 完全卸载

```bash
# 停止服务
sudo systemctl stop komari

# 删除所有文件和配置（谨慎操作）
sudo rm -rf /opt/komari

# 删除 systemd 服务
sudo rm -f /etc/systemd/system/komari.service
sudo systemctl daemon-reload
```

---

<a id="7-故障排查"></a>

## 7. 故障排查

### 7.1、如果备份或者还原时出现下方提示

```
============== 开始执行 Komari 备份任务 ==============
已有备份或还原任务正在运行，本次备份跳过。
```

代表后台有其他任务在执行，需要等待1分钟（KOMARI_LOCK_TIMEOUT_SECONDS 默认60s）解锁。

---

<a id="8-环境变量参考"></a>

## 8. 环境变量参考

### 快速导航

- **[必需配置](#必需配置)**
- **[可选配置 - 节点订阅](#可选配置--节点订阅)**
- **[可选配置 - 其他](#可选配置--其他)**

---

<a id="必需配置"></a>

### 必需配置

| 变量 | 说明 | 示例 |
|---|---|---|
| `ADMIN_USERNAME` | Komari 面板用户名 | `admin` |
| `ADMIN_PASSWORD` | Komari 面板密码 | `securepass123` |
| `ARGO_DOMAIN` | Cloudflare 隧道域名 | `komari.example.com` |
| `KOMARI_CLOUDFLARED_TOKEN` | Cloudflare Token 或 JSON | `eyJ...` 或 `{...}` |
| `GH_BACKUP_USER` | GitHub 用户名 | `username` |
| `GH_REPO` | 备份仓库名（建议私有） | `komari` |
| `GH_BACKUP_BRANCH` | 备份分支 | `main` |
| `GH_PAT` | GitHub Personal Access Token | `ghp_xxxxx` |
| `GH_EMAIL` | Git 提交邮箱 | `user@example.com` |

---

<a id="可选配置--节点订阅"></a>

### 可选配置 - 节点订阅

| 变量 | 默认值 | 说明 | 示例 |
|---|---|---|---|
| `UUID` | - | 订阅 UUID | `550e8400-e29b-41d4-a716-446655440000` |
| `CF_IP` | `ip.sb` | 连接地址，可填 CDN 优选 IP 或域名 | `saas.sin.fan` |
| `SUB_NAME` | `komari` | 订阅名称 | `komari` |

**节点订阅地址：**

设置 UUID 后，节点订阅链接地址为：

```
https://{ARGO_DOMAIN}/{UUID}
```

示例：
```
https://komari.example.com/550e8400-e29b-41d4-a716-446655440000
```

---

<a id="可选配置--其他"></a>

### 可选配置 - 其他

| 变量 | 默认值 | 说明 |
|---|---|---|
| `BACKUP_TIME` | `0 20 * * *` | UTC cron 表达式；`0 */8 * * *` 对应北京时间 08:00/16:00/00:00 |
| `BACKUP_DAYS` | `10` | 备份保留天数 |
| `CADDY_PROXY_PORT` | `8001` | Caddy 监听端口 |
| `KOMARI_DISABLE_WEB_SSH` | `1` | 设为 `0` 启用 Web SSH |
| `KOMARI_DISABLE_REMOTE` | `1` | 设为 `0` 启用远程命令 |
| `NO_AUTO_RENEW` | 空 | 设为 `1` 禁用脚本自动更新 |

---

<a id="9-安全防护"></a>

## 9. 安全防护

### 启用双因素认证（2FA）

🔐 **强烈推荐启用 2FA 保护您的 Komari 面板安全。**

#### 什么是 2FA？

双因素认证（Two-Factor Authentication）通过 TOTP（基于时间的一次性密码）验证器提供额外的安全保护。启用后，即使攻击者知道您的密码，也无法在没有验证器的情况下登录。

#### 使用验证器

启用 2FA 后，您需要使用验证器应用来生成实时验证码。推荐的验证器应用：

- **Google Authenticator** - iOS / Android
- **Microsoft Authenticator** - iOS / Android
- **Authy** - iOS / Android / Web
- **FreeOTP** - iOS / Android（开源）

#### 连接 Web SSH 时需要 2FA

启用 2FA 后，使用 Web SSH 功能时同样需要提供验证器中的实时验证码。这确保了远程访问的安全性。

#### 启用步骤

1. 登录 Komari 面板
2. 进入设置 → 账户
3. 启用 2FA 身份验证
4. 使用验证器应用扫描二维码
5. 输入验证器中生成的 6 位数验证码确认

#### 网络安全建议

- ✅ **启用 HTTPS/TLS** - 通过 Cloudflare Tunnel 自动提供
- ✅ **启用 2FA** - 强烈推荐
- ✅ **定期修改密码** - 建议每 3 个月修改一次
- ✅ **只在需要时启用 Web SSH** - 默认关闭更安全
- ✅ **限制远程命令功能** - 默认关闭，必要时才启用
- ✅ **定期备份配置** - 使用 GitHub 备份功能

---

## 感谢以下项目

- [Komari Backup](https://github.com/yutian81/komari-backup)
- [Komari Monitor](https://github.com/komari-monitor/komari) - 官方项目
- [Argo-Nezha-Service-Container](https://github.com/Kiritocyz/Argo-Nezha-Service-Container)
