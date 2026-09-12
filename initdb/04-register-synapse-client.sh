#!/bin/bash
# ============================================================================
# 注册 synapse 为 SSO 接入应用（机密客户端，BFF 模式）
# —— 接入清单 S0-1: sso-project-hub/03-checklists/synapse-sso-integration.html
#
# secret 与回调地址经 postgres 容器 environment 注入（来自 .env）；
# ON CONFLICT DO NOTHING 保证首启幂等。secret 轮换 = 服务器上手动
# UPDATE oauth_clients 后 docker compose restart synapse-api。
# ============================================================================
set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
INSERT INTO oauth_clients (client_id, client_secret, client_type, app_name,
                           redirect_uris, backchannel_logout_uri, require_pkce, status)
VALUES ('synapse',
        crypt('${SYNAPSE_SSO_CLIENT_SECRET}', gen_salt('bf', 12)),
        1,
        'Synapse SkillHub',
        '["${SYNAPSE_REDIRECT_URI}"]',
        '${SYNAPSE_BACKCHANNEL_LOGOUT_URI}',
        0, 1)
ON CONFLICT (client_id) DO NOTHING;
EOSQL
