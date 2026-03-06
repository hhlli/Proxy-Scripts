#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 权限运行此脚本!${NC}" && exit 1

clean_alien_snell() {
    local quiet=$1
    [[ -z "$quiet" ]] && echo -e "${YELLOW}正在清理旧版/异形 Snell 残留...${NC}"
    
    ALIEN_SERVICES=$(systemctl list-unit-files | grep -i snell | grep -v "shadowtls" | awk '{print $1}')
    for svc in $ALIEN_SERVICES; do
        if [ "$svc" != "snell.service" ]; then
            systemctl stop "$svc" 2>/dev/null
            systemctl disable "$svc" 2>/dev/null
            rm -f "/etc/systemd/system/$svc" "/lib/systemd/system/$svc"
        fi
    done

    pkill -9 -x "snell-server" 2>/dev/null
    
    rm -f /usr/local/bin/snell-server /usr/bin/snell-server /usr/local/bin/snell
    rm -rf /etc/snell-server /etc/snell
    systemctl daemon-reload
}

check_status() {
    echo -e "${CYAN}--- 全盘状态检测 ---${NC}"
    
    ALIEN_PID=$(pgrep -x "snell-server" | head -n 1)
    if [ -n "$ALIEN_PID" ]; then
        ALIEN_EXE=$(readlink -f /proc/$ALIEN_PID/exe 2>/dev/null)
        echo -e "${YELLOW}警告: 检测到未知版本的 Snell 正在运行! (PID: $ALIEN_PID)${NC}"
    fi

    if systemctl is-active --quiet snell; then
        echo -e "Snell v5 服务:     ${GREEN}运行中${NC}"
    else
        echo -e "Snell v5 服务:     ${RED}未安装或停止${NC}"
    fi

    if systemctl is-active --quiet shadowtls; then
        echo -e "ShadowTLS v3 服务: ${GREEN}运行中${NC}"
    else
        echo -e "ShadowTLS v3 服务: ${YELLOW}未安装或停止${NC}"
    fi
    echo -e "${CYAN}--------------------${NC}\n"
}

install_snell_core() {
    local LISTEN_IP=$1
    local PORT=$2
    local PSK=$3

    clean_alien_snell "quiet"

    echo -e "${YELLOW}部署 Snell v5 核心...${NC}"
    arch=$(uname -m)
    if [ "$arch" == "x86_64" ]; then
        url="https://dl.nssurge.com/snell/snell-server-v5.0.1-linux-amd64.zip"
    elif [ "$arch" == "aarch64" ]; then
        url="https://dl.nssurge.com/snell/snell-server-v5.0.1-linux-aarch64.zip"
    else
        echo -e "${RED}不支持的架构!${NC}" && exit 1
    fi

    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq unzip curl >/dev/null 2>&1
    
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

menu_install_snell() {
    read -p "设置 Snell 公网监听端口 (默认 10086): " PORT
    PORT=${PORT:-10086}
    PSK=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20)
    
    install_snell_core "0.0.0.0" "$PORT" "$PSK"
    echo -e "${GREEN}Snell 独立安装完成!${NC}"
    menu_view_config
}

menu_install_combo() {
    read -p "设置 ShadowTLS 对外公网端口 (默认 443): " STLS_PORT
    STLS_PORT=${STLS_PORT:-443}
    read -p "设置伪装 SNI 域名 (默认 gateway.icloud.com): " STLS_SNI
    STLS_SNI=${STLS_SNI:-gateway.icloud.com}

    SNELL_PORT=$(shuf -i 10000-65000 -n 1)
    SNELL_PSK=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20)
    STLS_PASS=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16)

    install_snell_core "127.0.0.1" "$SNELL_PORT" "$SNELL_PSK"
    install_shadowtls_core "$STLS_PORT" "$SNELL_PORT" "$STLS_SNI" "$STLS_PASS"

    echo -e "${GREEN}Snell + ShadowTLS 组合安装完成!${NC}"
    # 等待一秒确保服务配置落盘
    sleep 1
    menu_view_config
}

menu_view_config() {
    if [ ! -f "/etc/snell/snell-server.conf" ]; then
        echo -e "${RED}未找到 Snell 配置文件，请先安装!${NC}"
        return
    fi

    SNELL_LISTEN=$(grep "listen =" /etc/snell/snell-server.conf | tr -d ' ' | awk -F= '{print $2}')
    SNELL_PORT=$(echo "$SNELL_LISTEN" | awk -F: '{print $NF}')
    SNELL_PSK=$(grep "psk =" /etc/snell/snell-server.conf | awk -F= '{print $2}' | tr -d ' ')

    echo -e "${GREEN}=== 当前配置详情 ===${NC}"
    
    # 修复点：只要服务文件存在即认为是组合模式，不再依赖实时的 is-active 状态
    if [ -f "/etc/systemd/system/shadowtls.service" ]; then
        EXEC_LINE=$(grep "ExecStart" /etc/systemd/system/shadowtls.service)
        STLS_PORT=$(echo "$EXEC_LINE" | awk '{print $4}' | awk -F: '{print $2}')
        STLS_SNI=$(echo "$EXEC_LINE" | awk '{print $6}' | awk -F: '{print $1}')
        STLS_PASS=$(echo "$EXEC_LINE" | awk '{print $7}')

        echo -e "模式: ${YELLOW}组合 (ShadowTLS接管公网)${NC}"
        echo -e "对外端口: ${YELLOW}$STLS_PORT${NC}"
        echo -e "伪装 SNI: ${YELLOW}$STLS_SNI${NC}"
        echo -e "STLS密码: ${YELLOW}$STLS_PASS${NC}"
        echo -e "Snell 密码: ${YELLOW}$SNELL_PSK${NC}"
        echo -e "----------------------------------------"
        echo -e "Surge 配置参考:"
        # 在组合模式下，Surge 填写的端口必须是 STLS_PORT
        echo -e "${GREEN}Snell-STLS = snell, 你的IP, $STLS_PORT, psk=$SNELL_PSK, version=5, shadow-tls-password=$STLS_PASS, shadow-tls-sni=$STLS_SNI, shadow-tls-version=3${NC}"
    else
        echo -e "模式: ${YELLOW}直连 (仅 Snell)${NC}"
        echo -e "监听端口: ${YELLOW}$SNELL_PORT${NC}"
        echo -e "Snell 密码: ${YELLOW}$SNELL_PSK${NC}"
        echo -e "----------------------------------------"
        echo -e "Surge 配置参考:"
        echo -e "${GREEN}Snell-Direct = snell, 你的IP, $SNELL_PORT, psk=$SNELL_PSK, version=5${NC}"
    fi
}

