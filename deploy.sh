#!/bin/bash
# ============================================================
# AIVISE 一键部署脚本
# 环境要求: Ubuntu 22.04/24.04 LTS
# 功能: 安装 Caddy、部署站点、自动申请 HTTPS 证书
# 用法: chmod +x deploy.sh && sudo ./deploy.sh
# ============================================================

set -euo pipefail

# ==================== 配置区 ====================
# 请根据实际情况修改以下变量

DOMAIN="aivise.com"              # 你的域名（替换为实际域名）
SITE_DIR="/var/www/aihot"        # 站点根目录
INDEX_FILE="index.html"          # 入口文件
ADMIN_EMAIL="admin@aivise.com"   # SSL 证书管理邮箱（替换为实际邮箱）

# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ---------- 前置检查 ----------
check_prerequisites() {
    echo ""
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}  AIVISE 一键部署${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo ""

    # 检查 root 权限
    if [ "$(id -u)" -ne 0 ]; then
        err "请使用 sudo 运行: sudo $0"
    fi

    # 检查系统
    if ! command -v apt &> /dev/null; then
        err "本脚本仅支持 Ubuntu/Debian 系统"
    fi
    log "系统检查通过"

    # 检查域名是否设置
    if [ "$DOMAIN" = "aivise.com" ]; then
        warn "请编辑脚本第 16 行，将 DOMAIN 改为你自己的域名"
        warn "当前值: $DOMAIN"
        read -rp "是否继续使用当前域名? [y/N]: " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            err "部署中止，请修改配置后重试"
        fi
    fi

    # 检查邮箱是否设置
    if [ "$ADMIN_EMAIL" = "admin@aivise.com" ]; then
        warn "请编辑脚本第 18 行，将 ADMIN_EMAIL 改为你的邮箱（用于 SSL 证书管理）"
        read -rp "请输入你的邮箱地址: " ADMIN_EMAIL
    fi

    log "域名: $DOMAIN"
    log "邮箱: $ADMIN_EMAIL"
    echo ""
}

# ---------- 系统更新 ----------
update_system() {
    log "更新系统软件包..."
    apt update -y
    apt upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
    log "系统更新完成"
}

# ---------- 安装 Caddy ----------
install_caddy() {
    if command -v caddy &> /dev/null; then
        log "Caddy 已安装: $(caddy version --short)"
        return
    fi

    log "安装 Caddy..."

    # 安装依赖
    apt install -y debian-keyring debian-archive-keyring apt-transport-https curl

    # 添加 Caddy 仓库
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /etc/apt/trusted.gpg.d/caddy.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list

    apt update
    apt install -y caddy

    log "Caddy 安装完成: $(caddy version --short)"
}

# ---------- 创建站点目录 ----------
setup_site() {
    log "创建站点目录..."
    mkdir -p "$SITE_DIR"

    # 检查是否有 index.html
    if [ ! -f "$SITE_DIR/$INDEX_FILE" ]; then
        warn "未在 $SITE_DIR 找到 $INDEX_FILE"
        warn "请将 index.html 上传到 $SITE_DIR 目录"
        echo ""
        echo "  上传命令（在本机执行）:"
        echo "  scp index.html user@服务器IP:$SITE_DIR/"
        echo ""
        read -rp "是否先手动上传文件? (y=确认已上传, n=中止): " uploaded
        if [[ ! "$uploaded" =~ ^[Yy]$ ]]; then
            err "部署中止，请先上传 index.html"
        fi
    fi

    # 验证文件存在
    if [ ! -f "$SITE_DIR/$INDEX_FILE" ]; then
        err "文件 $SITE_DIR/$INDEX_FILE 不存在"
    fi

    # 设置权限
    chown -R caddy:caddy "$SITE_DIR"
    chmod -R 755 "$SITE_DIR"

    log "站点目录就绪: $SITE_DIR"
}

