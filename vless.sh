#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 权限运行此脚本!${NC}" && exit 1

check_status() {
    echo -e "${CYAN}--- 服务状态检测 ---${NC}"
    if systemctl is-active --quiet xray; then
        echo -e "Xray (VLESS) 服务: ${GREEN}运行中${NC}"
    else
        echo -e "Xray (VLESS) 服务: ${RED}未安装或停止${NC}"
    fi
    echo -e "${CYAN}--------------------${NC}\n"
}

clean_xray() {
    systemctl stop xray 2>/dev/null
    systemctl disable xray 2>/dev/null
    rm -f /etc/systemd/system/xray.service
    rm -rf /usr/local/etc/xray
    rm -f /usr/local/bin/xray
    systemctl daemon-reload
}

install_xray_core() {
    local PORT=$1
    local SNI=$2
    local UUID=$3
    local PRIVATE_KEY=$4
    local PUBLIC_KEY=$5
    local SHORT_ID=$6

    clean_xray

    echo -e "${YELLOW}--- 开始部署 VLESS+REALITY ---${NC}"
    
    echo -e "${CYAN}[1/5] 更新系统依赖...${NC}"
    export DEBIAN_FRONTEND=noninteractive
    export NEEDRESTART_MODE=a
    apt-get update -y
    apt-get install -y unzip curl wget openssl

    echo -e "${CYAN}[2/5] 下载 Xray 核心...${NC}"
    arch=$(uname -m)
    if [[ "$arch" == "x86_64" ]]; then
        XRAY_URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip"
    elif [[ "$arch" == "aarch64" ]]; then
        XRAY_URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-arm64-v8a.zip"
    else
        echo -e "${RED}不支持的架构: $arch${NC}" && exit 1
    fi
    wget -O /tmp/xray.zip "$XRAY_URL"

    echo -e "${CYAN}[3/5] 解压并安装...${NC}"
    unzip -o /tmp/xray.zip xray -d /usr/local/bin/
    chmod +x /usr/local/bin/xray
    rm -f /tmp/xray.zip

    echo -e "${CYAN}[4/5] 生成配置文件...${NC}"
    mkdir -p /usr/local/etc/xray
    
    cat << EOF > /usr/local/etc/xray/config.json
{
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$SNI:443",
          "xver": 0,
          "serverNames": [
            "$SNI"
          ],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": [
            "$SHORT_ID"
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "blocked"
    }
  ]
}
EOF
    echo -e "-> 已生成: /usr/local/etc/xray/config.json"

    echo -e "${CYAN}[5/5] 创建并启动服务...${NC}"
    cat << EOF > /etc/systemd/system/xray.service
[Unit]
Description=Xray Service
Documentation=https://github.com/xtls
After=network.target nss-lookup.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF
    echo -e "-> 已生成: /etc/systemd/system/xray.service"
    
    echo "$PUBLIC_KEY" > /usr/local/etc/xray/public.key

    systemctl daemon-reload
    systemctl enable --now xray
    echo -e "-> 系统服务 xray 已设置为开机自启并拉起"
    echo -e "${GREEN}VLESS+REALITY 部署完成。${NC}\n"
}

menu_install() {
    read -p "设置监听端口 (默认 443): " PORT
    PORT=${PORT:-443}
    read -p "设置伪装 SNI 域名 (默认 gateway.icloud.com): " SNI
    SNI=${SNI:-gateway.icloud.com}

    if [ ! -f "/usr/local/bin/xray" ]; then
        apt-get update -y
        apt-get install -y wget unzip
        wget -O /tmp/xray.zip "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip"
        unzip -o /tmp/xray.zip xray -d /tmp/
        chmod +x /tmp/xray
        XRAY_EXEC="/tmp/xray"
    else
        XRAY_EXEC="/usr/local/bin/xray"
    fi

    UUID=$($XRAY_EXEC uuid)
    KEYS=$($XRAY_EXEC x25519)
    PRIVATE_KEY=$(echo "$KEYS" | grep "Private key:" | awk '{print $3}')
    PUBLIC_KEY=$(echo "$KEYS" | grep "Public key:" | awk '{print $3}')
    SHORT_ID=$(openssl rand -hex 8)

    install_xray_core "$PORT" "$SNI" "$UUID" "$PRIVATE_KEY" "$PUBLIC_KEY" "$SHORT_ID"
    
    [ -f "/tmp/xray" ] && rm -f /tmp/xray
    menu_view_config
}