menu_modify_config() {
    if [ ! -f "/etc/snell/snell-server.conf" ]; then
        echo -e "${RED}配置文件不存在，请先安装!${NC}"
        return
    fi

    if [ -f "/etc/systemd/system/shadowtls.service" ]; then
        echo -e "${CYAN}当前为 Snell + ShadowTLS 模式${NC}"
        read -p "设置新的公网对外端口: " NEW_PORT
        NEW_STLS_PASS=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16)
        NEW_SNELL_PSK=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20)

        sed -i "s/psk = .*/psk = $NEW_SNELL_PSK/" /etc/snell/snell-server.conf
        sed -i -E "s/0\.0\.0\.0:[0-9]+/0.0.0.0:$NEW_PORT/" /etc/systemd/system/shadowtls.service
        sed -i -E "s/ [A-Za-z0-9]{16}$/ $NEW_STLS_PASS/" /etc/systemd/system/shadowtls.service
        
        systemctl daemon-reload
        systemctl restart snell shadowtls
        echo -e "${GREEN}配置已更新并重启服务 (已生成新密码)。${NC}"
    else
        echo -e "${CYAN}当前为仅 Snell 直连模式${NC}"
        read -p "设置新的公网端口: " NEW_PORT
        NEW_SNELL_PSK=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20)
        
        sed -i -E "s/listen = 0\.0\.0\.0:[0-9]+/listen = 0.0.0.0:$NEW_PORT/" /etc/snell/snell-server.conf
        sed -i "s/psk = .*/psk = $NEW_SNELL_PSK/" /etc/snell/snell-server.conf
        
        systemctl restart snell
        echo -e "${GREEN}配置已更新并重启服务 (已生成新密码)。${NC}"
    fi
    menu_view_config
}

menu_view_logs() {
    echo -e "${YELLOW}显示服务日志 (按 Ctrl+C 退出):${NC}"
    if systemctl is-active --quiet shadowtls; then
        journalctl -u snell -u shadowtls -f
    else
        journalctl -u snell -f
    fi
}

menu_check_update() {
    echo -e "${YELLOW}正在检测 Snell 服务端更新...${NC}"
    if [ ! -f "/usr/local/bin/snell-server" ]; then
        echo -e "${RED}尚未安装 Snell。${NC}"
        return
    fi
    
    LOCAL_VER=$(/usr/local/bin/snell-server --version 2>&1 | head -n 1 | awk '{print $2}')
    echo -e "当前本地版本: ${CYAN}$LOCAL_VER${NC}"
    echo -e "Snell 暂无官方 API 查询最新版本，当前脚本默认下载的最新版为: ${CYAN}v5.0.1${NC}"
    
    if [[ "$LOCAL_VER" != *"v5"* ]]; then
        echo -e "${YELLOW}发现您使用的不是 v5 系列，建议通过选项 1 或 2 覆盖安装。${NC}"
    else
        echo -e "${GREEN}您的内核已是 v5 系列。${NC}"
    fi
}

menu_uninstall() {
    echo -e "${YELLOW}警告: 即将完全卸载系统中的 Snell 和 ShadowTLS。${NC}"
    read -p "确认卸载? (y/N): " CONFIRM
    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
        clean_alien_snell "quiet"
        systemctl stop shadowtls 2>/dev/null
        systemctl disable shadowtls 2>/dev/null
        rm -f /usr/local/bin/shadowtls /etc/systemd/system/shadowtls.service
        systemctl daemon-reload
        echo -e "${GREEN}完全卸载完毕。系统已清理。${NC}"
    else
        echo -e "已取消。"
    fi
}

clear
check_status

echo "1. 安装 Snell v5"
echo "2. 安装 Snell v5 + ShadowTLS v3"
echo "3. 查看配置"
echo "4. 修改配置"
echo "5. 查看运行状态"
echo "6. 检查更新"
echo "7. 卸载 (清理所有组件)"
echo "8. 退出"
read -p "选择 [1-8]: " opt

case $opt in
    1) menu_install_snell ;;
    2) menu_install_combo ;;
    3) menu_view_config ;;
    4) menu_modify_config ;;
    5) menu_view_logs ;;
    6) menu_check_update ;;
    7) menu_uninstall ;;
    8) exit 0 ;;
    *) echo -e "${RED}无效选择。${NC}" && exit 1 ;;
esac
