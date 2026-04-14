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
    if [ -f "/usr/local/bin/anytls-server" ]; then
        if systemctl is-active --quiet anytls; then
            echo -e "AnyTLS 状态: ${GREEN}运行中 (Sing-box 核心)${NC}"
        else
            echo -e "AnyTLS 状态: ${YELLOW}已安装，但未运行${NC}"
        fi
    else
        echo -e "AnyTLS 状态: ${RED}未安装${NC}"
    fi
}

view_config() {
    CONF="/etc/anytls/config.json"
    if [ ! -f "$CONF" ]; then
        echo -e "${RED}配置文件不存在，请先安装!${NC}"
        return
    fi
    
    get_ip
    PORT=$(grep '"listen_port":' $CONF | awk -F: '{print $NF}' | tr -d '", ')
    PASSWORD=$(grep '"password":' $CONF | awk -F: '{print $2}' | tr -d '", ')
    DOMAIN=$(grep '"server_name":' $CONF | awk -F: '{print $2}' | tr -d '", ')

    echo -e "${GREEN}=== 当前 AnyTLS 配置 ===${NC}"
    echo -e "节点IP:   ${YELLOW}$VPS_IP${NC}"
    echo -e "监听端口: ${YELLOW}$PORT${NC}"
    echo -e "Password: ${YELLOW}$PASSWORD${NC}"
    echo -e "域名/SNI: ${YELLOW}$DOMAIN${NC}"
    echo -e "----------------------------------------"
    echo -e "Surge 配置参考 (已启用真实证书校验):"
    echo -e "${GREEN}AnyTLS-Node = anytls, $DOMAIN, $PORT, password=$PASSWORD, sni=$DOMAIN${NC}"
}

modify_config() {
    CONF="/etc/anytls/config.json"
    if ! [ -f "$CONF" ]; then
        echo -e "${RED}配置文件不存在，请先安装!${NC}"
        return
    fi

    read -p "设置新端口: " NEW_PORT
    NEW_PASSWORD=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16)

    sed -i -E "s/\"listen_port\": [0-9]+/\"listen_port\": $NEW_PORT/" $CONF
    sed -i -E "s/\"password\": \".*\"/\"password\": \"$NEW_PASSWORD\"/" $CONF

    systemctl restart anytls
    echo -e "${GREEN}配置已更新并重启服务。新的强密码已生效。${NC}"
    view_config
}

download_and_replace_core() {
    local target_version=$1
    echo -e "${CYAN}开始获取 Sing-box 核心 (版本: v${target_version})...${NC}"
    
    arch=$(uname -m)
    if [ "$arch" == "x86_64" ]; then
        url="https://github.com/SagerNet/sing-box/releases/download/v${target_version}/sing-box-${target_version}-linux-amd64.tar.gz"
    elif [ "$arch" == "aarch64" ]; then
        url="https://github.com/SagerNet/sing-box/releases/download/v${target_version}/sing-box-${target_version}-linux-arm64.tar.gz"
    else
        echo -e "${RED}不支持的架构: $arch${NC}" && exit 1
    fi
    
    apt update -y && apt install -y curl tar wget
    wget -q -O /tmp/sb.tar.gz "$url"
    tar -xzf /tmp/sb.tar.gz -C /tmp/
    
    systemctl stop anytls 2>/dev/null
    mv /tmp/sing-box-*/sing-box /usr/local/bin/anytls-server
    chmod +x /usr/local/bin/anytls-server
    rm -rf /tmp/sb.tar.gz /tmp/sing-box-*
}

install_anytls() {
    CONF="/etc/anytls/config.json"
    
    if [ -f "$CONF" ]; then
        OLD_DOMAIN=$(grep '"server_name":' $CONF | awk -F: '{print $2}' | tr -d '", ')
        OLD_PORT=$(grep '"listen_port":' $CONF | awk -F: '{print $NF}' | tr -d '", ')
        
        echo -e "${YELLOW}检测到已有配置 (域名: $OLD_DOMAIN, 端口: $OLD_PORT)。${NC}"
        read -p "是否保留现有配置，仅执行核心更新？(Y/n，默认保留): " KEEP_CONF
        KEEP_CONF=${KEEP_CONF:-Y}
        
        if [[ "$KEEP_CONF" =~ ^[Yy]$ ]]; then
            LATEST_VERSION=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')
            [[ -z "$LATEST_VERSION" ]] && LATEST_VERSION="1.11.4"
            
            download_and_replace_core "$LATEST_VERSION"
            systemctl start anytls
            
            echo -e "${GREEN}核心更新完成，已成功保留原有配置！${NC}"
            view_config
            return
        fi
    fi

    read -p "设置域名 (请输入域名): " DOMAIN
    read -p "设置端口 (默认 4430): " PORT
    PORT=${PORT:-4430}
    
    echo -e "${YELLOW}正在自动生成强密码...${NC}"
    PASSWORD=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16)
    
    LATEST_VERSION=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')
    [[ -z "$LATEST_VERSION" ]] && LATEST_VERSION="1.11.4"
    
    download_and_replace_core "$LATEST_VERSION"

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
        curl https://get.acme.sh | sh -s email=admin@$DOMAIN
        source ~/.bashrc
        ~/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone --force
        mkdir -p /etc/anytls/certs
        ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
            --key-file /etc/anytls/certs/server.key \
            --fullchain-file /etc/anytls/certs/server.crt
        CERT_PATH="/etc/anytls/certs/server.crt"
        KEY_PATH="/etc/anytls/certs/server.key"
    fi

    mkdir -p /etc/anytls
    cat << EOF > /etc/anytls/config.json
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "anytls",
      "tag": "anytls-in",
      "listen": "::",
      "listen_port": $PORT,
      "users": [
        {
          "name": "user",
          "password": "$PASSWORD"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$DOMAIN",
        "certificate_path": "$CERT_PATH",
        "key_path": "$KEY_PATH"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF

    cat << EOF > /etc/systemd/system/anytls.service
[Unit]
Description=AnyTLS Server Service (Sing-box Core)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/etc/anytls
ExecStart=/usr/local/bin/anytls-server run -c /etc/anytls/config.json
Restart=on-failure
RestartSec=5s
LimitNOFILE=512000

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable anytls
    systemctl restart anytls
    
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}AnyTLS (Sing-box 核心) 安装成功!${NC}"
    view_config
    echo -e "${GREEN}========================================${NC}"
}

