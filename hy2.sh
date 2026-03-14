#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 权限运行此脚本!${NC}" && exit 1

get_ip() {
    VPS_IP=$(curl -s4 -m 5 api.ipify.org || curl -s4 -m 5 ifconfig.me || echo "获取失败_请手动替换IP")
}

check_status() {
    if [ -f "/usr/local/bin/hysteria" ]; then
        if systemctl is-active --quiet hysteria-server; then
            echo -e "Hysteria 2 状态: ${GREEN}运行中${NC}"
        else
            echo -e "Hysteria 2 状态: ${YELLOW}已安装，但未运行${NC}"
        fi
    else
        echo -e "Hysteria 2 状态: ${RED}未安装${NC}"
    fi
}

view_config() {
    CONF="/etc/hysteria/config.yaml"
    if [ ! -f "$CONF" ]; then
        echo -e "${RED}配置文件不存在，请先安装!${NC}"
        return
    fi
    
    get_ip
    
    # 提取端口
    PORT=$(grep -E '^listen:' $CONF | awk -F':' '{print $NF}' | tr -d ' ')
    # 提取密码
    PASSWORD=$(grep -E '^\s+password:' $CONF | awk '{print $2}')
    
    # 从证书提取域名
    CERT_FILE=$(grep -E '^\s+cert:' $CONF | awk '{print $2}')
    if [ -f "$CERT_FILE" ]; then
        DOMAIN=$(openssl x509 -noout -subject -in "$CERT_FILE" 2>/dev/null | grep -oE 'CN\s*=\s*[^,]+' | awk -F'=' '{print $2}' | tr -d ' ' | sed 's/CN=//g')
    fi
    DOMAIN=${DOMAIN:-"你的域名"}

    echo -e "${GREEN}=== 当前 Hysteria 2 配置 ===${NC}"
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

install_hy2() {
    read -p "设置域名: " DOMAIN
    read -p "设置端口 (默认 443): " PORT
    PORT=${PORT:-443}
    read -p "设置连接密码: " PASSWORD
    
    get_ip

    echo -e "${CYAN}开始更新系统依赖...${NC}"
    apt update && apt install -y curl socat openssl
    
    echo -e "${CYAN}部署 Hysteria 2 核心...${NC}"
    bash <(curl -fsSL https://get.hy2.sh/)
    
    if [ ! -f "$HOME/.acme.sh/acme.sh" ]; then
        echo -e "${YELLOW}开始安装 acme.sh...${NC}"
        curl https://get.acme.sh | sh -s email=admin@$DOMAIN
    fi
    
    source ~/.bashrc
    ~/.acme.sh/acme.sh --upgrade --auto-upgrade
    echo -e "${CYAN}开始申请 TLS 证书...${NC}"
    ~/.acme.sh/acme.sh --issue -d $DOMAIN --standalone --force

    mkdir -p /etc/hysteria/certs
    ~/.acme.sh/acme.sh --install-cert -d $DOMAIN \
        --key-file /etc/hysteria/certs/server.key \
        --fullchain-file /etc/hysteria/certs/server.crt

    echo -e "${CYAN}生成配置文件...${NC}"
    cat << EOF > /etc/hysteria/config.yaml
listen: :$PORT

tls:
  cert: /etc/hysteria/certs/server.crt
  key: /etc/hysteria/certs/server.key

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

    chown -R hysteria:hysteria /etc/hysteria/certs
    
    echo -e "${CYAN}启动服务...${NC}"
    systemctl enable --now hysteria-server
    systemctl restart hysteria-server
    
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}Hysteria 2 安装成功!${NC}"
    echo -e "节点IP:   ${YELLOW}$VPS_IP${NC}"
    echo -e "域名/SNI: ${YELLOW}$DOMAIN${NC}"
    echo -e "端口:     ${YELLOW}$PORT${NC}"
    echo -e "密码:     ${YELLOW}$PASSWORD${NC}"
    echo -e "----------------------------------------"
    echo -e "Surge 配置参考:"
    echo -e "${GREEN}Hy2-Node = hysteria2, $VPS_IP, $PORT, password=$PASSWORD, sni=$DOMAIN${NC}"
    echo -e "----------------------------------------"
    echo -e "Loon 配置参考:"
    echo -e "${GREEN}Hy2-Node = Hysteria2, $VPS_IP, $PORT, password=$PASSWORD, sni=$DOMAIN${NC}"
    echo -e "${GREEN}========================================${NC}"
}

uninstall_hy2() {
    read -p "确认卸载 Hysteria 2? (y/N): " CONFIRM
    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}正在清理 Hysteria 2...${NC}"
        systemctl stop hysteria-server
        systemctl disable hysteria-server
        rm -rf /etc/hysteria
        rm -f /usr/local/bin/hysteria
        rm -f /etc/systemd/system/hysteria-server.service
        systemctl daemon-reload
        echo -e "${GREEN}卸载完成。${NC}"
    fi
}

check_update() {
    if [ ! -f "/usr/local/bin/hysteria" ]; then
        echo -e "${RED}未安装 Hysteria 2。${NC}"
        return
    fi
    
    LOCAL_VER=$(/usr/local/bin/hysteria version | grep -i 'app version' | awk '{print $3}')
    echo -e "当前本地版本: ${LOCAL_VER:-未知}"
    
    LATEST_VER=$(curl -s https://api.github.com/repos/apernet/hysteria/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    echo -e "GitHub 最新版本: ${LATEST_VER:-获取失败}"
    
    if [[ "$LOCAL_VER" != "$LATEST_VER" && -n "$LATEST_VER" ]]; then
        echo -e "${YELLOW}发现新版本，若需更新请重新选择 [1] 执行覆盖安装。${NC}"
    else
        echo -e "${GREEN}当前已是最新版本。${NC}"
    fi
}

# 循环主菜单逻辑
while true; do
    clear
    echo -e "${GREEN}Hysteria 2 一键管理脚本${NC}"
    check_status
    echo "--------------------------------"
    echo "1. 安装 / 覆盖安装"
    echo "2. 卸载"
    echo "3. 重启服务"
    echo "4. 查看运行状态 (实时日志)"
    echo "5. 查看当前配置"
    echo "6. 检查更新"
    echo "7. 退出"
    read -p "请选择 [1-7]: " opt

    echo -e "\n"
    case $opt in
        1) install_hy2 ;;
        2) uninstall_hy2 ;;
        3) systemctl restart hysteria-server && echo -e "${GREEN}已重启${NC}" ;;
        4) 
           echo -e "${YELLOW}已打开日志分页查看模式，按 'q' 即可退出并返回菜单。${NC}"
           journalctl -u hysteria-server -e 
           ;;
        5) view_config ;;
        6) check_update ;;
        7) echo -e "${CYAN}已退出脚本。${NC}"; exit 0 ;;
        *) echo -e "${RED}无效选择。${NC}" ;;
    esac
    
    echo -e "\n"
    read -n 1 -s -r -p "按任意键返回主菜单..."
done
