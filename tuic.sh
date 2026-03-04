#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 检查权限
[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 权限运行此脚本!${NC}" && exit 1

# 检查安装状态
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

# 安装功能
install_tuic() {
    read -p "设置域名 : " DOMAIN
    read -p "设置端口 (默认 443): " PORT
    PORT=${PORT:-443}
    read -p "设置 UUID (留空随机生成): " USER_UUID
    USER_UUID=${USER_UUID:-$(cat /proc/sys/kernel/random/uuid)}
    
    # 密码随机逻辑：如果为空，则生成 12 位随机字符串
    read -p "设置连接密码 (留空随机生成): " PASSWORD
    if [ -z "$PASSWORD" ]; then
        PASSWORD=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 12)
    fi
    
    # 1. 下载二进制文件
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

    # 2. 证书复用检查
    CERT_PATH="/etc/hysteria/certs/server.crt"
    KEY_PATH="/etc/hysteria/certs/server.key"
    
    if [ ! -f "$CERT_PATH" ]; then
        echo -e "${RED}错误: 未找到域名证书! 请先运行 Hy2 脚本完成证书申请。${NC}"
        exit 1
    fi

    # 3. 生成 JSON 配置文件 (已移除无效的 udp_relay_mode 字段)
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

    # 4. 创建 Systemd 服务
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

    # 5. 启动服务
    systemctl daemon-reload
    systemctl enable tuic
    systemctl restart tuic
    
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}TUIC v5 安装并配置完成!${NC}"
    echo -e "域名: ${YELLOW}$DOMAIN${NC}"
    echo -e "端口: ${YELLOW}$PORT${NC}"
    echo -e "UUID: ${YELLOW}$USER_UUID${NC}"
    echo -e "密码: ${YELLOW}$PASSWORD${NC}"
    echo -e "----------------------------------------"
    echo -e "Surge 配置参考:"
    echo -e "${GREEN}TUIC-Node = tuic, $DOMAIN, $PORT, password=$PASSWORD, uuid=$USER_UUID, sni=$DOMAIN, skip-cert-verify=false, alpn=h3${NC}"
    echo -e "${GREEN}========================================${NC}"
}

# 卸载功能
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

# 主菜单
clear
echo -e "${GREEN}TUIC v5 一键管理脚本 (2026)${NC}"
check_status
echo "--------------------------------"
echo "1. 安装 / 覆盖安装"
echo "2. 卸载"
echo "3. 重启服务"
echo "4. 查看实时日志"
echo "5. 退出"
read -p "请选择 [1-5]: " opt

case $opt in
    1) install_tuic ;;
    2) uninstall_tuic ;;
    3) systemctl restart tuic && echo -e "${GREEN}已重启${NC}" ;;
    4) journalctl -u tuic -f ;;
    *) exit 0 ;;
esac
