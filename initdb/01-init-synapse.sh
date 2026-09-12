#!/bin/bash
# ============================================================================
# 共库分用户初始化（规划 P2.5）：platform-postgres 承载 sso_auth + synapse 两个库
#   - sso 用户 + sso_auth 库由 postgres 镜像 POSTGRES_USER/POSTGRES_DB 自动创建
#   - 本脚本创建 synapse 独立账号 + synapse 库，仅授权该库（互不越权）
#
# 仅在 pg_data 卷为空的首次初始化时执行（docker-entrypoint-initdb.d 机制）；
# 密码经 SYNAPSE_DB_PASSWORD 环境变量注入（postgres 服务 environment 透传）
# ============================================================================
set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
CREATE USER synapse WITH PASSWORD '${SYNAPSE_DB_PASSWORD}';
CREATE DATABASE synapse OWNER synapse;
-- 共库资源争抢防线（规划 §05）：synapse 慢查询不拖累同实例 SSO 登录，
-- 重报表查询走错峰
ALTER ROLE synapse SET statement_timeout = '30s';
GRANT ALL PRIVILEGES ON DATABASE synapse TO synapse;
EOSQL
