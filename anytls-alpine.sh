#!/bin/bash
# 适用环境: Alpine Linux (NAT)
# 核心程序: sing-box (AnyTLS)

# --- 变量定义 ---
SCRIPT_URL="https://raw.githubusercontent.com/hhlli/Proxy-Scripts/main/anytls-alpine.sh"
CONF_DIR="/etc/sing-box"
BIN_PATH="/usr/local/bin/sing-box"
SVC_FILE="/etc/init.d/sing-box"
LOG_FILE="/var/log/sing-box.log"
ACME_SH="$HOME/.acme.sh/acme.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# --- 基础检测 ---
if [ "$(id -u)" != "0" ]; then
    echo -e "${RED}错误: 必须使用 root 用户运行此脚本。${PLAIN}"
    exit 1
fi

if [ ! -f "/etc/alpine-release" ]; then
    echo -e "${RED}错误: 当前系统不是 Alpine Linux。${PLAIN}"
    exit 1
fi

# --- 依赖安装 ---
install_dependencies() {
    echo -e "${GREEN}检查并安装基础依赖...${PLAIN}"
    apk add --no-cache bash curl jq openssl socat tzdata tzdata-posix
}

# --- 核心组件 ---
get_latest_version() {
    curl -s "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | jq -r .tag_name | sed 's/v//g'
}

install_sing_box() {
    local version=$(get_latest_version)
    if [ -z "$version" ]; then
        echo -e "${RED}获取 sing-box 最新版本失败，请检查网络。${PLAIN}"
        return 1
    fi
    echo -e "${GREEN}正在下载 sing-box v${version}...${PLAIN}"
    
    local arch
    case "$(uname -m)" in
        x86_64) arch="amd64" ;;
        aarch64) arch="arm64" ;;
        *) echo -e "${RED}不支持的架构: $(uname -m)${PLAIN}"; exit 1 ;;
    esac

    local file_name="sing-box-${version}-linux-${arch}"
    local download_url="https://github.com/SagerNet/sing-box/releases/download/v${version}/${file_name}.tar.gz"
    
    curl -L -o /tmp/sing-box.tar.gz "$download_url"
    tar -xzf /tmp/sing-box.tar.gz -C /tmp/
    mv "/tmp/${file_name}/sing-box" "$BIN_PATH"
    chmod +x "$BIN_PATH"
    rm -rf /tmp/sing-box.tar.gz "/tmp/${file_name}"
    echo -e "${GREEN}sing-box 安装/更新完成。${PLAIN}"
}

configure_service() {
    cat > "$SVC_FILE" <<-EOF
#!/sbin/openrc-run
name="sing-box"
description="sing-box anytls service"
command="$BIN_PATH"
command_args="run -c $CONF_DIR/config.json"
command_background="yes"
pidfile="/run/sing-box.pid"
output_log="$LOG_FILE"
error_log="$LOG_FILE"

depend() {
    need net
    after network
}
EOF
    chmod +x "$SVC_FILE"
    rc-update add sing-box default >/dev/null 2>&1
}

# --- 证书申请 ---
issue_cert() {
    local domain=$1
    if [ ! -f "$ACME_SH" ]; then
        echo -e "${GREEN}安装 acme.sh...${PLAIN}"
        curl https://get.acme.sh | sh -s
        $ACME_SH --set-default-ca --server letsencrypt
    fi

    if $ACME_SH --list | grep -q "$domain"; then
        echo -e "${GREEN}检测到域名 $domain 的证书已存在，尝试复用...${PLAIN}"
    else
        echo -e "${YELLOW}未检测到可用证书，开始申请...${PLAIN}"
        
        read -p "请输入 CF_Token (Cloudflare API Token): " cf_token
        read -p "请输入 CF_Account_ID (Cloudflare Account ID): " cf_account_id
        
        export CF_Token="$cf_token"
        export CF_Account_ID="$cf_account_id"
        
        $ACME_SH --register-account -m "" --server letsencrypt >/dev/null 2>&1
        
        $ACME_SH --issue --dns dns_cf -d "$domain"
        if [ $? -ne 0 ]; then
            echo -e "${RED}证书申请失败，请检查 API Token、Account ID 或 DNS 设置。${PLAIN}"
            exit 1
        fi
    fi

    mkdir -p "$CONF_DIR/certs"
    $ACME_SH --install-cert -d "$domain" \
        --key-file "$CONF_DIR/certs/private.key" \
        --fullchain-file "$CONF_DIR/certs/cert.cer"
    
    if [ ! -f "$CONF_DIR/certs/cert.cer" ]; then
        echo -e "${RED}证书安装到指定目录失败。${PLAIN}"
        exit 1
    fi
}

