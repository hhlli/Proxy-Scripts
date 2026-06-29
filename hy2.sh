#!/bin/bash
#
# Hysteria 2 一键管理脚本
# 功能: 安装/重新配置、更新核心(保留配置)、卸载、重启、查看日志、查看配置、检查更新
#

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

HYSTERIA_BIN="/usr/local/bin/hysteria"
HYSTERIA_CONF="/etc/hysteria/config.yaml"
HYSTERIA_CERT_DIR="/etc/hysteria/certs"
ACME_BIN="$HOME/.acme.sh/acme.sh"

[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 权限运行此脚本!${NC}" && exit 1

# ========================================
# 工具函数
# ========================================

is_installed() {
    [ -f "$HYSTERIA_BIN" ]
}

get_ip() {
    VPS_IP=$(curl -s4 -m 5 api.ipify.org || curl -s4 -m 5 ifconfig.me || echo "获取失败_请手动替换IP")
}

# 本地已安装版本。官方 `hysteria version` 输出的字段是 "Version:"，
# 不是 "App Version"，提取时必须按这个真实格式来匹配。
get_local_version() {
    "$HYSTERIA_BIN" version 2>/dev/null | grep '^Version' | grep -o 'v[0-9.]*' | head -1
}

# GitHub 最新版本。apernet/hysteria 仓库的 tag 形如 "app/v2.9.2"
# (带 "app/" 前缀)，需要去掉前缀才能跟本地版本号对比。
get_latest_version() {
    curl -s --max-time 10 https://api.github.com/repos/apernet/hysteria/releases/latest \
        | grep '"tag_name":' \
        | sed -E 's/.*"tag_name":[[:space:]]*"([^"]+)".*/\1/' \
        | sed 's#^app/##'
}

check_status() {
    if is_installed; then
        if systemctl is-active --quiet hysteria-server; then
            echo -e "Hysteria 2 状态: ${GREEN}运行中${NC}"
        else
            echo -e "Hysteria 2 状态: ${YELLOW}已安装，但未运行${NC}"
        fi
    else
        echo -e "Hysteria 2 状态: ${RED}未安装${NC}"
    fi
}

# 从现有配置文件中解析出 DOMAIN / PORT / PASSWORD，
# 供"查看配置"和"更新(保留配置)"复用，避免重复代码。
load_existing_config() {
    [ -f "$HYSTERIA_CONF" ] || return 1

    PORT=$(grep -E '^listen:' "$HYSTERIA_CONF" | awk -F':' '{print $NF}' | tr -d ' ')
    PASSWORD=$(grep -E '^\s+password:' "$HYSTERIA_CONF" | awk '{print $2}')

    local cert_file
    cert_file=$(grep -E '^\s+cert:' "$HYSTERIA_CONF" | awk '{print $2}')
    if [ -f "$cert_file" ]; then
        DOMAIN=$(openssl x509 -noout -subject -in "$cert_file" 2>/dev/null \
            | grep -oE 'CN\s*=\s*[^,]+' | awk -F'=' '{print $2}' | tr -d ' ' | sed 's/CN=//g')
    fi
    DOMAIN=${DOMAIN:-"你的域名"}
}

# 统一的节点信息展示，安装成功 / 查看配置 / 更新完成都会用到
print_node_info() {
    local title="$1"
    echo -e "${GREEN}=== ${title} ===${NC}"
    echo -e "节点IP:   ${YELLOW}$VPS_IP${NC}"
    echo -e "域名/SNI: ${YELLOW}$DOMAIN${NC}"
    echo -e "监听端口: ${YELLOW}$PORT${NC}"
    echo -e "连接密码: ${YELLOW}$PASSWORD${NC}"
    echo -e "----------------------------------------"
    echo -e "Surge 配置参考:"
    echo -e "${GREEN}Hy2-Node = hysteria2, $VPS_IP, $PORT, password=$PASSWORD, sni=$DOMAIN${NC}"
    echo -e "----------------------------------------"
    echo -e "Loon 配置参考:"
    echo -e "${GREEN}Hy2-Node = Hysteria2, $VPS_IP, $PORT, password=$PASSWORD, sni=$DOMAIN${NC}"
}

view_config() {
    if [ ! -f "$HYSTERIA_CONF" ]; then
        echo -e "${RED}配置文件不存在，请先安装!${NC}"
        return
    fi

    get_ip
    load_existing_config
    print_node_info "当前 Hysteria 2 配置"
}

# ========================================
# 安装 / 重新配置 (会改动域名、端口、密码并重新申请证书)
# ========================================

install_hy2() {
    if is_installed; then
        echo -e "${YELLOW}检测到 Hysteria 2 已安装。${NC}"
        echo -e "${YELLOW}继续将重新设置域名/端口/密码，并重新申请证书 (旧配置会被覆盖)。${NC}"
        echo -e "${CYAN}如果只是想更新核心程序版本、保留现有配置，请使用菜单 [2]。${NC}"
        read -p "确认要重新安装并覆盖现有配置吗? (y/N): " CONFIRM
        if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
            echo -e "${CYAN}已取消。${NC}"
            return
        fi
    fi

    read -p "设置域名: " DOMAIN
    if [ -z "$DOMAIN" ]; then
        echo -e "${RED}域名不能为空，已取消。${NC}"
        return 1
    fi
    read -p "设置端口 (默认 443): " PORT
    PORT=${PORT:-443}
    read -p "设置连接密码: " PASSWORD
    if [ -z "$PASSWORD" ]; then
        echo -e "${RED}密码不能为空，已取消。${NC}"
        return 1
    fi

    get_ip

    echo -e "${CYAN}开始更新系统依赖...${NC}"
    apt update && apt install -y curl socat openssl

    echo -e "${CYAN}部署 Hysteria 2 核心...${NC}"
    if ! bash <(curl -fsSL https://get.hy2.sh/); then
        echo -e "${RED}错误: Hysteria 2 核心程序安装失败，请检查网络后重试。${NC}"
        return 1
    fi

    if [ ! -f "$ACME_BIN" ]; then
        echo -e "${YELLOW}开始安装 acme.sh...${NC}"
        curl https://get.acme.sh | sh -s email=admin@$DOMAIN
    fi

    "$ACME_BIN" --upgrade --auto-upgrade

    echo -e "${CYAN}开始申请 TLS 证书 (首选 ZeroSSL)...${NC}"
    if ! "$ACME_BIN" --issue -d "$DOMAIN" --standalone --force; then
        echo -e "${YELLOW}ZeroSSL 申请失败，切换至 Let's Encrypt 并重试...${NC}"
        "$ACME_BIN" --set-default-ca --server letsencrypt
        if ! "$ACME_BIN" --issue -d "$DOMAIN" --standalone --force; then
            echo -e "${RED}错误: 证书申请连续失败。请检查域名解析是否生效，以及 80 端口是否被占用或屏蔽。${NC}"
            return 1
        fi
    fi

    mkdir -p "$HYSTERIA_CERT_DIR"
    "$ACME_BIN" --install-cert -d "$DOMAIN" \
        --key-file "$HYSTERIA_CERT_DIR/server.key" \
        --fullchain-file "$HYSTERIA_CERT_DIR/server.crt"

    if [ ! -s "$HYSTERIA_CERT_DIR/server.crt" ]; then
        echo -e "${RED}错误: 证书文件未成功生成。${NC}"
        return 1
    fi

    echo -e "${CYAN}生成配置文件...${NC}"
    cat << EOF > "$HYSTERIA_CONF"
listen: :$PORT

tls:
  cert: $HYSTERIA_CERT_DIR/server.crt
  key: $HYSTERIA_CERT_DIR/server.key

auth:
  type: password
  password: $PASSWORD

masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com
    rewriteHost: true

ignoreClientBandwidth: true
EOF

    # 官方脚本默认以 root 运行，此命令可能报错，添加忽略潜在错误
    chown -R hysteria:hysteria "$HYSTERIA_CERT_DIR" 2>/dev/null || true

    echo -e "${CYAN}启动服务...${NC}"
    systemctl enable --now hysteria-server
    systemctl restart hysteria-server

    print_node_info "Hysteria 2 安装成功"
}

# ========================================
# 更新核心程序 (保留现有域名/端口/密码/证书配置)
# ========================================

update_hy2() {
    if ! is_installed; then
        echo -e "${RED}尚未安装 Hysteria 2，请先选择 [1] 进行安装。${NC}"
        return
    fi

    if [ ! -f "$HYSTERIA_CONF" ]; then
        echo -e "${RED}未找到现有配置文件，无法在保留配置的情况下更新，请使用 [1] 重新安装。${NC}"
        return
    fi

    local local_ver latest_ver
    local_ver=$(get_local_version)
    latest_ver=$(get_latest_version)

    echo -e "当前本地版本: ${YELLOW}${local_ver:-未知}${NC}"
    echo -e "GitHub 最新版本: ${YELLOW}${latest_ver:-获取失败}${NC}"

    if [[ -n "$latest_ver" && "$local_ver" == "$latest_ver" ]]; then
        echo -e "${GREEN}当前已是最新版本。${NC}"
        read -p "仍然要强制重新安装核心程序吗? (y/N): " CONFIRM
        if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
            return
        fi
    fi

    echo -e "${CYAN}正在更新 Hysteria 2 核心程序 (域名/端口/密码/证书保持不变)...${NC}"
    # 官方安装脚本只会覆盖二进制文件本身；当 /etc/hysteria/config.yaml
    # 已存在时，脚本会跳过写入示例配置，因此现有配置不会被改动。
    if ! bash <(curl -fsSL https://get.hy2.sh/); then
        echo -e "${RED}更新失败，请检查网络后重试。${NC}"
        return 1
    fi

    echo -e "${CYAN}重启服务以应用新版本...${NC}"
    systemctl restart hysteria-server

    if systemctl is-active --quiet hysteria-server; then
        local new_ver
        new_ver=$(get_local_version)
        echo -e "${GREEN}更新完成，当前版本: ${new_ver:-未知}${NC}"
        get_ip
        load_existing_config
        print_node_info "更新后仍然有效的节点配置"
    else
        echo -e "${RED}更新后服务未能正常启动，请用菜单 [5] 查看日志排查。${NC}"
    fi
}

# ========================================
# 卸载
# ========================================

uninstall_hy2() {
    read -p "确认卸载 Hysteria 2? (y/N): " CONFIRM
    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}正在清理 Hysteria 2...${NC}"
        systemctl stop hysteria-server 2>/dev/null
        systemctl disable hysteria-server 2>/dev/null
        rm -rf /etc/hysteria
        rm -f "$HYSTERIA_BIN"
        rm -f /etc/systemd/system/hysteria-server.service
        systemctl daemon-reload
        echo -e "${GREEN}卸载完成。${NC}"
    fi
}

# ========================================
# 检查更新 (仅检测，不执行更新动作)
# ========================================

check_update() {
    if ! is_installed; then
        echo -e "${RED}未安装 Hysteria 2。${NC}"
        return
    fi

    local local_ver latest_ver
    local_ver=$(get_local_version)
    latest_ver=$(get_latest_version)

    echo -e "当前本地版本: ${YELLOW}${local_ver:-未知}${NC}"
    echo -e "GitHub 最新版本: ${YELLOW}${latest_ver:-获取失败}${NC}"

    if [[ -z "$latest_ver" ]]; then
        echo -e "${RED}获取最新版本失败，可能是 GitHub API 限流或网络问题，请稍后再试。${NC}"
    elif [[ -z "$local_ver" ]]; then
        echo -e "${YELLOW}无法识别本地版本号，建议直接执行菜单 [2] 更新核心程序。${NC}"
    elif [[ "$local_ver" != "$latest_ver" ]]; then
        echo -e "${YELLOW}发现新版本，可选择菜单 [2] 更新核心程序 (会保留现有配置)。${NC}"
    else
        echo -e "${GREEN}当前已是最新版本。${NC}"
    fi
}

# ========================================
# 主菜单
# ========================================

while true; do
    clear
    echo -e "${GREEN}Hysteria 2 一键管理脚本${NC}"
    check_status
    echo "--------------------------------"
    echo "1. 安装 / 重新配置 (域名、端口、密码)"
    echo "2. 更新核心程序 (保留现有配置)"
    echo "3. 卸载"
    echo "4. 重启服务"
    echo "5. 查看运行状态 (实时日志)"
    echo "6. 查看当前配置"
    echo "7. 检查更新"
    echo "8. 退出"
    read -p "请选择 [1-8]: " opt

    echo -e "\n"
    case $opt in
        1) install_hy2 ;;
        2) update_hy2 ;;
        3) uninstall_hy2 ;;
        4) systemctl restart hysteria-server && echo -e "${GREEN}已重启${NC}" ;;
        5)
           echo -e "${YELLOW}已打开日志分页查看模式，按 'q' 即可退出并返回菜单。${NC}"
           journalctl -u hysteria-server -e
           ;;
        6) view_config ;;
        7) check_update ;;
        8) echo -e "${CYAN}已退出脚本。${NC}"; exit 0 ;;
        *) echo -e "${RED}无效选择。${NC}" ;;
    esac

    echo -e "\n"
    read -n 1 -s -r -p "按任意键返回主菜单..."
done
