#!/bin/bash
# ============================================================================
# /opt/platform 服务器首次初始化（幂等：已有文件一律跳过，绝不覆盖）
#
# 自动完成:
#   1. 备案期自签证书（8443 入口，CN=服务器公网 IP）
#   2. 从 .env.example 生成 .env——所有可随机生成的密钥自动填充:
#      数据库密码 ×2 / SSO 管理员密码 / SSO client secret / Cookie 双钥 /
#      metrics token / 内部回调 token / LLM 密钥加密钥
#
# 不自动填、需人工填的（vim .env）:
#   SMTP_*（邮箱授权码）/ LLM_API_KEY / SKILL_SCANNER_LLM_API_KEY /
#   SUPABASE_*（过渡期 Storage）
#
# 数据说明（不用手动配数据）: postgres 首启时 initdb/ 自动执行——
#   01 建 synapse 库+账号 / 02 sso_auth 表结构 / 03 种子+管理员 /
#   04 注册 synapse SSO client
# ============================================================================
set -euo pipefail
cd /opt/platform

# ---- 1. 自签证书 ----
if [ ! -f certs/self-signed/server.crt ]; then
  mkdir -p certs/self-signed
  IP=$(grep -oE 'https://[0-9.]+' .env.example | head -1 | grep -oE '[0-9.]+$')
  openssl req -x509 -newkey rsa:2048 -days 365 -nodes \
    -keyout certs/self-signed/server.key -out certs/self-signed/server.crt \
    -subj "/CN=${IP}"
  chmod 600 certs/self-signed/server.key
  echo "[OK] 自签证书已生成（CN=${IP}，有效期 365 天）"
else
  echo "[SKIP] 自签证书已存在"
fi

# ---- 1b. 443 正式证书占位 ----
# nginx 443 段引用 certs/fullchain.pem（备案后的 Let's Encrypt 证书）。
# 备案期文件不存在会导致 nginx 启动失败，故先生成临时自签占位；
# 备案通过后用 acme.sh 申请的正式证书覆盖同名文件即完成切换。
if [ ! -f certs/fullchain.pem ]; then
  IP=$(grep -oE 'https://[0-9.]+' .env.example | head -1 | grep -oE '[0-9.]+$')
  openssl req -x509 -newkey rsa:2048 -days 365 -nodes \
    -keyout certs/privkey.pem -out certs/fullchain.pem -subj "/CN=${IP}"
  chmod 600 certs/privkey.pem
  echo "[OK] 443 临时自签占位证书已生成（备案后覆盖同名文件切换）"
else
  echo "[SKIP] 443 证书已存在"
fi

# ---- 2. .env 生成 ----
if [ -f .env ]; then
  echo "[SKIP] .env 已存在（不覆盖）"
else
  cp .env.example .env
  gen()  { openssl rand -hex 24; }
  gen32() { openssl rand -hex 32; }
  sed -i \
    -e "s|^SSO_DB_PASSWORD=.*|SSO_DB_PASSWORD=$(gen)|" \
    -e "s|^SYNAPSE_DB_PASSWORD=.*|SYNAPSE_DB_PASSWORD=$(gen)|" \
    -e "s|^SSO_ADMIN_PASSWORD=.*|SSO_ADMIN_PASSWORD=$(gen)|" \
    -e "s|^SYNAPSE_SSO_CLIENT_SECRET=.*|SYNAPSE_SSO_CLIENT_SECRET=$(gen)|" \
    -e "s|^SSO_COOKIE_KEYS=.*|SSO_COOKIE_KEYS=$(gen32),$(gen32)|" \
    -e "s|^SSO_METRICS_TOKEN=.*|SSO_METRICS_TOKEN=$(gen)|" \
    -e "s|^DEFAULT_ADMIN_PASSWORD=.*|DEFAULT_ADMIN_PASSWORD=$(gen)|" \
    -e "s|^INTERNAL_CALLBACK_TOKEN=.*|INTERNAL_CALLBACK_TOKEN=$(gen)|" \
    -e "s|^LLM_KEY_ENCRYPTION_KEY=.*|LLM_KEY_ENCRYPTION_KEY=$(gen32)|" \
    .env
  chmod 600 .env
  echo "[OK] .env 已生成，密钥已随机填充（600 权限）"
fi

# ---- 3. 待办清单 ----
echo
echo "================ 剩余待人工填写（vim /opt/platform/.env）================"
grep -n 'change-me' .env | grep -v '^\s*#' || echo "（无——全部已就绪）"
echo "=========================================================================="
echo
echo "下一步: 填完后起基建验证:"
echo "  docker compose -f compose.prod.yml --env-file .env up -d postgres redis scanner-redis"
echo "镜像就绪前先登录 ACR（拉私有镜像的凭证，一次性）:"
echo "  docker login \$(grep -oP '^ACR_REGISTRY=\\K.*' .env)"
echo "镜像（sso-auth 等）就绪后全栈:"
echo "  docker compose -f compose.prod.yml --env-file .env up -d"
echo "最后挂轮询（正式进入自动部署）:"
echo "  chmod +x /opt/platform/deploy-loop.sh"
echo "  (crontab -l 2>/dev/null; echo '*/5 * * * * /opt/platform/deploy-loop.sh >> /var/log/platform-deploy.log 2>&1') | crontab -"
