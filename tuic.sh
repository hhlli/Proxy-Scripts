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
    if [ -f "/usr/local/bin/tuic-server" ]; then
        if systemctl is-active --quiet tuic; then
            echo -e "TUIC v5 状态: ${GREEN}运行中${NC}"
        else
            echo -e "TUIC v5 状态: ${YELLOW}已安装，但未运行${NC}"
        fi
    else
        echo -e "TUIC v5 状态: ${RED}未安装${NC}"
    fi
}

view_config() {
    CONF="/etc/tuic/config.json"
    if [ ! -f "$CONF" ]; then
        echo -e "${RED}配置文件不存在，请先安装!${NC}"
        return
    fi
    
    get_ip
    PORT=$(grep '"server":' $CONF | awk -F: '{print $NF}' | tr -d '", ')
    UUID=$(grep -oE '[a-z0-9A-Z-]{36}' $CONF | head -1 | tr '[:lower:]' '[:upper:]')
    PASSWORD=$(grep -i "\"$UUID\":" $CONF | awk -F: '{print $2}' | tr -d '", ')
    
    CERT_FILE=$(grep '"certificate":' $CONF | awk -F'"' '{print $4}')
    DOMAIN=$(openssl x509 -noout -subject -in "$CERT_FILE" 2>/dev/null | grep -oE 'CN\s*=\s*[^,]+' | awk -F'=' '{print $2}' | tr -d ' ' | sed 's/CN=//g')
    DOMAIN=${DOMAIN:-"你的域名"}

    echo -e "${GREEN}=== 当前 TUIC v5 配置 ===${NC}"
    echo -e "节点IP:   ${YELLOW}$VPS_IP${NC}"
    echo -e "域名/SNI: ${YELLOW}$DOMAIN${NC}"
    echo -e "监听端口: ${YELLOW}$PORT${NC}"
    echo -e "UUID:     ${YELLOW}$UUID${NC}"
    echo -e "Password: ${YELLOW}$PASSWORD${NC}"
    echo -e "----------------------------------------"
    echo -e "Surge 配置参考:"
    echo -e "${GREEN}TUIC-Node = tuic-v5, $VPS_IP, $PORT, password=$PASSWORD, uuid=$UUID, alpn=h3, sni=$DOMAIN${NC}"
}

modify_config() {
    CONF="/etc/tuic/config.json"
    if [ ! -f "$CONF" ]; then
        echo -e "${RED}配置文件不存在，请先安装!${NC}"
        return
    fi

    read -p "设置新端口: " NEW_PORT
    
    NEW_PASSWORD=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16)
    CURRENT_UUID=$(grep -oE '[a-z0-9A-Z-]{36}' $CONF | head -1)

    sed -i "s/\"server\": \".*\"/\"server\": \"[::]:$NEW_PORT\"/" $CONF
    sed -i "s/\"$CURRENT_UUID\": \".*\"/\"$CURRENT_UUID\": \"$NEW_PASSWORD\"/" $CONF

    systemctl restart tuic
    echo -e "${GREEN}配置已更新并重启服务。新的强密码已生效。${NC}"
    view_config
}

