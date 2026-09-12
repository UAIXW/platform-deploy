# ============================================================================
# 共享路由（443 与 8443 两个 server 块 include 本文件）
# ============================================================================

# ---- SSO 认证中心: /sso/xxx → auth-center /xxx（无全局前缀）----
location /sso/ {
    proxy_pass http://sso_auth/;
    proxy_http_version 1.1;
    proxy_set_header Connection "";
    # $http_host 保留端口——oidc-provider v9 discovery 按请求 Host 推导，
    # 须与 ISSUER 环境变量严格一致（本地 D1 同款结论）
    proxy_set_header Host $http_host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    client_max_body_size 2m;
    proxy_connect_timeout 3s;
    proxy_read_timeout 30s;
}

# ---- synapse 后端: /api/synapse/xxx → 后端 /api/xxx（内部前缀即 /api）----
location /api/synapse/ {
    proxy_pass http://synapse_api/api/;
    proxy_http_version 1.1;
    proxy_set_header Connection "";
    proxy_set_header Host $http_host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    # 后端 body parser 上限 50mb（LLM 对话历史等），nginx 同步放宽
    client_max_body_size 50m;
    proxy_connect_timeout 5s;
    # LLM 代理与 SSE（scan-events）响应耗时较长，且 SSE 需关闭缓冲
    proxy_read_timeout 300s;
    proxy_buffering off;
}

# ---- skillhub 前端: 纯静态 SPA（路由 fallback 到 index.html）----
# 前端构建注意: 备案期入口是 IP:8443 + 路径分发，需
#   VITE_API_BASE_URL=/api/synapse 构建后才与本路由对齐；
# 域名就绪拆子域后改回 VITE_API_BASE_URL=/api（nginx 直转）
location / {
    root /usr/share/nginx/html;
    index index.html;
    try_files $uri $uri/ /index.html;

    # 带指纹的静态资源长缓存
    location ~* \.(js|css|png|jpg|jpeg|svg|ico|woff2?)$ {
        root /usr/share/nginx/html;
        expires 30d;
        add_header Cache-Control "public, immutable";
    }
}
