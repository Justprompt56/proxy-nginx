#!/usr/bin/env bash
# add-proxy-domain.sh — 一键添加新域名,反代到指定的后端
#
# 流程:
#   1. 输入域名 → 校验格式 / 幂等检查
#   2. 提示设置 DNS A 记录,并做解析预检
#   3. certbot --webroot 申请 Let's Encrypt 证书
#   4. 在托管的 nginx 配置中追加 443 server 块,并把域名加到 80 重定向块
#   5. nginx -t && systemctl reload nginx (失败自动回滚)
#
# 自动续签由 certbot.timer + /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh 负责,
# 本脚本无需额外配置。

set -euo pipefail

# ─── 配置 ─────────────────────────────────────────────────────────────────────
# NGINX_CONF 在 init_nginx_conf 中动态决定 (兼容既有部署 + 新机种子)
readonly DEFAULT_NGINX_CONF="/etc/nginx/conf.d/proxy-managed.conf"
readonly LEGACY_LINK="/etc/nginx/conf.d/proxy-nginx.conf"
NGINX_CONF=""
readonly WEBROOT="/var/www/certbot"

# ─── 输出辅助 ─────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    readonly C_RED=$'\033[31m' C_GRN=$'\033[32m' C_YLW=$'\033[33m'
    readonly C_BLD=$'\033[1m'  C_DIM=$'\033[2m'  C_RST=$'\033[0m'
else
    readonly C_RED="" C_GRN="" C_YLW="" C_BLD="" C_DIM="" C_RST=""
fi

log()   { printf '%s[*]%s %s\n' "$C_BLD" "$C_RST" "$*"; }
ok()    { printf '%s[✓]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn()  { printf '%s[!]%s %s\n' "$C_YLW" "$C_RST" "$*"; }
err()   { printf '%s[✗]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; }
die()   { err "$*"; exit 1; }

# ─── 前置检查 ─────────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "请用 sudo 运行: sudo $0"

# 检测 systemd (脚本依赖 systemctl 管理 nginx)
ensure_systemd() {
    command -v systemctl >/dev/null \
        || die "未检测到 systemctl,本脚本依赖 systemd 管理 nginx 服务"
    [[ -d /run/systemd/system ]] \
        || die "systemd 未在运行(可能在容器或被禁用),无法管理 nginx 服务"
}
ensure_systemd

# 自动探测 nginx 运行用户(用于 webroot 目录归属)
detect_web_user() {
    local u
    for u in www-data nginx http apache; do
        if getent passwd "$u" >/dev/null 2>&1; then
            echo "$u"; return
        fi
    done
    echo ""
}

# RHEL 系上 certbot 通常在 EPEL,需要先启用 EPEL 源
ensure_epel_if_needed() {
    local mgr="$1"
    [[ "$mgr" == "dnf" || "$mgr" == "yum" ]] || return 0
    # 已经能找到 certbot 就不需要 EPEL
    if "$mgr" list available certbot >/dev/null 2>&1; then
        return 0
    fi
    # 已经装过 EPEL 也跳过
    if rpm -q epel-release >/dev/null 2>&1; then
        return 0
    fi
    log "RHEL 系上 certbot 不在默认源,启用 EPEL ..."
    "$mgr" install -y epel-release \
        || warn "EPEL 启用失败,certbot 可能装不上(请手动: $mgr install epel-release)"
}

# 检测包管理器
detect_pkg_mgr() {
    if   command -v apt-get >/dev/null; then echo "apt"
    elif command -v dnf     >/dev/null; then echo "dnf"
    elif command -v yum     >/dev/null; then echo "yum"
    elif command -v zypper  >/dev/null; then echo "zypper"
    elif command -v pacman  >/dev/null; then echo "pacman"
    elif command -v apk     >/dev/null; then echo "apk"
    else echo ""
    fi
}

# 把命令名映射到对应发行版的包名
pkg_for_cmd() {
    local cmd="$1" mgr="$2"
    case "$cmd" in
        dig)
            case "$mgr" in
                apt)              echo "dnsutils" ;;
                dnf|yum|zypper)   echo "bind-utils" ;;
                pacman)           echo "bind" ;;
                apk)              echo "bind-tools" ;;
            esac ;;
        awk)
            case "$mgr" in
                apt|dnf|yum|zypper|pacman) echo "gawk" ;;
                apk)                       echo "gawk" ;;
            esac ;;
        certbot|nginx|curl|sed) echo "$cmd" ;;
    esac
}

