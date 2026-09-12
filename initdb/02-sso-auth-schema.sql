-- ============================================================
-- SSO 认证中心 · 初始化表结构（五表）
-- 依据: SSO_Design_Plan.md v2.4 §6（含 v2.3 修订: email 小写唯一 / audit JSONB）
-- 执行: docker exec -i sso-postgres psql -U sso -d sso_auth < 001_init_tables.sql
-- ============================================================

-- ---------- 6.1 用户表 ----------
CREATE TABLE IF NOT EXISTS users (
    id            BIGSERIAL    PRIMARY KEY,
    user_id       VARCHAR(32)  NOT NULL UNIQUE,          -- 对外用户 ID（u_100001）
    email         VARCHAR(128) NOT NULL UNIQUE,         -- 登录凭证，应用层统一小写后写入
    password_hash VARCHAR(255) NOT NULL,                -- bcrypt（cost ≥ 10）
    nickname      VARCHAR(64),
    avatar        VARCHAR(255),
    status        SMALLINT     NOT NULL DEFAULT 1,      -- 0-禁用 1-正常 2-未激活
    role          SMALLINT     NOT NULL DEFAULT 0,      -- 0-普通用户 1-管理员（阶段M：仅 DB 可改，防提权）
    created_at    TIMESTAMP    NOT NULL DEFAULT now(),
    updated_at    TIMESTAMP    NOT NULL DEFAULT now()
);

COMMENT ON TABLE  users                IS 'SSO 用户主表';
COMMENT ON COLUMN users.user_id        IS '对外用户 ID（u_ 前缀）';
COMMENT ON COLUMN users.email          IS '登录邮箱（统一小写存储，唯一）';
COMMENT ON COLUMN users.password_hash   IS 'bcrypt 哈希';
COMMENT ON COLUMN users.status         IS '0-禁用 1-正常 2-未激活';
COMMENT ON COLUMN users.role           IS '角色：0-普通用户 1-管理员（仅数据库可改，防提权）';

-- ---------- 6.2 应用注册表 ----------
CREATE TABLE IF NOT EXISTS oauth_clients (
    id                      BIGSERIAL    PRIMARY KEY,
    client_id               VARCHAR(64)  NOT NULL UNIQUE,
    client_secret           VARCHAR(255),              -- bcrypt 哈希存储；公开客户端为 NULL
    client_type             SMALLINT     NOT NULL DEFAULT 1,   -- 1-机密客户端 2-公开客户端
    app_name                VARCHAR(64)  NOT NULL,
    redirect_uris           TEXT         NOT NULL,     -- JSON 数组，精确匹配
    backchannel_logout_uri  VARCHAR(255),              -- SLO 登出回调（阶段三 C2 使用）
    require_pkce            SMALLINT     NOT NULL DEFAULT 0,
    status                  SMALLINT     NOT NULL DEFAULT 1,  -- 0-禁用 1-启用
    sso_enabled             SMALLINT     NOT NULL DEFAULT 1,  -- 0-仅旧入口 1-SSO入口开放（B8 双跑开关）
    created_at              TIMESTAMP    NOT NULL DEFAULT now()
);

COMMENT ON TABLE  oauth_clients                     IS '接入应用注册表（SP）';
COMMENT ON COLUMN oauth_clients.client_secret       IS '应用密钥（bcrypt 哈希；公开客户端为 NULL）';
COMMENT ON COLUMN oauth_clients.client_type          IS '1-机密客户端（后端持有 secret） 2-公开客户端（强制 PKCE）';
COMMENT ON COLUMN oauth_clients.redirect_uris       IS '允许的重定向地址 JSON 数组，精确匹配';
COMMENT ON COLUMN oauth_clients.backchannel_logout_uri IS 'Backchannel Logout 回调地址';
COMMENT ON COLUMN oauth_clients.require_pkce       IS '是否强制 PKCE（公开客户端恒为 1）';

-- ---------- 6.3 存量账号映射表（阶段二迁移用，先建好）----------
CREATE TABLE IF NOT EXISTS user_account_links (
    id             BIGSERIAL    PRIMARY KEY,
    user_id        VARCHAR(32)  NOT NULL,               -- SSO 用户 ID
    app_code       VARCHAR(32)  NOT NULL,              -- 来源应用标识（app_a/app_b/app_c）
    legacy_user_id VARCHAR(64)  NOT NULL,              -- 原应用用户 ID
    migrate_type   SMALLINT     NOT NULL,               -- 1-方案A重置 2-方案B首登迁移
    migrated_at    TIMESTAMP,
    UNIQUE (app_code, legacy_user_id),
    UNIQUE (user_id, app_code)
);

COMMENT ON TABLE  user_account_links           IS '存量账号映射表（阶段二 B5-B8 使用）';
COMMENT ON COLUMN user_account_links.migrate_type IS '0-SSO已有账号直接映射 1-方案A重置密码 2-方案B首登迁移';
COMMENT ON COLUMN user_account_links.migrated_at  IS '迁移完成时间（未迁移为 NULL）';

