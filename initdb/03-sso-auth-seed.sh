#!/bin/bash
# ============================================================================
# SSO 认证中心 · 初始数据（源: auth-center/db/seed/001_init_data.sql）
#   1) 三个接入应用（应用 A/B 机密客户端；应用 C 公开客户端 + PKCE，演示用）
#   2) 一个生产管理员账号——密码经 postgres environment 注入（.env 的
#      SSO_ADMIN_PASSWORD，由 first-boot.sh 随机生成），不再使用源文件里的
#      开发态固定密码
# ============================================================================
set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
-- bcrypt 依赖 pgcrypto
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ---------- 演示接入应用注册（本地开发 client_secret 明文，生产不使用）----------
INSERT INTO oauth_clients (client_id, client_secret, client_type, app_name, redirect_uris, backchannel_logout_uri, require_pkce, status)
VALUES
('app_a', crypt('dev-secret-app-a', gen_salt('bf', 12)), 1, '应用 A',
 '["http://localhost:3001/auth/callback"]',
 'http://localhost:3001/auth/backchannel-logout', 0, 1),
('app_b', crypt('dev-secret-app-b', gen_salt('bf', 12)), 1, '应用 B',
 '["http://localhost:3002/auth/callback"]',
 'http://localhost:3002/auth/backchannel-logout', 0, 1),
('app_c', NULL, 2, '应用 C',
 '["http://localhost:3003/auth/callback"]',
 'http://localhost:3003/auth/backchannel-logout', 1, 1)
ON CONFLICT (client_id) DO NOTHING;

-- ---------- 生产管理员账号（role=1；密码见 .env 的 SSO_ADMIN_PASSWORD）----------
INSERT INTO users (user_id, email, password_hash, nickname, status, role)
VALUES ('u_100001', 'admin@example.com', crypt('${SSO_ADMIN_PASSWORD}', gen_salt('bf', 12)), '管理员', 1, 1)
ON CONFLICT (email) DO NOTHING;
EOSQL
