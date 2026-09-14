#!/bin/bash
# ============================================================================
# platform 轮询部署 · deploy-loop.sh（crontab 每 5 分钟）
#
# 架构（绕开 GitHub runner → ECS 的跨境 SSH）:
#   GitHub Actions 只负责 build + push 到 ACR（跨境仅 runner→ACR 一段）
#   ECS 上本脚本轮询拉取（国内拉国内 ACR，秒级）——
#   服务器不对 GitHub 暴露任何端口，安全组 22 可严格只放行自己 IP。
#
# 行为:
#   1) docker compose pull —— 无新镜像时是几秒的空操作
#   2) up -d —— 镜像有变才重建对应容器，其余 no-op（滚动更新）
#   3) 前端: skillhub-web 镜像当制品运输（docker cp 取出 dist 到挂载目录）
#
# 回滚: 改 .env 的 TAG=latest 为 TAG=<git-sha> 后手动
#       docker compose -f compose.prod.yml --env-file .env up -d
#       （轮询会遵循 .env 的 TAG；改回 latest 恢复追新）
#
# 前置（一次性，配置好后再挂 cron）:
#   1) docker login $ACR_REGISTRY   ← 拉私有镜像的凭证（ACR 访问凭证的用户名/固定密码）
#      凭证落在 /root/.docker/config.json，密码不进任何文件
#   2) chmod +x /opt/platform/deploy-loop.sh
#   3) crontab -e 追加:
#      */5 * * * * /opt/platform/deploy-loop.sh >> /var/log/platform-deploy.log 2>&1
#
# 配置文件更新（compose/nginx/initdb 变更时）:
#   服务器无法直连 GitHub（clone 实测超时），也不依赖 SSH:
#     · 当前: Workbench 文件树上传 platform-deploy.zip → 解压覆盖
#     · SSH 解封后: 本地 rsync -avz --exclude '.env' deploy/ root@<IP>:/opt/platform/
#   （.env 永远只在服务器上维护，git/zip 都不带）
# ============================================================================
set -uo pipefail
cd /opt/platform || exit 1

log() { echo "$(date '+%F %T') $*"; }

# 从 .env 取镜像坐标（compose 自身会加载 .env 全量，这里只取脚本用的两个）
eval "$(grep -E '^(ACR_REGISTRY|TAG)=' .env 2>/dev/null)"
ACR_REGISTRY="${ACR_REGISTRY:-}"
TAG="${TAG:-latest}"

# ---- 1. 后端镜像轮询 + 滚动 ----
if docker compose -f compose.prod.yml --env-file .env pull --quiet; then
  if docker compose -f compose.prod.yml --env-file .env up -d --remove-orphans; then
    log "compose 栈已同步（tag=${TAG}）"
  else
    log "ERROR: compose up 失败（检查 .env / 镜像），下轮重试"
  fi
else
  log "WARN: compose pull 失败（ACR 未连通或镜像未推送），跳过本轮"
fi

# ---- 2. 前端 dist 同步（skillhub-web 镜像 → docker cp → 挂载目录）----
IMG="${ACR_REGISTRY}/skillhub-web:${TAG}"
if [ -n "$ACR_REGISTRY" ] && docker pull -q "$IMG" >/dev/null 2>&1; then
  CID=$(docker create "$IMG")
  rm -rf /tmp/skillhub-stage && mkdir -p /tmp/skillhub-stage
  if docker cp "$CID":/usr/share/nginx/html/. /tmp/skillhub-stage/ 2>/dev/null; then
    # 清空+拷贝之间存在 <1s 的 404 窗口——低频发布可接受；
    # 目录路径不变（bind mount 不换 inode），运行中的 platform-nginx 不受影响
    find /opt/platform/skillhub-dist -mindepth 1 -delete
    cp -a /tmp/skillhub-stage/. /opt/platform/skillhub-dist/
    log "skillhub dist 已同步"
  else
    log "WARN: docker cp 取 dist 失败，保留旧版前端"
  fi
  docker rm "$CID" >/dev/null
  rm -rf /tmp/skillhub-stage
else
  log "WARN: pull ${IMG} 失败，跳过前端同步"
fi
