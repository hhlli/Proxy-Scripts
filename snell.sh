#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 权限运行此脚本!${NC}" && exit 1

check_status() {
    systemctl is-active --quiet snell && echo -e "Snell v5: ${GREEN}运行中${NC}" || echo -e "Snell v5: ${RED}未安装或停止${NC}"
    systemctl is-active --quiet shadowtls && echo -e "ShadowTLS v3: ${GREEN}运行中${NC}" || echo -e "ShadowTLS v3: ${YELLOW}未安装或停止${NC}"
}

# --- 配置读取模块 ---
view_config() {
    if [ ! -f "/etc/snell/snell-server.conf" ]; then
        echo -e "${RED}未找到 Snell 配置文件!${NC}"
        return
    fi

    SNELL_LISTEN=$(grep "listen =" /etc/snell/snell-server.conf | tr -d ' ' | awk -F= '{print $2}')
    SNELL_PORT=$(echo "$SNELL_LISTEN" | awk -F: '{print $NF}')
    SNELL_PSK=$(grep "psk =" /etc/snell/snell-server.conf | awk -F= '{print $2}' | tr -d ' ')

    echo -e "${GREEN}=== 当前 Snell v5 配置 ===${NC}"
    echo -e "监听地址: ${YELLOW}$SNELL_LISTEN${NC}"
    echo -e "PSK 密码: ${YELLOW}$SNELL_PSK${NC}"
    echo -e "----------------------------------------"

    if [ -f "/etc/systemd/system/shadowtls.service" ] && systemctl is-active --quiet shadowtls; then
        # 提取 ShadowTLS 启动参数
        EXEC_LINE=$(grep "ExecStart" /etc/systemd/system/shadowtls.service)
        STLS_PORT=$(echo "$EXEC_LINE" | awk '{print $4}' | awk -F: '{print $2}')
        STLS_SNI=$(echo "$EXEC_LINE" | awk '{print $6}' | awk -F: '{print $1}')
        STLS_PASS=$(echo "$EXEC_LINE" | awk '{print $7}')

        echo -e "${GREEN}=== 当前 ShadowTLS v3 配置 ===${NC}"
        echo -e "外部端口: ${YELLOW}$STLS_PORT${NC}"
        echo -e "伪装 SNI: ${YELLOW}$STLS_SNI${NC}"
        echo -e "STLS密码: ${YELLOW}$STLS_PASS${NC}"
        echo -e "----------------------------------------"
        echo -e "Surge 配置参考 (组合模式):"
        echo -e "${GREEN}Snell-STLS = snell, 你的服务器IP, $STLS_PORT, psk=$SNELL_PSK, version=5, shadow-tls-password=$STLS_PASS, shadow-tls-sni=$STLS_SNI, shadow-tls-version=3${NC}"
    else
        echo -e "Surge 配置参考 (直连模式):"
        echo -e "${GREEN}Snell-Direct = snell, 你的服务器IP, $SNELL_PORT, psk=$SNELL_PSK, version=5${NC}"
    fi
}

# --- 核心安装模块 ---
install_snell_core() {
    local LISTEN_IP=$1
    local PORT=$2
    local PSK=$3

    echo -e "${YELLOW}部署 Snell v5 核心...${NC}"
    arch=$(uname -m)
    if [ "$arch" == "x86_64" ]; then
        url="https://dl.nssurge.com/snell/snell-server-v5.0.1-linux-amd64.zip"
    elif [ "$arch" == "aarch64" ]; then
        url="https://dl.nssurge.com/snell/snell-server-v5.0.1-linux-aarch64.zip"
    else
        echo -e "${RED}不支持的架构!${NC}" && exit 1
    fi

    apt update && apt install -y unzip curl
    wget -q -O /tmp/snell.zip $url
    unzip -o -q /tmp/snell.zip -d /usr/local/bin/
    chmod +x /usr/local/bin/snell-server
    rm -f /tmp/snell.zip

    mkdir -p /etc/snell
    cat << EOF > /etc/snell/snell-server.conf
[snell-server]
listen = $LISTEN_IP:$PORT
psk = $PSK
ipv6 = false
EOF

    cat << EOF > /etc/systemd/system/snell.service
[Unit]
Description=Snell v5 Proxy Service
After=network.target

[Service]
Type=simple
LimitNOFILE=32768
ExecStart=/usr/local/bin/snell-server -c /etc/snell/snell-server.conf
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now snell
}

