# Komari

基于 Komari 的增强封装，集成 Cloudflare Tunnel、Caddy 反代、VLESS/VMESS 订阅、GitHub 备份和脚本自动更新。

---

## Fork 后的初始化

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

## 快速选择

- **Docker Compose** - 推荐，一键部署，开箱即用，容器化隔离
- **普通 VPS** - 原生安装，性能最优，需要 Linux/macOS，直接运行服务

---

## Cloudflare Tunnel 前置配置

**两种部署方式都需要先完成这一步！**

### 1. 在 Cloudflare 创建隧道

1. 登录 [Cloudflare Dashboard](https://dash.cloudflare.com/)
2. 进入 **Zero Trust** → **Networks** → **Tunnels**
3. 点击 **Create a tunnel**，给隧道命名（如 `komari`）
4. 选择 **Any OS**（推荐），复制显示的 Token 或下载 JSON 凭据

### 2. 获取隧道凭据

**选项 A：Token 格式（简单，推荐）**
- 复制 Token，格式为 `eyJ...` 
- 直接用于 `KOMARI_CLOUDFLARED_TOKEN`

**选项 B：JSON 格式（完整凭据）**
- 下载 `.json` 凭据文件
- 将完整内容复制到 `KOMARI_CLOUDFLARED_TOKEN`

### 3. 在隧道中添加公共主机名

在 Cloudflare Tunnel 控制面板中添加：

```
Public hostname: your-domain.com
Type: HTTP
URL: localhost:8001
```

---

# 部署指南

选择你的部署方式，按照对应章节进行安装和配置。

---

## 方案一：Docker（推荐）

### 1. 安装和启动

#### 方式 A：Docker Compose（最简单）

##### 一键部署

```bash
# 克隆项目
git clone https://github.com/hynize/komari.git && cd komari
```

##### 创建 docker-compose.yml（直接使用下面的内容）

项目中已经包含了 `docker-compose.yml`，但你也可以自己创建一个，内容如下：

```yaml
services:
  komari:
    image: "ghcr.io/你自己的github名字/komari:latest"
    container_name: komari
    restart: unless-stopped
    ports:
      - "25774:25774"
    environment:
      # GitHub 备份配置（备份和自动还原所需）
      GH_BACKUP_USER: "your_github_username"
      GH_REPO: "komari"
      GH_BACKUP_BRANCH: "main"
      GH_PAT: "ghp_xxxxxxxxxxxxxxxx"
      GH_EMAIL: "your-email@example.com"

      # 面板登录凭证（必需）
      ADMIN_USERNAME: "yourusername"
      ADMIN_PASSWORD: "yourpassword"

      # Cloudflare 隧道配置（必需）
      ARGO_DOMAIN: "your-domain.com"
      KOMARI_CLOUDFLARED_TOKEN: "eyJxxxxx"

      # 备份时间配置
      BACKUP_TIME: "0 20 * * *"    # 每天 20:00 UTC 备份
      BACKUP_DAYS: "10"             # 保留 10 天备份

      # Caddy 反代配置
      CADDY_PROXY_PORT: "8001"

      # Komari 远程功能开关（默认关闭，设置为0表示开启）
      KOMARI_DISABLE_WEB_SSH: "1"
      KOMARI_DISABLE_REMOTE: "1"

      # 节点订阅配置（设置 UUID 才启用）
      UUID: "你自己的UUID"
      CF_IP: "ip.sb"
      SUB_NAME: "komari"

    volumes:
      - ./komari-data:/app/data
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS http://localhost:25774/ >/dev/null && curl -fsS http://localhost:8001/ >/dev/null || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s
    logging:
      options:
        max-size: "5m"
        max-file: "5"
```

##### 修改配置

编辑上面的 YAML 内容，只需修改这些关键项：

```yaml
environment:
  # 面板登录凭证（必需）
  ADMIN_USERNAME: "yourusername"      # 改为你的用户名
  ADMIN_PASSWORD: "yourpassword"      # 改为你的密码

  # Cloudflare 隧道配置（必需，从前置步骤获取）
  ARGO_DOMAIN: "your-domain.com"
  KOMARI_CLOUDFLARED_TOKEN: "eyJxxxxx"

  # GitHub 备份配置（可选，全部填写才启用）
  GH_BACKUP_USER: "your_github_username"
  GH_REPO: "komari"
  GH_PAT: "ghp_xxxxxxxxxxxxxxxx"
  GH_EMAIL: "your-email@example.com"

  # 节点订阅（可选，设置 UUID 才启用）
  UUID: ""                            # 改为你的 UUID 以启用订阅
```

##### 启动容器

```bash
# 启动
docker compose up -d

# 查看日志
docker compose logs -f

# 等待启动完成（约 30-40 秒）
```

访问 `https://your-domain.com` 使用 Komari 面板。

---

#### 方式 B：Docker Run（无需 docker-compose.yml）

如果你只想用 `docker run` 命令启动，无需 clone 整个项目：

##### 创建配置目录

```bash
# 创建存储目录
mkdir -p ~/komari-data
```

##### 启动容器（完整配置）

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

##### 环境变量说明

###### 必需配置

| 环境变量 | 说明 | 示例值 |
|---|---|---|
| `ADMIN_USERNAME` | Komari 面板登录用户名 | `admin` |
| `ADMIN_PASSWORD` | Komari 面板登录密码 | `password123` |
| `ARGO_DOMAIN` | Cloudflare 隧道域名 | `komari.example.com` |
| `KOMARI_CLOUDFLARED_TOKEN` | Cloudflare Token 或 JSON 凭据 | `eyJ0eXAi...` |

###### GitHub 备份配置（全部填写才启用）

| 环境变量 | 说明 | 示例值 |
|---|---|---|
| `GH_BACKUP_USER` | GitHub 用户名 | `username` |
| `GH_REPO` | 备份仓库名（建议私有） | `komari` |
| `GH_BACKUP_BRANCH` | 备份分支名 | `main` |
| `GH_PAT` | GitHub Personal Access Token | `ghp_xxxxx` |
| `GH_EMAIL` | Git 提交邮箱 | `user@example.com` |

###### 备份策略配置

| 环境变量 | 说明 | 默认值 | 示例值 |
|---|---|---|---|
| `BACKUP_TIME` | 备份执行时间（cron 表达式） | `0 20 * * *` | `0 2 * * *` |
| `BACKUP_DAYS` | 备份文件保留天数 | `10` | `7` |
| `KOMARI_LOCK_TIMEOUT_SECONDS` | 备份锁定超时时间（秒） | `60` | `120` |

###### 脚本更新配置

| 环境变量 | 说明 | 设置方式 |
|---|---|---|
| `NO_AUTO_RENEW` | 禁用脚本自动更新 | 设为 `1` 则禁用，留空则启用 |

###### Caddy 反代配置

| 环境变量 | 说明 | 默认值 | 说明 |
|---|---|---|---|
| `CADDY_PROXY_PORT` | Caddy 反代监听端口 | `8001` | 用于反代 Komari 和提供订阅服务 |
| `CADDY_VERSION` | Caddy 版本号 | `2.9.1` | 无特殊需求不用修改 |


###### 远程功能开关（默认关闭）

| 环境变量 | 说明 | 默认值 | 启用方式 |
|---|---|---|---|
| `KOMARI_DISABLE_WEB_SSH` | 禁用 Web SSH 功能 | `1`（禁用） | 设为 `0` 则启用 |
| `KOMARI_DISABLE_REMOTE` | 禁用远程命令功能 | `1`（禁用） | 设为 `0` 则启用 |

###### 节点订阅配置（设置 UUID 才启用）

| 环境变量 | 说明 | 默认值 | 示例值 |
|---|---|---|---|
| `UUID` | 订阅 UUID（为空则不启用订阅） | - | `550e8400-e29b-41d4-a716-446655440000` |
| `CF_IP` | CDN 优选 IP 或域名 | `ip.sb` |  `saas.sin.fan` |
| `SUB_NAME` | 订阅名称 | `komari` | `MyProxy` |

##### 查看日志

```bash
# 查看启动日志
docker logs -f komari

# 等待启动完成（约 30-40 秒）
```

##### 停止容器

```bash
docker stop komari
docker rm komari
```

##### 重启容器

```bash
docker restart komari
```

---

### 2. 备份和还原


#### 备份操作

##### 模式一：Docker 

###### 手动备份

```bash
docker exec komari /app/backup.sh
```

###### 查看备份日志

```bash
docker exec komari tail -f /tmp/backup.log
```

---

##### 模式二：Docker Run


###### 手动备份

```bash
docker exec komari /app/backup.sh
```

###### 查看备份日志

```bash
docker exec komari tail -f /tmp/backup.log
```

---

##### 模式三：VPS 命令行


###### 手动备份

```bash
# 方式1：CLI 工具
komari-cli backup

# 方式2：直接运行脚本
bash /opt/komari/scripts/backup.sh
```

###### 查看备份日志

```bash
tail -f /opt/komari/logs/backup.log
```

---

#### 还原操作

##### 模式一：Docker Compose

###### 方式 1：备份库 README 模式（推荐）

编辑备份仓库的 `README.md` 第一行为备份文件名：

```markdown
komari-2024-12-15-200000.tar.gz
```

容器启动时自动还原。也可以手动触发：

```bash
docker exec komari /app/restore.sh f
```

###### 方式 2：交互式选择

```bash
docker exec -it komari /app/restore.sh
```

###### 方式 3：直接指定文件

```bash
docker exec komari /app/restore.sh komari-2024-12-15-200000.tar.gz
```

###### 查看还原日志

```bash
docker exec komari tail -f /tmp/restore-cron.log
```

---

##### 模式二：Docker Run

###### 方式 1：备份库 README 模式（推荐）

编辑备份仓库的 `README.md` 第一行为备份文件名：

```markdown
komari-2024-12-15-200000.tar.gz
```

手动触发还原：

```bash
docker exec komari /app/restore.sh f
```

###### 方式 2：交互式选择

```bash
docker exec -it komari /app/restore.sh
```

###### 方式 3：直接指定文件

```bash
docker exec komari /app/restore.sh komari-2024-12-15-200000.tar.gz
```

###### 查看还原日志

```bash
docker exec komari tail -f /tmp/restore-cron.log
```

---

##### 模式三：VPS 命令行

###### 方式 1：备份库 README 模式（推荐）

编辑备份仓库的 `README.md` 第一行为备份文件名：

```markdown
komari-2024-12-15-200000.tar.gz
```

手动触发还原：

```bash
komari-cli restore f
```

###### 方式 2：交互式选择

```bash
komari-cli restore
```

###### 方式 3：直接指定文件

```bash
komari-cli restore komari-2024-12-15-200000.tar.gz
```

###### 查看还原日志

```bash
tail -f /opt/komari/logs/restore-cron.log
```

---

#### 自动还原功能

容器/服务启动时自动检查备份仓库 `README.md` 的第一行：

**还原模式：** README 第一行是备份文件名
```markdown
komari-2024-12-15-200000.tar.gz
```
→ 自动下载并还原

**备份模式：** README 第一行是关键词
```markdown
backup now
```
支持的关键词：`backup` / `backup now` / `立即备份`
→ 自动执行一次备份

**查看自动操作日志：**

```bash
# Docker Compose / Docker Run
docker exec komari tail -f /tmp/restore-cron.log

# VPS
tail -f /opt/komari/logs/restore-cron.log
```

---

#### 备份库 README 使用指南

GitHub 备份库的 `README.md` 用于控制自动备份/还原行为。

**示例 - 设置自动还原：**

```markdown
# Komari 备份管理

还原版本：komari-2024-12-15-200000.tar.gz

## 备份列表

| 文件名 | 备份时间 | 大小 |
|---|---|---|
| komari-2024-12-15-200000.tar.gz | 2024-12-15 20:00 | 50MB |
| komari-2024-12-14-200000.tar.gz | 2024-12-14 20:00 | 48MB |
```

**示例 - 设置自动备份：**

```markdown
backup now

最后备份时间：2024-12-15 20:00:00 UTC
```

---

#### 常见问题

| 问题 | 答案 |
|---|---|
| 如何快速还原最新备份？ | 编辑备份库 README 第一行为最新备份文件名，服务下次启动自动还原 |
| 备份文件保留多久？ | 由 `BACKUP_DAYS` 控制，默认 10 天，过期自动删除 |
| 能否修改备份时间？ | 可以，修改 `BACKUP_TIME`（cron 表达式） |
| 是否支持手动触发备份？ | 支持，使用对应命令立即执行备份 |

---

### 3. 更新和卸载

#### Docker Compose 用户

##### 更新容器镜像

```bash
# 拉取最新镜像
docker pull ghcr.io/jyucoeng/komari:latest

# 重启容器（使用新镜像）
docker compose down
docker compose up -d
```

##### 查看日志和状态

```bash
# 查看所有日志
docker compose logs -f

# 只看 Caddy 日志
docker compose logs -f komari | grep caddy

# 查看订阅日志
docker exec komari tail -f /tmp/list.log
```

##### 完全卸载

```bash
# 停止容器
docker compose down

# 删除数据卷（删除所有数据，谨慎操作）
docker volume rm komari_komari-data

# 删除配置目录
rm -rf komari-data
```

---

#### Docker Run 用户

##### 更新容器镜像

```bash
# 停止并删除旧容器
docker stop komari
docker rm komari

# 拉取最新镜像
docker pull ghcr.io/jyucoeng/komari:latest

# 用新镜像重新启动容器（使用前面"启动容器"部分的完整命令）
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
  -e XRAY_VLESS_PORT="8002" \
  -e XRAY_VMESS_PORT="8003" \
  -e KOMARI_DISABLE_WEB_SSH="1" \
  -e KOMARI_DISABLE_REMOTE="1" \
  -e UUID="" \
  -e CF_IP="ip.sb" \
  -e SUB_NAME="komari" \
  -v ~/komari-data:/app/data \
  ghcr.io/jyucoeng/komari:latest
```

##### 查看日志和状态

```bash
# 查看所有日志
docker logs -f komari

# 查看订阅日志
docker exec komari tail -f /tmp/list.log

# 查看容器状态
docker ps | grep komari
```

##### 完全卸载

```bash
# 停止并删除容器
docker stop komari
docker rm komari

# 删除镜像（可选）
docker rmi ghcr.io/hynize/komari:latest

# 删除数据目录（谨慎操作）
rm -rf ~/komari-data
```

##### 保留数据卸载

```bash
# 只删除容器，保留数据目录
docker stop komari
docker rm komari

# 数据保存在 ~/komari-data 中，重新启动时使用相同的挂载点
```

---

## 方案二：普通 VPS（原生安装）

### 1. 安装

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

#### 配置修改（安装后）

如需修改配置，编辑：

```bash
sudo nano /opt/komari/conf/.env
```

修改后重启服务：

```bash
sudo systemctl restart komari
```

---

### 2. 备份和还原

备份和还原操作已在"方案一"的通用部分中详细说明。VPS 的具体命令如下：

**手动备份：**

```bash
komari-cli backup
# 或
bash /opt/komari/scripts/backup.sh
```

**手动还原（三种方式）：**

```bash
# 方式1：备份库 README 模式
komari-cli restore f

# 方式2：交互式选择
komari-cli restore

# 方式3：直接指定文件
komari-cli restore komari-2024-12-15-200000.tar.gz
```

**查看日志：**

```bash
tail -f /opt/komari/logs/backup.log
tail -f /opt/komari/logs/restore-cron.log
```

详细的备份配置和自动还原说明，请参考上面的 **"方案一 - 备份和还原"** 部分。

---

### 3. 常用命令

#### 查看状态

```bash
# 查看 Komari 进程状态
komari-cli status

# 查看详细日志
komari-cli logs komari
komari-cli logs caddy
komari-cli logs cron
```

#### 手动操作

```bash
# 手动备份
komari-cli backup

# 手动还原（交互式）
komari-cli restore

# 强制还原
komari-cli restore f

# 更新脚本（会自动检查新版本）
komari-cli update

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
tail -f /opt/komari/logs/restore.log

# 脚本更新日志
tail -f /opt/komari/logs/renew.log
```

#### 性能监控

```bash
# 查看内存占用
ps aux | grep komari

# 查看磁盘占用
du -sh /opt/komari

# 查看数据库大小
du -sh /opt/komari/data
```

---

### 4. 更新和卸载

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

# 删除 systemd 服务（如果有）
sudo rm -f /etc/systemd/system/komari.service
sudo systemctl daemon-reload
```

#### 保留数据卸载

如果想保留备份数据：

```bash
# 只删除程序，保留 /opt/komari/data
sudo rm -rf /opt/komari/scripts /opt/komari/conf

# 或者完整备份数据后再卸载
tar czf ~/komari-backup-$(date +%Y%m%d).tar.gz /opt/komari/data
```
---

## 配置参考

### 必需配置

| 变量 | 说明 | 示例 |
|---|---|---|
| `ADMIN_USERNAME` | Komari 面板用户名 | `admin` |
| `ADMIN_PASSWORD` | Komari 面板密码 | `securepass123` |
| `ARGO_DOMAIN` | Cloudflare 隧道域名 | `komari.example.com` |
| `KOMARI_CLOUDFLARED_TOKEN` | Cloudflare Token 或 JSON | `eyJ...` 或 `{...}` |

### 可选配置

#### GitHub 备份（所有字段都填才启用）

| 变量 | 说明 |
|---|---|
| `GH_BACKUP_USER` | GitHub 用户名 |
| `GH_REPO` | 备份仓库名（建议私有） |
| `GH_BACKUP_BRANCH` | 备份分支（默认 `main`） |
| `GH_PAT` | GitHub Personal Access Token |
| `GH_EMAIL` | Git 提交邮箱 |

#### 节点订阅（设置 UUID 则启用）

| 变量 | 说明 | 示例 |
|---|---|---|
| `UUID` | 订阅 UUID | `550e8400-e29b-41d4-a716-446655440000` |
| `CF_IP` | CDN 优选 IP 或域名 | `ip.sb` |
| `SUB_NAME` | 订阅名称 | `komari` |

#### 其他配置

| 变量 | 默认值 | 说明 |
|---|---|---|
| `BACKUP_TIME` | `0 20 * * *` | cron 表达式，备份时间（UTC） |
| `BACKUP_DAYS` | `10` | 备份保留天数 |
| `CADDY_PROXY_PORT` | `8001` | Caddy 监听端口 |
| `KOMARI_DISABLE_WEB_SSH` | `1` | 设为 `0` 启用 Web SSH |
| `KOMARI_DISABLE_REMOTE` | `1` | 设为 `0` 启用远程命令 |
| `NO_AUTO_RENEW` | 空 | 设为 `1` 禁用脚本自动更新 |

---

## Fork 后的修改

从其他项目 Fork 此仓库后：

1. **修改源码仓库**
   - 编辑 `repo.conf` 中的 `KOMARI_SOURCE_REPOSITORY` 和 `KOMARI_SOURCE_BRANCH`
   - 这决定脚本自动更新的来源

2. **发布镜像**
   - GitHub Actions 会自动发布到 `ghcr.io/<owner>/<repo>:latest`
   - 修改 `.env` 中的 `KOMARI_IMAGE` 指向自己的镜像

3. **修改部署信息**
   - 将 README 中的 `hynize/komari` 改为自己的用户名和仓库名

---

## 故障排查

### Docker 方式

**容器无法启动**

```bash
# 查看启动日志
docker compose logs komari

# 检查配置文件
docker exec komari cat /app/.env

# 检查必需的环境变量
docker exec komari env | grep -E "ADMIN_|ARGO_|KOMARI_CLOUDFLARED"
```

**订阅功能不工作**

```bash
# 检查是否设置了 UUID
docker exec komari env | grep UUID

# 检查 Xray 是否运行
docker exec komari ps aux | grep xray

# 检查订阅文件
docker exec komari cat /tmp/list.log

# 检查 Caddy 配置
docker exec komari cat /app/Caddyfile
```

### VPS 方式

**服务无法启动**

```bash
# 查看服务状态
sudo systemctl status komari

# 查看详细日志
journalctl -u komari -n 50

# 检查配置文件
cat /opt/komari/conf/.env
```

**订阅功能不工作**

```bash
# 检查是否设置了 UUID
grep UUID /opt/komari/conf/.env

# 查看订阅日志
tail -f /opt/komari/logs/backup.log

# 检查 Xray 进程
ps aux | grep xray
```

---

## 感谢以下项目

- https://github.com/komari-monitor/komari
- https://github.com/yutian81/komari-backup