uninstall_anytls() {
    read -p "确认卸载 AnyTLS? (y/N): " CONFIRM
    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}正在卸载 AnyTLS...${NC}"
        systemctl stop anytls
        systemctl disable anytls
        rm -f /usr/local/bin/anytls-server
        rm -rf /etc/anytls
        rm -f /etc/systemd/system/anytls.service
        systemctl daemon-reload
        echo -e "${GREEN}卸载完成。${NC}"
    fi
}

check_update() {
    echo -e "${CYAN}--- 版本检查 ---${NC}"
    
    if [ -f "/usr/local/bin/anytls-server" ]; then
        LOCAL_VER=$(/usr/local/bin/anytls-server version | head -n 1 | awk '{print $3}')
        echo -e "当前本地 Sing-box 核心版本: ${LOCAL_VER:-未知}"
    else
        echo -e "${RED}未安装 AnyTLS (Sing-box 核心)。${NC}"
        LOCAL_VER="未知"
    fi
    
    echo -e "${YELLOW}正在获取 GitHub 最新版本信息...${NC}"
    
    LATEST_SB=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep '"tag_name":' | sed -E 's/.*"v?([^"]+)".*/\1/')
    echo -e "Sing-box GitHub 最新版本: ${LATEST_SB:-获取失败}"
    
    LATEST_ANYTLS=$(curl -s https://api.github.com/repos/anytls/anytls-rs/releases/latest | grep '"tag_name":' | sed -E 's/.*"v?([^"]+)".*/\1/')
    if [[ -z "$LATEST_ANYTLS" ]]; then
        LATEST_ANYTLS=$(curl -s https://api.github.com/repos/anytls/anytls-go/tags | grep '"name":' | head -n 1 | sed -E 's/.*"v?([^"]+)".*/\1/')
    fi
    echo -e "AnyTLS (官方协议库) GitHub 最新版本: ${LATEST_ANYTLS:-获取失败}"
    
    echo -e "${CYAN}----------------${NC}"
    
    if [[ "$LOCAL_VER" != "$LATEST_SB" && -n "$LATEST_SB" && "$LOCAL_VER" != "未知" ]]; then
        echo -e "${YELLOW}发现 Sing-box 核心新版本！${NC}"
        read -p "是否立即保留现有配置，执行核心覆盖更新？(y/N): " DO_UPDATE
        if [[ "$DO_UPDATE" =~ ^[Yy]$ ]]; then
            download_and_replace_core "$LATEST_SB"
            systemctl start anytls
            echo -e "${GREEN}核心更新成功！${NC}"
            view_config
        fi
    elif [[ "$LOCAL_VER" == "$LATEST_SB" ]]; then
        echo -e "${GREEN}当前核心已是最新版本，无需更新。${NC}"
    fi
}

while true; do
    clear
    echo -e "${GREEN}AnyTLS 高级服务端 一键管理脚本 (基于 Sing-box)${NC}"
    check_status
    echo "--------------------------------"
    echo "1. 安装 / 覆盖安装"
    echo "2. 卸载"
    echo "3. 重启服务"
    echo "4. 查看运行状态 (实时日志)"
    echo "5. 查看当前配置"
    echo "6. 修改端口和 Password"
    echo "7. 检查更新"
    echo "8. 退出"
    read -p "请选择 [1-8]: " opt

    echo -e "\n"
    case $opt in
        1) install_anytls ;;
        2) uninstall_anytls ;;
        3) systemctl restart anytls && echo -e "${GREEN}已重启${NC}" ;;
        4) 
           echo -e "${YELLOW}已打开日志分页查看模式，按 'q' 即可退出并返回菜单。${NC}"
           journalctl -u anytls -e 
           ;;
        5) view_config ;;
        6) modify_config ;;
        7) check_update ;;
        8) echo -e "${CYAN}已退出脚本。${NC}"; exit 0 ;;
        *) echo -e "${RED}无效选择。${NC}" ;;
    esac
    
    echo -e "\n"
    read -n 1 -s -r -p "按任意键返回主菜单..."
done