# --- 主功能模块 ---
install_or_reconfig() {
    local is_running=0
    if rc-service sing-box status 2>/dev/null | grep -q 'started'; then 
        is_running=1
    elif pgrep -f "sing-box run" > /dev/null; then 
        is_running=1
    fi
    
    if [ $is_running -eq 1 ]; then
        echo -e "${YELLOW}警告: 检测到 AnyTLS (sing-box) 服务当前正在运行。${PLAIN}"
        read -p "继续执行将覆盖现有配置，是否继续？[y/N]: " confirm
        if [[ "${confirm,,}" != "y" ]]; then
            echo "已取消安装/重新配置。"
            return
        fi
        rc-service sing-box stop >/dev/null 2>&1
    fi

    install_dependencies
    
    read -p "请输入需要解析的域名 (如: anytls.example.com): " domain
    if [ -z "$domain" ]; then echo "域名不能为空"; exit 1; fi
    
    issue_cert "$domain"
    
    read -p "请输入监听/外部端口 [直接回车默认 8443]: " port
    port=${port:-8443}
    
    if netstat -tuln | grep -Eq ":$port\b"; then
        local port_pid=$(netstat -tulnp 2>/dev/null | grep -E ":$port\b" | awk '{print $7}' | cut -d'/' -f1)
        echo -e "${RED}错误: 端口 $port 已被系统其他进程 (PID: $port_pid) 占用，请更换端口。${PLAIN}"
        exit 1
    fi
    
    read -p "请输入 AnyTLS 密码 [直接回车随机生成]: " password
    if [ -z "$password" ]; then
        password=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
        echo -e "已生成随机密码: ${GREEN}${password}${PLAIN}"
    fi

    if [ ! -f "$BIN_PATH" ]; then
        install_sing_box
    fi

    cat > "$CONF_DIR/config.json" <<-EOF
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
      "listen_port": $port,
      "users": [
        {
          "password": "$password"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$domain",
        "certificate_path": "$CONF_DIR/certs/cert.cer",
        "key_path": "$CONF_DIR/certs/private.key"
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

    configure_service
    rc-service sing-box start
    
    sleep 1
    if rc-service sing-box status 2>/dev/null | grep -q 'started'; then
        echo -e "\n${GREEN}=== 安装/重新配置完成 ===${PLAIN}"
        print_nodes "$domain" "$port" "$password"
    else
        echo -e "\n${RED}服务启动失败，请使用菜单 5 查看日志排查原因。${PLAIN}"
    fi
}

update_core() {
    echo -e "${GREEN}开始更新 sing-box 核心...${PLAIN}"
    rc-service sing-box stop >/dev/null 2>&1
    install_sing_box
    rc-service sing-box start
    echo -e "${GREEN}核心更新完成并已重启服务。${PLAIN}"
}

uninstall_service() {
    echo -e "${YELLOW}正在卸载服务...${PLAIN}"
    rc-service sing-box stop >/dev/null 2>&1
    rc-update del sing-box default >/dev/null 2>&1
    
    rm -f "$SVC_FILE"
    rm -f "$BIN_PATH"
    rm -f "$CONF_DIR/config.json"
    rm -f "$LOG_FILE"
    
    echo -e "${GREEN}卸载完成。核心程序、服务和配置文件已删除。${PLAIN}"
    echo -e "注: 已保留 acme.sh 及证书文件在 ${CONF_DIR}/certs 目录下。"
}

restart_service() {
    rc-service sing-box restart
    echo -e "${GREEN}服务已重启。${PLAIN}"
}

view_status() {
    rc-service sing-box status
    echo -e "${YELLOW}实时日志 (按 Ctrl+C 退出):${PLAIN}"
    tail -f "$LOG_FILE"
}

print_nodes() {
    local d=$1 p=$2 pwd=$3
    echo -e "\n${YELLOW}--- 客户端配置 ---${PLAIN}"
    echo -e "Surge 节点配置:"
    echo -e "\033[0;36mAnyTLS_Node = anytls, ${d}, ${p}, password=${pwd}\033[0m\n"
    echo -e "Loon 节点配置:"
    echo -e "\033[0;36mAnyTLS_Node = AnyTLS,${d},${p},\"${pwd}\",sni=${d}\033[0m"
    echo -e "${YELLOW}------------------${PLAIN}\n"
}

view_config() {
    if [ ! -f "$CONF_DIR/config.json" ]; then
        echo -e "${RED}配置文件不存在，请先安装。${PLAIN}"
        return
    fi
    
    local port=$(jq -r '.inbounds[0].listen_port' "$CONF_DIR/config.json")
    local pwd=$(jq -r '.inbounds[0].users[0].password' "$CONF_DIR/config.json")
    local domain=$(jq -r '.inbounds[0].tls.server_name' "$CONF_DIR/config.json")
    local status=$(rc-service sing-box status | grep -o 'started\|stopped\|crashed')
    local ver=$($BIN_PATH version 2>/dev/null | head -n 1)

    echo -e "\n${GREEN}=== 当前状态信息 ===${PLAIN}"
    echo -e "运行状态: ${status:-未知}"
    echo -e "核心版本: ${ver:-未安装}"
    echo -e "证书路径: $CONF_DIR/certs"
    
    print_nodes "$domain" "$port" "$pwd"
}

check_script_update() {
    echo -e "${GREEN}检查脚本更新...${PLAIN}"
    local temp_file="/tmp/anytls_script_update.sh"
    curl -sL "$SCRIPT_URL" -o "$temp_file"
    if [ -f "$temp_file" ] && grep -q "sing-box AnyTLS" "$temp_file"; then
        mv "$temp_file" "$0"
        chmod +x "$0"
        echo -e "${GREEN}脚本更新成功，请重新运行脚本。${PLAIN}"
        exit 0
    else
        echo -e "${RED}获取最新脚本失败，或仓库文件不存在。${PLAIN}"
        rm -f "$temp_file"
    fi
}

# --- 菜单界面 ---
show_menu() {
    echo -e "\n${GREEN}=== Alpine NAT AnyTLS 管理脚本 ===${PLAIN}"
    echo -e "1. 安装 / 重新配置"
    echo -e "2. 更新核心程序 (保留配置)"
    echo -e "3. 卸载"
    echo -e "4. 重启服务"
    echo -e "5. 查看运行状态 (实时日志)"
    echo -e "6. 查看当前配置"
    echo -e "7. 检查脚本更新"
    echo -e "8. 退出"
    echo -e "=================================="
}

while true; do
    show_menu
    read -p "请输入选项 [1-8]: " choice
    case "$choice" in
        1) install_or_reconfig ;;
        2) update_core ;;
        3) uninstall_service ;;
        4) restart_service ;;
        5) view_status ;;
        6) view_config ;;
        7) check_script_update ;;
        8) exit 0 ;;
        *) echo -e "${RED}无效选项，请重新输入。${PLAIN}" ;;
    esac
done