pkg_install() {
    local mgr="$1"; shift
    case "$mgr" in
        apt)    DEBIAN_FRONTEND=noninteractive apt-get update -qq \
                 && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" ;;
        dnf)    dnf install -y "$@" ;;
        yum)    yum install -y "$@" ;;
        zypper) zypper --non-interactive install "$@" ;;
        pacman) pacman -Sy --noconfirm "$@" ;;
        apk)    apk add --no-cache "$@" ;;
    esac
}

ensure_dependencies() {
    local required=(certbot nginx dig curl awk sed)
    local missing=() cmd
    for cmd in "${required[@]}"; do
        command -v "$cmd" >/dev/null || missing+=("$cmd")
    done
    [[ ${#missing[@]} -eq 0 ]] && return 0

    local mgr; mgr=$(detect_pkg_mgr)
    [[ -n "$mgr" ]] || die "缺少依赖 (${missing[*]}) 且未识别到包管理器,请手动安装"

    local pkgs=() pkg
    for cmd in "${missing[@]}"; do
        pkg=$(pkg_for_cmd "$cmd" "$mgr")
        [[ -n "$pkg" ]] || die "无法为命令 $cmd 找到对应的包(管理器: $mgr)"
        pkgs+=("$pkg")
    done

    log "检测到缺失依赖: ${missing[*]}"
    # 缺 certbot 时,RHEL 系需要先启用 EPEL
    if [[ " ${missing[*]} " == *" certbot "* ]]; then
        ensure_epel_if_needed "$mgr"
    fi
    log "使用 $mgr 安装: ${pkgs[*]}"
    pkg_install "$mgr" "${pkgs[@]}" || die "依赖安装失败,请手动安装: ${pkgs[*]}"

    for cmd in "${missing[@]}"; do
        command -v "$cmd" >/dev/null || die "安装后仍找不到命令: $cmd"
    done
    ok "依赖已就绪"
}

ensure_dependencies

# 确保 nginx 服务正在运行(否则后续 reload 会失败,certbot --webroot 也无法被外部访问)
ensure_nginx_running() {
    if systemctl is-active --quiet nginx; then
        return 0
    fi
    warn "nginx 服务未运行,正在启动 ..."
    systemctl enable --now nginx 2>/dev/null || systemctl start nginx \
        || die "无法启动 nginx,请手动排查: systemctl status nginx"
    systemctl is-active --quiet nginx || die "nginx 启动后仍未处于 active 状态"
    ok "nginx 已启动"
}

ensure_nginx_running

# 启动前自检既有 nginx 配置(把锅留给真正的问题)
log "运行 nginx -t 自检 ..."
if ! nginx -t 2>/tmp/nginx-test.$$.log; then
    cat /tmp/nginx-test.$$.log >&2
    rm -f /tmp/nginx-test.$$.log
    die "nginx 现有配置就有问题,请先修复后再运行本脚本"
fi
rm -f /tmp/nginx-test.$$.log
ok "nginx 现有配置正常"

# 确定 NGINX_CONF: 优先沿用既有部署,否则在 /etc/nginx/conf.d/ 写入种子文件
init_nginx_conf() {
    # 1) 既有合法 symlink → 沿用其目标
    if [[ -L "$LEGACY_LINK" ]]; then
        local legacy
        legacy=$(readlink -f "$LEGACY_LINK" 2>/dev/null || true)
        if [[ -n "$legacy" && -f "$legacy" ]]; then
            NGINX_CONF="$legacy"
            log "沿用既有配置: $NGINX_CONF"
            return
        fi
    fi
    # 2) 既有普通文件
    if [[ -f "$LEGACY_LINK" && ! -L "$LEGACY_LINK" ]]; then
        NGINX_CONF="$LEGACY_LINK"
        log "沿用既有配置: $NGINX_CONF"
        return
    fi
    # 3) 默认托管路径已存在
    if [[ -f "$DEFAULT_NGINX_CONF" ]]; then
        NGINX_CONF="$DEFAULT_NGINX_CONF"
        log "沿用既有配置: $NGINX_CONF"
        return
    fi
    # 4) 全新机器: 写入种子配置
    NGINX_CONF="$DEFAULT_NGINX_CONF"
    log "首次运行,创建种子配置: $NGINX_CONF"
    cat > "$NGINX_CONF" <<'NGINX_SEED'
# Auto-managed by add-proxy-domain.sh — new domains will be appended below.
# Safe to edit by hand, but keep the map block and the :80 redirect server.

map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

# ---------------------------------------------------------------- HTTP -> HTTPS
server {
    listen 80;
    listen [::]:80;
    server_name _;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
        default_type "text/plain";
    }

    location / {
        return 308 https://$host$request_uri;
    }
}
NGINX_SEED

    if ! nginx -t 2>/tmp/nginx-test.$$.log; then
        cat /tmp/nginx-test.$$.log >&2
        rm -f /tmp/nginx-test.$$.log "$NGINX_CONF"
        die "种子配置导致 nginx 校验失败,已删除"
    fi
    rm -f /tmp/nginx-test.$$.log
    systemctl reload nginx || { rm -f "$NGINX_CONF"; die "种子配置写入后 nginx reload 失败"; }
    ok "种子配置就绪"
}

init_nginx_conf

# 确保所有监听 80 端口的 server 块都能响应 /.well-known/acme-challenge/
# (避免新域名因落到 default_server 而拿不到验证文件)
inject_acme_into_80_servers() {
    local file="$1" tmp="${1}.tmp.$$"
    awk '
    BEGIN { in_srv = 0; depth = 0; buf_n = 0; has_80 = 0; has_acme = 0 }
    function flush_srv(   i, injected) {
        if (has_80 && !has_acme && buf_n > 1) {
            injected = 0
            for (i = 1; i <= buf_n; i++) {
                print buf[i]
                if (!injected && index(buf[i], "{") > 0) {
                    print "    # ACME HTTP-01 (auto-added by add-proxy-domain.sh)"
                    print "    location /.well-known/acme-challenge/ { root /var/www/certbot; default_type \"text/plain\"; }"
                    injected = 1
                }
            }
            changed = 1
        } else {
            for (i = 1; i <= buf_n; i++) print buf[i]
        }
        in_srv = 0; depth = 0; buf_n = 0; has_80 = 0; has_acme = 0
    }
    {
        nocomm = $0
        sub(/#.*$/, "", nocomm)
        opens  = gsub(/\{/, "&", nocomm)
        closes = gsub(/\}/, "&", nocomm)
    }
    !in_srv && /^[ \t]*server[ \t]*\{/ {
        in_srv = 1; depth = opens - closes
        buf_n = 1; buf[1] = $0
        if (match($0, /listen[ \t]+([0-9.]+:|\[[^]]+\]:)?80([ \t;]|$)/)) has_80 = 1
        if (index($0, "acme-challenge")) has_acme = 1
        if (depth <= 0) flush_srv()
        next
    }
    in_srv {
        depth += opens - closes
        buf_n++; buf[buf_n] = $0
        if (match($0, /listen[ \t]+([0-9.]+:|\[[^]]+\]:)?80([ \t;]|$)/)) has_80 = 1
        if (index($0, "acme-challenge")) has_acme = 1
        if (depth <= 0) flush_srv()
        next
    }
    { print }
    END   { if (in_srv) flush_srv() }
    END   { exit (changed ? 0 : 99) }
    ' "$file" > "$tmp"
    local rc=$?
    if [[ $rc -eq 0 ]]; then
        mv "$tmp" "$file"; return 0
    elif [[ $rc -eq 99 ]]; then
        rm -f "$tmp"; return 1   # 没有改动
    else
        rm -f "$tmp"; return 2   # awk 出错
    fi
}

ensure_acme_endpoint() {
    mkdir -p "$WEBROOT"
    local web_user; web_user=$(detect_web_user)
    if [[ -n "$web_user" ]]; then
        chown -R "${web_user}:${web_user}" "$WEBROOT" 2>/dev/null || true
    fi

    # 收集候选 nginx 配置文件
    local -a candidates=()
    local pattern f real
    for pattern in /etc/nginx/sites-enabled/* /etc/nginx/conf.d/*.conf "$NGINX_CONF"; do
        for f in $pattern; do
            [[ -e "$f" ]] || continue
            real=$(readlink -f "$f")
            candidates+=("$real")
        done
    done

    # 去重
    local -a files=()
    if [[ ${#candidates[@]} -gt 0 ]]; then
        mapfile -t files < <(printf '%s\n' "${candidates[@]}" | sort -u)
    fi

    local -a modified=()  # 元素格式: "file|backup"
    local file backup ts
    ts=$(date +%Y%m%d-%H%M%S)
    for file in "${files[@]}"; do
        # 必须能写
        [[ -w "$file" ]] || continue
        # 没有 :80 监听就跳过
        grep -Eq 'listen[[:space:]]+([0-9.]+:|\[[^]]+\]:)?80([[:space:]]|;|$)' "$file" || continue
        # 已经处理过 ACME 就跳过
        grep -q 'acme-challenge' "$file" && continue

        backup="${file}.bak.${ts}"
        cp -p "$file" "$backup"
        if inject_acme_into_80_servers "$file"; then
            modified+=("${file}|${backup}")
            ok "已为 $file 注入 ACME location (备份: $backup)"
        else
            rm -f "$backup"
        fi
    done

    [[ ${#modified[@]} -eq 0 ]] && return 0

    # 校验 + reload,失败则全部回滚
    if ! nginx -t 2>/tmp/nginx-test.$$.log; then
        cat /tmp/nginx-test.$$.log >&2
        rm -f /tmp/nginx-test.$$.log
        warn "nginx -t 失败,回滚 ACME 注入"
        local entry
        for entry in "${modified[@]}"; do
            cp -p "${entry##*|}" "${entry%%|*}"
        done
        die "ACME location 注入后 nginx 校验失败,已回滚"
    fi
    rm -f /tmp/nginx-test.$$.log
    systemctl reload nginx || die "nginx reload 失败"
    ok "已重载 nginx,ACME endpoint 就绪"
}

ensure_acme_endpoint

# 自动续签兜底: certbot.timer + deploy hook
ensure_auto_renewal() {
    # 1) certbot.timer: 多数发行版包默认启用,这里只做兜底
    if systemctl list-unit-files certbot.timer >/dev/null 2>&1; then
        if ! systemctl is-enabled --quiet certbot.timer 2>/dev/null; then
            systemctl enable --now certbot.timer 2>/dev/null \
                && ok "已启用 certbot.timer (每日续签)"
        fi
    fi
    # 2) deploy hook: 续签后自动 reload nginx
    local hook=/etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
    if [[ -x "$hook" ]]; then
        return 0
    fi
    mkdir -p "$(dirname "$hook")"
    cat > "$hook" <<'HOOK'
#!/bin/sh
# Auto-created by add-proxy-domain.sh
systemctl reload nginx
HOOK
    chmod +x "$hook"
    ok "已创建续签 deploy hook: $hook"
}

ensure_auto_renewal

# ─── 工具函数 ─────────────────────────────────────────────────────────────────
ask() {
    # ask "提示" [默认值]
    local prompt="$1" default="${2-}" reply
    if [[ -n "$default" ]]; then
        read -rp "$prompt [$default] " reply
        echo "${reply:-$default}"
    else
        read -rp "$prompt " reply
        echo "$reply"
    fi
}

confirm() {
    local reply
    read -rp "$1 [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]]
}

is_valid_domain() {
    [[ "$1" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}$ ]]
}

is_valid_email() {
    [[ "$1" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]
}

detect_public_ip() {
    local ip
    ip=$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null) && { echo "$ip"; return; }
    ip=$(curl -fsS --max-time 5 https://ifconfig.me 2>/dev/null)   && { echo "$ip"; return; }
    echo ""
}

# ─── 主流程 ───────────────────────────────────────────────────────────────────
printf '\n%s== Nginx 反代域名一键添加 ==%s\n\n' "$C_BLD" "$C_RST"

# 1) 域名输入 ────────────────────────────────────────────────────────────────
DOMAIN=$(ask "请输入对外访问的新域名:")
DOMAIN="${DOMAIN,,}"; DOMAIN="${DOMAIN// /}"
[[ -n "$DOMAIN" ]]      || die "域名不能为空"
is_valid_domain "$DOMAIN" || die "域名格式不合法: $DOMAIN"

if awk -v d="$DOMAIN" '
    /^[ \t]*server_name[ \t]/ {
        line = $0
        sub(/^[ \t]*server_name[ \t]+/, "", line)
        sub(/;.*$/, "", line)
        n = split(line, names, /[ \t]+/)
        for (i = 1; i <= n; i++) if (names[i] == d) { print "hit"; exit }
    }
' "$NGINX_CONF" | grep -q hit; then
    die "$DOMAIN 已存在于 $NGINX_CONF 的 server_name 中,请先手动清理后再重试"
fi

# 1b) 后端域名输入 ───────────────────────────────────────────────────────────
BACKEND=$(ask "请输入后端域名:")
BACKEND="${BACKEND,,}"; BACKEND="${BACKEND// /}"
BACKEND="${BACKEND#http://}"; BACKEND="${BACKEND#https://}"; BACKEND="${BACKEND%%/*}"
[[ -n "$BACKEND" ]]       || die "后端域名不能为空"
is_valid_domain "$BACKEND" || die "后端域名格式不合法: $BACKEND"
[[ "$BACKEND" == "$DOMAIN" ]] && die "后端域名不能与对外域名相同 ($DOMAIN)"
ok "后端: https://$BACKEND"

# 1c) Let's Encrypt 邮箱(用于证书过期提醒和账号注册) ─────────────────────────
ACME_EMAIL=$(ask "请输入用于 Let's Encrypt 的邮箱 (用于过期提醒):")
ACME_EMAIL="${ACME_EMAIL// /}"
[[ -n "$ACME_EMAIL" ]]       || die "邮箱不能为空"
is_valid_email "$ACME_EMAIL" || die "邮箱格式不合法: $ACME_EMAIL"

# 2) DNS 提示 + 预检 ─────────────────────────────────────────────────────────
SERVER_IP=$(detect_public_ip)
echo
warn "请先到 DNS 服务商为该域名添加 A 记录:"
if [[ -n "$SERVER_IP" ]]; then
    printf '       %s%s%s  →  %s%s%s\n' "$C_BLD" "$DOMAIN" "$C_RST" "$C_BLD" "$SERVER_IP" "$C_RST"
else
    printf '       %s%s%s  →  %s<本机公网 IP>%s  (自动探测失败,请手动确认)\n' \
        "$C_BLD" "$DOMAIN" "$C_RST" "$C_BLD" "$C_RST"
fi
printf '       验证命令: %sdig +short %s%s\n\n' "$C_DIM" "$DOMAIN" "$C_RST"
confirm "DNS 已生效,继续?" || die "已取消"

log "解析 $DOMAIN ..."
RESOLVED=$(dig +short A "$DOMAIN" @1.1.1.1 | tail -n1 || true)
if [[ -z "$RESOLVED" ]]; then
    warn "解析不到 A 记录(DNS 可能尚未传播)"
    confirm "仍然继续(ACME 验证可能失败)?" || die "已取消"
elif [[ -n "$SERVER_IP" && "$RESOLVED" != "$SERVER_IP" ]]; then
    warn "$DOMAIN 解析为 $RESOLVED,与本机 $SERVER_IP 不一致"
    confirm "仍然继续?" || die "已取消"
else
    ok "DNS 解析: $DOMAIN → $RESOLVED"
fi

# 3) 签发证书 ────────────────────────────────────────────────────────────────
echo
log "申请 Let's Encrypt 证书 ..."
certbot certonly --webroot -w "$WEBROOT" -d "$DOMAIN" \
    --non-interactive --agree-tos --no-eff-email -m "$ACME_EMAIL" \
    || die "certbot 签发失败,请检查 DNS / 80 端口可达性"
ok "证书已签发: /etc/letsencrypt/live/$DOMAIN/"

# 4) 写入 nginx 配置(原子化,失败回滚) ─────────────────────────────────────
echo
log "更新 nginx 配置 ..."
BACKUP="${NGINX_CONF}.bak.$(date +%Y%m%d-%H%M%S)"
cp -p "$NGINX_CONF" "$BACKUP"

restore() {
    warn "回滚配置 ..."
    cp -p "$BACKUP" "$NGINX_CONF"
}

# 4a) 把域名插入第一个 server_name 行(80 端口 HTTP→HTTPS 重定向块)
awk -v d="$DOMAIN" '
    !done && /^[[:space:]]*server_name[[:space:]]/ {
        sub(/;[[:space:]]*$/, " " d ";")
        done = 1
    }
    { print }
' "$NGINX_CONF" > "${NGINX_CONF}.tmp" \
    && mv "${NGINX_CONF}.tmp" "$NGINX_CONF" \
    || { restore; die "更新 80 端口 server_name 失败"; }

# 4b) 追加 443 server 块。用 quoted heredoc 避免 nginx 变量被 shell 展开,
#     再用 sed 注入两个 shell 变量。
cat >> "$NGINX_CONF" <<'NGINX_BLOCK'

# ---------------------------------------------------------------- __DOMAIN__
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name __DOMAIN__;

    ssl_certificate     /etc/letsencrypt/live/__DOMAIN__/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/__DOMAIN__/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;

    client_max_body_size 100m;

    location / {
        proxy_pass https://__BACKEND__;
        proxy_http_version 1.1;
        proxy_ssl_server_name on;
        proxy_ssl_name __BACKEND__;
        proxy_set_header Host __BACKEND__;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $host;

        # WebSocket upgrade
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;

        proxy_connect_timeout 30s;
        proxy_send_timeout    300s;
        proxy_read_timeout    300s;
        proxy_buffering off;
    }
}
NGINX_BLOCK

# 仅替换我们刚追加的那块里的占位符
sed -i \
    -e "s|__DOMAIN__|$DOMAIN|g" \
    -e "s|__BACKEND__|$BACKEND|g" \
    "$NGINX_CONF" \
    || { restore; die "占位符替换失败"; }

# 5) 校验 + reload ──────────────────────────────────────────────────────────
log "nginx -t 校验 ..."
if ! nginx -t 2> /tmp/nginx-test.$$.log; then
    cat /tmp/nginx-test.$$.log >&2
    rm -f /tmp/nginx-test.$$.log
    restore
    die "nginx 配置校验失败,已回滚到 $BACKUP"
fi
rm -f /tmp/nginx-test.$$.log

systemctl reload nginx || { restore; die "nginx reload 失败,已回滚"; }
ok "nginx 已 reload"

# 6) 完成 ────────────────────────────────────────────────────────────────────
cat <<EOF

${C_GRN}╔══════════════════════════════════════════════════════════╗
║  ✅  $DOMAIN
╠══════════════════════════════════════════════════════════╣
║  HTTPS  : https://$DOMAIN
║  后端   : https://$BACKEND
║  证书   : /etc/letsencrypt/live/$DOMAIN/
║  续签   : certbot.timer + deploy hook(无需手动维护)
║  备份   : $BACKUP
╚══════════════════════════════════════════════════════════╝${C_RST}

测试命令:
  curl -v https://$DOMAIN/

EOF