# ---------- 配置 Caddy ----------
configure_caddy() {
    log "配置 Caddy..."

    # 备份旧配置
    if [ -f /etc/caddy/Caddyfile ]; then
        cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.backup.$(date +%Y%m%d%H%M%S)"
        log "旧配置已备份"
    fi

    # 写入新配置
    cat > /etc/caddy/Caddyfile << 'CADDYEOF'
# AIVISE - AI 精选
# 主域名
__DOMAIN__ {
    root * __SITE_DIR__
    file_server browse
    encode gzip

    # ---- AIHOT API 反向代理（解决 CORS 问题）----
    # 前端请求 /api-proxy/* → Caddy 转发 → AIHOT 公开 API
    # 浏览器看到的是同域请求，完全绕过 CORS 限制
    handle_path /api-proxy/* {
        uri strip_prefix /api-proxy
        reverse_proxy https://aihot.virxact.com {
            transport http {
                tls_insecure_skip_verify
            }
            header_up Host aihot.virxact.com
            header_up User-Agent "AIVISE/1.0 (AI News Aggregator)"
        }
    }

    # 全局 headers
    header {
        X-Frame-Options "SAMEORIGIN"
        X-Content-Type-Options "nosniff"
        X-XSS-Protection "1; mode=block"
        Referrer-Policy "strict-origin-when-cross-origin"
        Permissions-Policy "camera=(), microphone=(), geolocation=()"
    }

    # 强制 HTTPS（Caddy 自动处理）
    # 缓存静态资源
    @static file {
        path *.html *.css *.js *.png *.jpg *.jpeg *.gif *.svg *.ico *.woff *.woff2 *.ttf
    }
    header @static Cache-Control "public, max-age=86400"

    # SSL 邮箱
    tls __ADMIN_EMAIL__
}

# www 重定向到主域名
www.__DOMAIN__ {
    redir https://__DOMAIN__{uri} permanent
}
CADDYEOF

    # 替换占位符为实际值
    sed -i "s|__DOMAIN__|$DOMAIN|g" /etc/caddy/Caddyfile
    sed -i "s|__SITE_DIR__|$SITE_DIR|g" /etc/caddy/Caddyfile
    sed -i "s|__ADMIN_EMAIL__|$ADMIN_EMAIL|g" /etc/caddy/Caddyfile

    # 测试配置
    if ! caddy validate --config /etc/caddy/Caddyfile; then
        err "Caddy 配置验证失败"
    fi

    log "Caddy 配置完成"
}

# ---------- 启动服务 ----------
start_service() {
    log "启动 Caddy 服务..."
    systemctl enable caddy
    systemctl restart caddy

    # 等待启动
    sleep 2

    if systemctl is-active --quiet caddy; then
        log "Caddy 服务运行中"
    else
        err "Caddy 启动失败，请检查: journalctl -u caddy --no-pager -n 30"
    fi
}

# ---------- 防火墙 ----------
setup_firewall() {
    if command -v ufw &> /dev/null; then
        log "配置防火墙..."
        ufw allow 'Caddy' 2>/dev/null || {
            ufw allow 80/tcp
            ufw allow 443/tcp
        }
        log "防火墙配置完成 (80, 443 已放行)"
    else
        warn "未检测到 UFW，请手动确保 80 和 443 端口已开放"
        warn "云服务器用户请检查安全组规则"
    fi
}

# ---------- 验证部署 ----------
verify_deploy() {
    echo ""
    log "验证部署..."
    sleep 3

    # 检查 HTTP
    if command -v curl &> /dev/null; then
        HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://$DOMAIN" 2>/dev/null || echo "000")
        if [ "$HTTP_STATUS" = "200" ]; then
            log "HTTP 访问正常 (状态码: $HTTP_STATUS)"
        else
            warn "HTTP 返回状态码: $HTTP_STATUS（DNS 可能尚未生效）"
        fi
    fi

    # 检查 SSL
    sleep 5
    if command -v curl &> /dev/null; then
        HTTPS_STATUS=$(curl -sk -o /dev/null -w "%{http_code}" "https://$DOMAIN" 2>/dev/null || echo "000")
        if [ "$HTTPS_STATUS" = "200" ]; then
            log "HTTPS 访问正常，SSL 证书已生效"
        else
            warn "HTTPS 状态码: $HTTPS_STATUS（SSL 证书可能需要几分钟生成）"
        fi
    fi
}

# ---------- 打印结果 ----------
print_summary() {
    echo ""
    echo -e "${CYAN}========================================${NC}"
    echo -e "${GREEN}  部署完成!${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo ""
    echo -e "  站点地址:  ${GREEN}https://$DOMAIN${NC}"
    echo -e "  备用地址:  ${GREEN}http://$DOMAIN${NC}"
    echo -e "  站点目录:  $SITE_DIR"
    echo -e "  Caddy 配置: /etc/caddy/Caddyfile"
    echo ""
    echo "  --- 常用管理命令 ---"
    echo "  查看日志:   journalctl -u caddy -f --no-pager"
    echo "  重载配置:   sudo caddy reload"
    echo "  重启服务:   sudo systemctl restart caddy"
    echo "  更新站点:   直接替换 $SITE_DIR/index.html"
    echo ""
    echo "  --- 阿里云 DNS 检查 ---"
    echo "  确保已在阿里云 DNS 控制台添加 A 记录:"
    echo "  主机记录: @   记录值: $(curl -s ifconfig.me 2>/dev/null || echo '你的服务器IP')"
    echo "  主机记录: www  记录值: $(curl -s ifconfig.me 2>/dev/null || echo '你的服务器IP')"
    echo ""
}

# ==================== 主流程 ====================
main() {
    check_prerequisites
    update_system
    install_caddy
    setup_site
    configure_caddy
    start_service
    setup_firewall
    verify_deploy
    print_summary
}

main "$@"