install_shadowtls_core() {
    local EXTERNAL_PORT=$1
    local INTERNAL_PORT=$2
    local SNI=$3
    local PASS=$4

    echo -e "${YELLOW}部署 ShadowTLS v3 核心...${NC}"
    arch=$(uname -m)
    if [ "$arch" == "x86_64" ]; then
        stls_url="https://github.com/ihciah/shadow-tls/releases/latest/download/shadow-tls-x86_64-unknown-linux-musl"
    elif [ "$arch" == "aarch64" ]; then
        stls_url="https://github.com/ihciah/shadow-tls/releases/latest/download/shadow-tls-aarch64-unknown-linux-musl"
    fi

    wget -q -O /usr/local/bin/shadowtls $stls_url
    chmod +x /usr/local/bin/shadowtls

    cat << EOF > /etc/systemd/system/shadowtls.service
[Unit]
Description=ShadowTLS v3 Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/shadowtls --v3 0.0.0.0:$EXTERNAL_PORT 127.0.0.1:$INTERNAL_PORT $SNI:443 $PASS
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now shadowtls
}

# --- 交互安装逻辑 ---
do_install_snell_only() {
    read -p "设置 Snell 公网监听端口 (默认 10086): " PORT
    PORT=${PORT:-10086}
    PSK=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20)
    
    install_snell_core "0.0.0.0" "$PORT" "$PSK"
    echo -e "${GREEN}Snell 独立安装完成!${NC}"
    view_config
}

do_install_combo() {
    read -p "设置 ShadowTLS 对外端口 (默认 443): " STLS_PORT
    STLS_PORT=${STLS_PORT:-443}
    read -p "设置伪装 SNI (默认 gateway.icloud.com): " STLS_SNI
    STLS_SNI=${STLS_SNI:-gateway.icloud.com}

    SNELL_PORT=$(shuf -i 10000-65000 -n 1)
    SNELL_PSK=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20)
    STLS_PASS=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16)

    # 1. 安装内网 Snell
    install_snell_core "127.0.0.1" "$SNELL_PORT" "$SNELL_PSK"
    # 2. 安装公网 ShadowTLS
    install_shadowtls_core "$STLS_PORT" "$SNELL_PORT" "$STLS_SNI" "$STLS_PASS"

    echo -e "${GREEN}Snell + ShadowTLS 组合安装完成!${NC}"
    view_config
}

# --- 卸载逻辑 ---
uninstall_shadowtls_only() {
    if [ ! -f "/etc/systemd/system/shadowtls.service" ]; then
        echo -e "${YELLOW}ShadowTLS 未安装。${NC}"
        return
    fi

    echo -e "${YELLOW}正在移除 ShadowTLS...${NC}"
    systemctl stop shadowtls
    systemctl disable shadowtls
    rm -f /usr/local/bin/shadowtls /etc/systemd/system/shadowtls.service

    # 恢复 Snell 的公网监听
    if [ -f "/etc/snell/snell-server.conf" ]; then
        echo -e "${YELLOW}正在恢复 Snell 直连配置...${NC}"
        # 提取当前内部端口
        SNELL_PORT=$(grep "listen =" /etc/snell/snell-server.conf | awk -F: '{print $NF}')
        # 修改监听地址为 0.0.0.0
        sed -i "s/listen = 127.0.0.1:.*/listen = 0.0.0.0:$SNELL_PORT/" /etc/snell/snell-server.conf
        systemctl daemon-reload
        systemctl restart snell
        echo -e "${GREEN}Snell 已恢复公网监听 (端口: $SNELL_PORT)${NC}"
    fi
    echo -e "${GREEN}ShadowTLS 已卸载。${NC}"
}

uninstall_all() {
    echo -e "${YELLOW}正在清理所有组件...${NC}"
    systemctl stop snell shadowtls 2>/dev/null
    systemctl disable snell shadowtls 2>/dev/null
    rm -f /usr/local/bin/snell-server /usr/local/bin/shadowtls
    rm -rf /etc/snell
    rm -f /etc/systemd/system/snell.service /etc/systemd/system/shadowtls.service
    systemctl daemon-reload
    echo -e "${GREEN}完全卸载成功!${NC}"
}

# --- 主菜单 ---
clear
echo -e "${GREEN}Snell v5 & ShadowTLS v3 智能管理脚本 (2026)${NC}"
check_status
echo "--------------------------------"
echo "1. 仅安装 Snell v5 (直连模式)"
echo "2. 安装 Snell + ShadowTLS (组合模式)"
echo "3. 仅卸载 ShadowTLS (恢复 Snell 直连)"
echo "4. 完全卸载 (清理所有)"
echo "5. 重启服务"
echo "6. 查看当前配置"
echo "7. 退出"
read -p "选择 [1-7]: " opt

case $opt in
    1) do_install_snell_only ;;
    2) do_install_combo ;;
    3) uninstall_shadowtls_only ;;
    4) uninstall_all ;;
    5) systemctl restart snell shadowtls 2>/dev/null && echo -e "${GREEN}已发送重启指令${NC}" ;;
    6) view_config ;;
    *) exit 0 ;;
esac
