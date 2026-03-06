#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 权限运行此脚本!${NC}" && exit 1

clean_alien_snell() {
    local quiet=$1
    [[ -z "$quiet" ]] && echo -e "${YELLOW}扫描并清理旧版残留...${NC}"
    
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
        echo -e "${YELLOW}提示: 检测到非本脚本控制的 Snell 正在运行 (PID: $ALIEN_PID)${NC}"
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

    echo -e "${YELLOW}--- 开始部署 Snell v5 ---${NC}"
    arch=$(uname -m)
    if [ "$arch" == "x86_64" ]; then
        url="https://dl.nssurge.com/snell/snell-server-v5.0.1-linux-amd64.zip"
    elif [ "$arch" == "aarch64" ]; then
        url="https://dl.nssurge.com/snell/snell-server-v5.0.1-linux-aarch64.zip"
    else
        echo -e "${RED}不支持的架构!${NC}" && exit 1
    fi

    echo -e "${CYAN}[1/5] 更新系统依赖...${NC}"
    export DEBIAN_FRONTEND=noninteractive
    export NEEDRESTART_MODE=a
    apt-get update -y >/dev/null 2>&1
    apt-get install -y unzip curl >/dev/null 2>&1
    
    echo -e "${CYAN}[2/5] 下载 Snell v5 核心...${NC}"
    wget -q -O /tmp/snell.zip $url

    echo -e "${CYAN}[3/5] 解压并安装...${NC}"
    unzip -o -q /tmp/snell.zip -d /usr/local/bin/
    chmod +x /usr/local/bin/snell-server
    rm -f /tmp/snell.zip

    echo -e "${CYAN}[4/5] 生成配置文件...${NC}"
    mkdir -p /etc/snell
    cat << EOF > /etc/snell/snell-server.conf
[snell-server]
listen = $LISTEN_IP:$PORT
psk = $PSK
ipv6 = false
EOF

    echo -e "${CYAN}[5/5] 创建并启动服务...${NC}"
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
    echo -e "${GREEN}Snell v5 部署完成。${NC}\n"
}

install_shadowtls_core() {
    local EXTERNAL_PORT=$1
    local INTERNAL_PORT=$2
    local SNI=$3
    local PASS=$4

    echo -e "${YELLOW}--- 开始部署 ShadowTLS v3 ---${NC}"
    arch=$(uname -m)
    if [ "$arch" == "x86_64" ]; then
        stls_url="https://github.com/ihciah/shadow-tls/releases/latest/download/shadow-tls-x86_64-unknown-linux-musl"
    elif [ "$arch" == "aarch64" ]; then
        stls_url="https://github.com/ihciah/shadow-tls/releases/latest/download/shadow-tls-aarch64-unknown-linux-musl"
    fi

    echo -e "${CYAN}[1/3] 下载 ShadowTLS 核心...${NC}"
    wget -q -O /usr/local/bin/shadowtls $stls_url
    chmod +x /usr/local/bin/shadowtls

    echo -e "${CYAN}[2/3] 创建服务与转发规则...${NC}"
    cat << EOF > /etc/systemd/system/shadowtls.service
[Unit]
Description=ShadowTLS v3 Server
After=network.target

[Service]
Type=simple
Environment="STLS_PORT=$EXTERNAL_PORT"
Environment="SNELL_PORT=$INTERNAL_PORT"
Environment="STLS_SNI=$SNI"
Environment="STLS_PASS=$PASS"
ExecStart=/usr/local/bin/shadowtls --v3 server --listen 0.0.0.0:\${STLS_PORT} --server 127.0.0.1:\${SNELL_PORT} --tls \${STLS_SNI}:443 --password \${STLS_PASS}
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

    echo -e "${CYAN}[3/3] 启动服务...${NC}"
    systemctl daemon-reload
    systemctl enable --now shadowtls
    echo -e "${GREEN}ShadowTLS v3 部署完成。${NC}\n"
}

menu_install_snell() {
    read -p "设置 Snell 公网监听端口 (默认 10086): " PORT
    PORT=${PORT:-10086}
    PSK=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20)
    
    install_snell_core "0.0.0.0" "$PORT" "$PSK"
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

    sleep 1
    menu_view_config
}