menu_view_config() {
    if [ ! -f "/usr/local/etc/xray/config.json" ]; then
        echo -e "${RED}未找到配置文件。${NC}"
        return
    fi

    PORT=$(grep '"port"' /usr/local/etc/xray/config.json | grep -Eo '[0-9]+')
    UUID=$(grep '"id"' /usr/local/etc/xray/config.json | awk -F'"' '{print $4}')
    SNI=$(grep -A 2 '"serverNames"' /usr/local/etc/xray/config.json | grep -v 'serverNames' | grep -v ']' | awk -F'"' '{print $2}')
    SHORT_ID=$(grep -A 2 '"shortIds"' /usr/local/etc/xray/config.json | grep -v 'shortIds' | grep -v ']' | awk -F'"' '{print $2}')
    PUBLIC_KEY=$(cat /usr/local/etc/xray/public.key 2>/dev/null)

    VPS_IP=$(curl -s4 -m 5 api.ipify.org || curl -s4 -m 5 ifconfig.me || echo "获取失败_请手动替换IP")

    echo -e "${GREEN}=== 当前配置详情 ===${NC}"
    echo -e "协议: VLESS-TCP-REALITY"
    echo -e "IP地址: $VPS_IP"
    echo -e "端口: $PORT"
    echo -e "UUID: $UUID"
    echo -e "SNI: $SNI"
    echo -e "Public Key: $PUBLIC_KEY"
    echo -e "Short ID: $SHORT_ID"
    echo -e "Flow: xtls-rprx-vision"
    echo -e "----------------------------------------"
    echo -e "Loon 配置参考:"
    echo -e "${GREEN}VLESS-Reality = VLESS, $VPS_IP, $PORT, $UUID, tls=true, tls-name=$SNI, reality-public-key=$PUBLIC_KEY, reality-short-id=$SHORT_ID, flow=xtls-rprx-vision${NC}"
}

menu_modify_config() {
    if [ ! -f "/usr/local/etc/xray/config.json" ]; then
        echo -e "${RED}未找到配置文件。${NC}"
        return
    fi

    OLD_PORT=$(grep '"port"' /usr/local/etc/xray/config.json | grep -Eo '[0-9]+')
    OLD_SNI=$(grep -A 2 '"serverNames"' /usr/local/etc/xray/config.json | grep -v 'serverNames' | grep -v ']' | awk -F'"' '{print $2}')

    read -p "设置新的端口 (当前: $OLD_PORT，回车保持): " NEW_PORT
    NEW_PORT=${NEW_PORT:-$OLD_PORT}

    read -p "设置新的 SNI 域名 (当前: $OLD_SNI，回车保持): " NEW_SNI
    NEW_SNI=${NEW_SNI:-$OLD_SNI}

    sed -i "s/\"port\": $OLD_PORT/\"port\": $NEW_PORT/" /usr/local/etc/xray/config.json
    sed -i "s/\"dest\": \"$OLD_SNI:443\"/\"dest\": \"$NEW_SNI:443\"/" /usr/local/etc/xray/config.json
    sed -i "s/\"$OLD_SNI\"/\"$NEW_SNI\"/" /usr/local/etc/xray/config.json

    systemctl restart xray
    echo -e "${GREEN}配置已更新并重启服务。${NC}"
    menu_view_config
}

menu_view_logs() {
    echo -e "显示服务日志 (按 Ctrl+C 退出):"
    journalctl -u xray -f
}

menu_check_update() {
    if [ ! -f "/usr/local/bin/xray" ]; then
        echo -e "${RED}未安装。${NC}"
        return
    fi
    
    LOCAL_VER=$(/usr/local/bin/xray version | head -n 1 | awk '{print $2}')
    echo -e "当前本地版本: ${LOCAL_VER:-未知}"
    
    LATEST_VER=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    echo -e "GitHub 最新版本: ${LATEST_VER:-获取失败}"
    
    if [[ "$LOCAL_VER" != "$LATEST_VER" && -n "$LATEST_VER" ]]; then
        echo -e "${YELLOW}发现新版本，若需更新请重新选择 [1] 执行安装。${NC}"
    else
        echo -e "${GREEN}当前已是最新版本。${NC}"
    fi
}

menu_uninstall() {
    read -p "确认完全卸载? (y/N): " CONFIRM
    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
        clean_xray
        echo -e "${GREEN}卸载完成。${NC}"
    fi
}

clear
check_status

echo "1. 安装 VLESS+REALITY"
echo "2. 查看配置"
echo "3. 修改配置 (端口/SNI)"
echo "4. 查看运行状态"
echo "5. 检查更新"
echo "6. 卸载"
echo "7. 退出"
read -p "选择 [1-7]: " opt

case $opt in
    1) menu_install ;;
    2) menu_view_config ;;
    3) menu_modify_config ;;
    4) menu_view_logs ;;
    5) menu_check_update ;;
    6) menu_uninstall ;;
    7) exit 0 ;;
    *) exit 1 ;;
esac