-- ---------- 7.x 密码迁移过渡表（B7 方案 B：旧哈希达标，首登无感迁移）----------
CREATE TABLE IF NOT EXISTS migration_credentials (
    id              BIGSERIAL    PRIMARY KEY,
    email           VARCHAR(128) NOT NULL UNIQUE,
    old_hash        VARCHAR(255) NOT NULL,               -- 达标的旧哈希（仅 bcrypt 类进入）
    old_algo        VARCHAR(32)  NOT NULL,              -- 算法标识（bcrypt）
    app_code        VARCHAR(32)  NOT NULL,
    legacy_user_id  VARCHAR(64)  NOT NULL,
    status          SMALLINT     NOT NULL DEFAULT 0,     -- 0-待迁移 1-已迁移（删除行即完成，此字段留扩展）
    created_at      TIMESTAMP    NOT NULL DEFAULT now(),
    migrated_at     TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_migration_credentials_pending ON migration_credentials (email) WHERE status = 0;
COMMENT ON TABLE  migration_credentials        IS '密码迁移过渡表（方案B）：旧哈希仅存此处，首登校验成功即重哈希并删除（§5.2 步骤三）';
COMMENT ON COLUMN migration_credentials.email  IS '账号邮箱（与 users.email 对齐，小写）';
COMMENT ON COLUMN migration_credentials.old_hash IS '应用侧达标旧哈希；弱哈希（md5/sha1）永不入此表';

-- ---------- 6.4 审计日志表（只增不改）----------
CREATE TABLE IF NOT EXISTS audit_logs (
    id         BIGSERIAL    PRIMARY KEY,
    user_id    VARCHAR(32),
    client_id  VARCHAR(64),
    action     VARCHAR(32)  NOT NULL,                  -- login_success/login_fail/logout/token_refresh/
                                                          -- token_revoke/replay_detected/account_lock/password_change
    result     SMALLINT     NOT NULL,                  -- 0-失败 1-成功
    ip         VARCHAR(45),                            -- 支持 IPv6
    user_agent VARCHAR(512),
    detail     JSONB,                                  -- 扩展事件上下文
    created_at TIMESTAMP    NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_audit_user_time   ON audit_logs (user_id, created_at);
CREATE INDEX IF NOT EXISTS idx_audit_action_time ON audit_logs (action, created_at);

COMMENT ON TABLE  audit_logs    IS '审计日志（只增不改；生产引入按月分区，阶段四 D1 前）';
COMMENT ON COLUMN audit_logs.detail IS '事件扩展上下文（JSONB）';

-- ---------- 6.5 邮件发送记录表 ----------
CREATE TABLE IF NOT EXISTS email_outbox (
    id              BIGSERIAL    PRIMARY KEY,
    to_email        VARCHAR(128) NOT NULL,             -- 统一小写
    template        VARCHAR(32)  NOT NULL,             -- verify_code_register/verify_code_reset/
                                                        -- verify_code_migrate/login_alert
    status          SMALLINT     NOT NULL DEFAULT 0,   -- 0-排队 1-已发送 2-失败
    provider_msg_id VARCHAR(128),                      -- Mailpit/DirectMail message-id
    error           VARCHAR(512),
    retry_count     SMALLINT     NOT NULL DEFAULT 0,   -- 异步邮件最多重试 3 次
    created_at      TIMESTAMP    NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_email_to_time     ON email_outbox (to_email, created_at);
CREATE INDEX IF NOT EXISTS idx_email_status_time ON email_outbox (status, created_at);

COMMENT ON TABLE  email_outbox           IS '邮件发送留痕（验证码类工单排查依据）';
COMMENT ON COLUMN email_outbox.template   IS 'verify_code_register / verify_code_reset / verify_code_migrate / login_alert';
COMMENT ON COLUMN email_outbox.status     IS '0-排队 1-已发送 2-失败';

-- ---------- 6.6 RT 注册表（阶段 M · Admin_Console_Design.md §2.2） ----------
-- 管理台会话管理屏的查询索引：Redis rt:{jti} 无法支撑分页/按用户搜索/按应用吊销。
-- 运行时鉴权（吊销判定、宽限期、黑名单）仍以 Redis 为权威；写表失败仅记日志不阻断主链路。
CREATE TABLE IF NOT EXISTS oauth_refresh_tokens (
    jti         VARCHAR(64)  PRIMARY KEY,
    user_id     VARCHAR(32)  NOT NULL,
    client_id   VARCHAR(64)  NOT NULL,
    grant_id    VARCHAR(64),
    ip          VARCHAR(45),
    user_agent  VARCHAR(512),
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT now(),
    expires_at  TIMESTAMPTZ  NOT NULL,
    revoked_at  TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_rt_user    ON oauth_refresh_tokens (user_id, revoked_at);
CREATE INDEX IF NOT EXISTS idx_rt_client  ON oauth_refresh_tokens (client_id, revoked_at);
CREATE INDEX IF NOT EXISTS idx_rt_expires ON oauth_refresh_tokens (expires_at);

COMMENT ON TABLE  oauth_refresh_tokens             IS 'RT 注册表：管理台查询索引（运行时鉴权以 Redis rt:{jti} 为权威）';
COMMENT ON COLUMN oauth_refresh_tokens.jti         IS 'RT 的 jti（与 Redis rt:{jti} 同键，轮转即新行）';
COMMENT ON COLUMN oauth_refresh_tokens.user_id     IS '签发对象（users.user_id）';
COMMENT ON COLUMN oauth_refresh_tokens.grant_id    IS '授权会话（同 grant 的轮转行同源，级联吊销用）';
COMMENT ON COLUMN oauth_refresh_tokens.ip          IS '签发请求来源 IP（ALS 请求上下文注入）';
COMMENT ON COLUMN oauth_refresh_tokens.user_agent  IS '签发请求 User-Agent（ALS 请求上下文注入）';
COMMENT ON COLUMN oauth_refresh_tokens.expires_at  IS 'RT 过期时间（与 Redis rt:{jti} TTL 对齐，7 天）';
COMMENT ON COLUMN oauth_refresh_tokens.revoked_at   IS '吊销时间（destroy/级联吊销路径回填；自然轮转不回填）';