menu_view_config() {
    if [ ! -f "/etc/snell/snell-server.conf" ]; then
        echo -e "${RED}未找到 Snell 配置文件。${NC}"
        return
    fi

    SNELL_LISTEN=$(grep "listen =" /etc/snell/snell-server.conf | tr -d ' ' | awk -F= '{print $2}')
    SNELL_PORT=$(echo "$SNELL_LISTEN" | awk -F: '{print $NF}')
    SNELL_PSK=$(grep "psk =" /etc/snell/snell-server.conf | awk -F= '{print $2}' | tr -d ' ')

    echo -e "${GREEN}=== 当前配置详情 ===${NC}"
    
    if [ -f "/etc/systemd/system/shadowtls.service" ]; then
        STLS_PORT=$(grep 'Environment="STLS_PORT=' /etc/systemd/system/shadowtls.service | cut -d= -f2- | tr -d '"')
        STLS_SNI=$(grep 'Environment="STLS_SNI=' /etc/systemd/system/shadowtls.service | cut -d= -f2- | tr -d '"')
        STLS_PASS=$(grep 'Environment="STLS_PASS=' /etc/systemd/system/shadowtls.service | cut -d= -f2- | tr -d '"')

        echo -e "模式: 组合 (ShadowTLS接管公网)"
        echo -e "对外端口: $STLS_PORT"
        echo -e "伪装 SNI: $STLS_SNI"
        echo -e "STLS密码: $STLS_PASS"
        echo -e "Snell 密码: $SNELL_PSK"
        echo -e "----------------------------------------"
        echo -e "Surge 配置参考:"
        echo -e "${GREEN}Snell-STLS = snell, 实际ip, $STLS_PORT, psk=$SNELL_PSK, version=5, reuse=true, tfo=true, shadow-tls-password=$STLS_PASS, shadow-tls-sni=$STLS_SNI, shadow-tls-version=3, ecn=true${NC}"
    else
        echo -e "模式: 直连 (仅 Snell)"
        echo -e "监听端口: $SNELL_PORT"
        echo -e "Snell 密码: $SNELL_PSK"
        echo -e "----------------------------------------"
        echo -e "Surge 配置参考:"
        echo -e "${GREEN}Snell-Direct = snell, 实际ip, $SNELL_PORT, psk=$SNELL_PSK, version=5, reuse=true, tfo=true, ecn=true${NC}"
    fi
}

menu_modify_config() {
    if [ ! -f "/etc/snell/snell-server.conf" ]; then
        echo -e "${RED}配置文件不存在。${NC}"
        return
    fi

    if [ -f "/etc/systemd/system/shadowtls.service" ]; then
        echo -e "当前模式: Snell + ShadowTLS"
        OLD_PORT=$(grep 'Environment="STLS_PORT=' /etc/systemd/system/shadowtls.service | cut -d= -f2- | tr -d '"')
        OLD_SNI=$(grep 'Environment="STLS_SNI=' /etc/systemd/system/shadowtls.service | cut -d= -f2- | tr -d '"')

        read -p "设置新的公网对外端口 (当前: $OLD_PORT, 回车保持不变): " NEW_PORT
        NEW_PORT=${NEW_PORT:-$OLD_PORT}

        read -p "设置新的伪装 SNI 域名 (当前: $OLD_SNI, 回车保持不变): " NEW_SNI
        NEW_SNI=${NEW_SNI:-$OLD_SNI}

        NEW_STLS_PASS=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16)
        NEW_SNELL_PSK=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20)

        sed -i "s/psk = .*/psk = $NEW_SNELL_PSK/" /etc/snell/snell-server.conf
        sed -i "s/^Environment=\"STLS_PORT=.*/Environment=\"STLS_PORT=$NEW_PORT\"/" /etc/systemd/system/shadowtls.service
        sed -i "s/^Environment=\"STLS_SNI=.*/Environment=\"STLS_SNI=$NEW_SNI\"/" /etc/systemd/system/shadowtls.service
        sed -i "s/^Environment=\"STLS_PASS=.*/Environment=\"STLS_PASS=$NEW_STLS_PASS\"/" /etc/systemd/system/shadowtls.service
        
        systemctl daemon-reload
        systemctl restart snell shadowtls
        echo -e "${GREEN}配置已更新 (密码已自动重新生成)。${NC}"
    else
        echo -e "当前模式: 仅 Snell"
        SNELL_LISTEN=$(grep "listen =" /etc/snell/snell-server.conf | tr -d ' ' | awk -F= '{print $2}')
        OLD_PORT=$(echo "$SNELL_LISTEN" | awk -F: '{print $NF}')

        read -p "设置新的公网端口 (当前: $OLD_PORT, 回车保持不变): " NEW_PORT
        NEW_PORT=${NEW_PORT:-$OLD_PORT}

        NEW_SNELL_PSK=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20)
        
        sed -i -E "s/listen = 0\.0\.0\.0:[0-9]+/listen = 0.0.0.0:$NEW_PORT/" /etc/snell/snell-server.conf
        sed -i "s/psk = .*/psk = $NEW_SNELL_PSK/" /etc/snell/snell-server.conf
        
        systemctl restart snell
        echo -e "${GREEN}配置已更新 (密码已自动重新生成)。${NC}"
    fi
    menu_view_config
}

menu_view_logs() {
    echo -e "显示服务日志 (按 Ctrl+C 退出):"
    if systemctl is-active --quiet shadowtls; then
        journalctl -u snell -u shadowtls -f
    else
        journalctl -u snell -f
    fi
}

menu_check_update() {
    if [ ! -f "/usr/local/bin/snell-server" ]; then
        echo -e "${RED}未安装。${NC}"
        return
    fi
    
    LOCAL_VER=$(strings /usr/local/bin/snell-server | grep -Eo 'snell-server v[0-9.]+' | head -n 1)
    echo -e "当前本地版本: ${LOCAL_VER:-未知版本}"
    echo -e "当前脚本默认安装版本: v5.0.1"
}

menu_uninstall() {
    read -p "确认完全卸载? (y/N): " CONFIRM
    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
        clean_alien_snell "quiet"
        systemctl stop shadowtls 2>/dev/null
        systemctl disable shadowtls 2>/dev/null
        rm -f /usr/local/bin/shadowtls /etc/systemd/system/shadowtls.service
        systemctl daemon-reload
        echo -e "${GREEN}卸载完成。${NC}"
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
echo "7. 卸载"
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
    *) exit 1 ;;
esac