install_tuic() {
    read -p "设置域名 (请输入域名): " DOMAIN
    read -p "设置端口 (默认 443): " PORT
    PORT=${PORT:-443}
    
    get_ip
    
    echo -e "${YELLOW}正在自动生成 UUID 与强密码...${NC}"
    USER_UUID=$(cat /proc/sys/kernel/random/uuid | tr '[:lower:]' '[:upper:]')
    PASSWORD=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16)
    
    arch=$(uname -m)
    echo -e "${YELLOW}正在下载 TUIC v5 服务端...${NC}"
    if [ "$arch" == "x86_64" ]; then
        url="https://github.com/EAimTY/tuic/releases/download/tuic-server-1.0.0/tuic-server-1.0.0-x86_64-unknown-linux-gnu"
    elif [ "$arch" == "aarch64" ]; then
        url="https://github.com/EAimTY/tuic/releases/download/tuic-server-1.0.0/tuic-server-1.0.0-aarch64-unknown-linux-gnu"
    else
        echo -e "${RED}不支持的架构: $arch${NC}" && exit 1
    fi
    curl -L $url -o /usr/local/bin/tuic-server && chmod +x /usr/local/bin/tuic-server

    if [ -f "/etc/hysteria/certs/server.crt" ]; then
        echo -e "${GREEN}检测到现有 Hysteria 2 证书，直接复用。${NC}"
        CERT_PATH="/etc/hysteria/certs/server.crt"
        KEY_PATH="/etc/hysteria/certs/server.key"
    elif [ -f "/etc/tuic/certs/server.crt" ]; then
        echo -e "${GREEN}检测到现有 TUIC 证书，直接复用。${NC}"
        CERT_PATH="/etc/tuic/certs/server.crt"
        KEY_PATH="/etc/tuic/certs/server.key"
    else
        echo -e "${YELLOW}未检测到可用证书，开始自动申请独立证书...${NC}"
        apt update && apt install -y curl socat openssl
        curl https://get.acme.sh | sh -s email=admin@$DOMAIN
        source ~/.bashrc
        ~/.acme.sh/acme.sh --issue -d $DOMAIN --standalone --force
        mkdir -p /etc/tuic/certs
        ~/.acme.sh/acme.sh --install-cert -d $DOMAIN \
            --key-file /etc/tuic/certs/server.key \
            --fullchain-file /etc/tuic/certs/server.crt
        CERT_PATH="/etc/tuic/certs/server.crt"
        KEY_PATH="/etc/tuic/certs/server.key"
    fi

    mkdir -p /etc/tuic
    cat << EOF > /etc/tuic/config.json
{
    "server": "[::]:$PORT",
    "users": {
        "$USER_UUID": "$PASSWORD"
    },
    "certificate": "$CERT_PATH",
    "private_key": "$KEY_PATH",
    "congestion_control": "bbr",
    "alpn": ["h3"],
    "zero_rtt_handshake": true,
    "dual_stack": true,
    "auth_timeout": "3s",
    "task_negotiation_timeout": "3s",
    "max_idle_time": "10s"
}
EOF

    cat << EOF > /etc/systemd/system/tuic.service
[Unit]
Description=TUIC v5 Server Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/etc/tuic
ExecStart=/usr/local/bin/tuic-server -c /etc/tuic/config.json
Restart=on-failure
RestartSec=5s
LimitNOFILE=512000

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable tuic
    systemctl restart tuic
    
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}TUIC v5 安装成功!${NC}"
    echo -e "节点IP:   ${YELLOW}$VPS_IP${NC}"
    echo -e "域名/SNI: ${YELLOW}$DOMAIN${NC}"
    echo -e "端口:     ${YELLOW}$PORT${NC}"
    echo -e "UUID:     ${YELLOW}$USER_UUID${NC}"
    echo -e "Password: ${YELLOW}$PASSWORD${NC}"
    echo -e "----------------------------------------"
    echo -e "Surge 配置参考:"
    echo -e "${GREEN}TUIC-Node = tuic-v5, $VPS_IP, $PORT, password=$PASSWORD, uuid=$USER_UUID, alpn=h3, sni=$DOMAIN${NC}"
    echo -e "${GREEN}========================================${NC}"
}

uninstall_tuic() {
    echo -e "${YELLOW}正在卸载 TUIC v5...${NC}"
    systemctl stop tuic
    systemctl disable tuic
    rm -f /usr/local/bin/tuic-server
    rm -rf /etc/tuic
    rm -f /etc/systemd/system/tuic.service
    systemctl daemon-reload
    echo -e "${GREEN}卸载完成。${NC}"
}

while true; do
    clear
    echo -e "${GREEN}TUIC v5 一键管理脚本${NC}"
    check_status
    echo "--------------------------------"
    echo "1. 安装 / 覆盖安装"
    echo "2. 卸载"
    echo "3. 重启服务"
    echo "4. 查看运行状态 (实时日志)"
    echo "5. 查看当前配置"
    echo "6. 修改端口和 Password"
    echo "7. 退出"
    read -p "请选择 [1-7]: " opt

    echo -e "\n"
    case $opt in
        1) install_tuic ;;
        2) uninstall_tuic ;;
        3) systemctl restart tuic && echo -e "${GREEN}已重启${NC}" ;;
        4) 
           echo -e "${YELLOW}已打开日志分页查看模式，按 'q' 即可退出并返回菜单。${NC}"
           journalctl -u tuic -e 
           ;;
        5) view_config ;;
        6) modify_config ;;
        7) echo -e "${CYAN}已退出脚本。${NC}"; exit 0 ;;
        *) echo -e "${RED}无效选择。${NC}" ;;
    esac
    
    echo -e "\n"
    read -n 1 -s -r -p "按任意键返回主菜单..."
done
