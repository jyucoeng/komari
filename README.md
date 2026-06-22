# 🐳 Komari 容器增强版 (Auto-Backup / CF Tunnel / Xray)

基于上游 [komari-monitor/komari](https://github.com/komari-monitor/komari) 的深度增强封装版。在保留原版所有功能的基础上，开箱即用地集成了**数据防丢（GitHub 私库全自动备份）、极简内网穿透（Cloudflare Tunnel）、以及科学上网节点生成（Xray VLESS/VMESS）**。

## ✨ 核心特性

- 🔄 **全自动版本跟进**：每日自动同步上游最新版本，支持拉取指定版本号（如 `1.2.5`）或 `latest`。
- 💾 **GitHub 私库备份**：支持定时将面板数据打包推送至 GitHub 私有仓库，防止机器失联导致数据全毁。
- 🛡️ **无缝数据恢复**：新装机器拉取镜像后，自动从私库下载最新备份并无缝恢复。
- ☁️ **Cloudflare Tunnel**：无需公网 IP，无需放行端口，填入 Token 直接暴露至公网。
- 🚀 **节点自动生成**：内置 Caddy 和 Xray 后端，配置 UUID 后自动生成 VLESS/VMESS 订阅链接。

---

## 🛠️ 部署前准备

1. **准备一个 GitHub 私有仓库**：用于存放备份数据（例如命名为 `komari-bak`）。
2. **获取 GitHub PAT (Personal Access Token)**：
   - 前往 GitHub -> Settings -> Developer Settings -> Personal access tokens (classic)。
   - 生成一个新 Token，**必须勾选 `repo` 全部权限**，并妥善保存。
3. **获取 Cloudflare Tunnel Token**：用于内网穿透（也支持传入 argo json 凭据）。
4. **生成一个 UUID**：用于节点的密码验证。

---

## 🚀 快速部署

推荐使用 `Docker Compose` 进行部署，配置文件更清晰，后期修改更方便。

### 方式一：Docker Compose (推荐)

创建 `docker-compose.yml` 文件并填入以下内容：

```yaml
version: '3.8'
services:
  komari:
    # 想要固定版本可以修改为具体版本号，例如: ghcr.io/saodisengyyds/komari:1.2.5
    image: ghcr.io/saodisengyyds/komari:latest
    container_name: komari
    restart: unless-stopped
    ports:
      # 如果不使用 CF Tunnel，可以暴露端口直接访问 (25774为映射到宿主机的端口)
      - "25774:8001"
    volumes:
      - ./komari-data:/app/data
    environment:
      # --- GitHub 自动备份配置 ---
      - GH_BACKUP_USER=你的GitHub用户名
      - GH_REPO=你的备份私库名称 (例如 komari-bak)
      - GH_BACKUP_BRANCH=main
      - GH_PAT=你的GitHub_PAT
      - GH_EMAIL=你的GitHub邮箱
      - BACKUP_TIME="*/10 * * * *" # 定时备份频率，标准 cron 格式 (此例为每 10 分钟一次)
      
      # --- 面板基础配置 ---
      - ADMIN_USERNAME=你的面板管理账户
      - ADMIN_PASSWORD=***
      
      # --- Cloudflare Tunnel 内网穿透 ---
      - ARGO_DOMAIN=你的隧道域名 (例如 panel.yourdomain.com)
      - KOMARI_CLOUDFLARED_TOKEN=你的Clou…oken
      
      # --- Xray 订阅配置 (选填) ---
      - UUID=你的UUID # 留空或设为 0 则不启用订阅
```

运行启动命令：
```bash
docker compose up -d
```

### 方式二：Docker Run CLI

如果你更习惯一行命令解决，可以直接使用 `docker run`：

```bash
docker run -d \
 --name komari \
 --restart unless-stopped \
 -p 25774:8001 \
 -v ./komari-data:/app/data \
 -e GH_BACKUP_USER="你的GitHub用户名" \
 -e GH_REPO="你的备份私库名称" \
 -e GH_BACKUP_BRANCH="main" \
 -e GH_PAT="你的GitHub_PAT" \
 -e GH_EMAIL="你的GitHub邮箱" \
 -e ADMIN_USERNAME="面板账户" \
 -e ADMIN_PASSWORD="***" \
 -e ARGO_DOMAIN="隧道域名" \
 -e KOMARI_CLOUDFLARED_TOKEN="***" \
 -e UUID="你的UUID" \
 -e BACKUP_TIME="*/10 * * * *" \
 ghcr.io/saodisengyyds/komari:latest
```

---

## 🏷️ 版本说明

本镜像与上游 `komari-monitor/komari` 保持同步。你可以通过指定标签来锁定面板版本，防止意外升级导致的不兼容：

- **`latest`**: 永远拉取包含了最新自动备份装甲的最新面板核心。
- **`1.x.x`**: 固定拉取上游的对应版本（例如 `ghcr.io/saodisengyyds/komari:1.2.5`）。

---


---

## 🔗 订阅链接使用

如果你在配置中填写了 `UUID`，容器启动后会自动生成 Xray (VLESS/VMESS) 节点。获取订阅的方式非常简单，直接在浏览器或代理软件（如 v2rayN, Clash 等）中访问：

```text
https://你的面板域名/你配置的UUID
```
*(例如：`https://panel.yourdomain.com/e31bf435-b196-44c9-8b23-c64d7ba2c73e`)*

访问该地址即可直接获取/导入完整的节点订阅信息。


---

## 🔐 安全建议

强烈建议在首次登录 Komari 面板后，前往设置页面开启**两步验证 (2FA)**。这能有效防止面板密码泄露或被暴力破解，最大程度保障您的节点与服务器安全！

## 📂 备份与恢复说明

### 自动备份机制
配置好 GitHub 相关环境变量后，容器会在后台按 `BACKUP_TIME` 设定的频率（如 `*/10 * * * *` 为每十分钟）自动检查数据变更。
- 只有当面板数据发生**实际变动**时，才会触发打包并推送到 GitHub 私有仓库，最大程度减少垃圾 Commit。
- 默认保留最近 10 天的备份（由 `BACKUP_DAYS` 控制）。

### 自动恢复机制 (搬家/重装神技)
当你在全新的服务器上使用同样的 `docker run` 或 `docker-compose.yml` 启动时：
容器启动脚本会**优先连接 GitHub 检查是否有历史备份**。如果有，它会自动拉取最新的备份包进行数据覆盖，然后才启动面板进程。这意味着**整个迁移过程是无缝且全自动的**！

### 手动触发
如果需要手动介入，你可以进入容器内部执行：
```bash
# 立刻执行一次强制备份
docker exec komari bash /app/backup.sh

# 查看备份日志
docker exec komari tail -n 100 /tmp/backup.log
```
