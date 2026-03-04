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

# 安装功能
install_hy2() {
    # 交互式获取参数
    read -p "设置域名 (如 dc1.767667.xyz): " DOMAIN
    read -p "设置端口 (默认 443): " PORT
    PORT=${PORT:-443}
    read -p "设置连接密码: " PASSWORD
    
    # 1. 环境准备与核心安装
    apt update && apt install -y curl socat
    bash <(curl -fsSL https://get.hy2.sh/)
    
    # 2. 证书申请 (使用本地独立脚本路径确保变量生效)
    if [ ! -f "$HOME/.acme.sh/acme.sh" ]; then
        curl https://get.acme.sh | sh -s email=admin@$DOMAIN
    fi
    
    # 强制加载环境变量
    source ~/.bashrc
    ~/.acme.sh/acme.sh --upgrade --auto-upgrade
    ~/.acme.sh/acme.sh --issue -d $DOMAIN --standalone --force

    # 3. 部署证书
    mkdir -p /etc/hysteria/certs
    ~/.acme.sh/acme.sh --install-cert -d $DOMAIN \
        --key-file /etc/hysteria/certs/server.key \
        --fullchain-file /etc/hysteria/certs/server.crt

    # 4. 关键修正：生成配置 (确保变量被解析)
    # 使用无引号的 EOF 确保 $PORT, $PASSWORD 等变量被替换为实际输入值
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

    # 5. 权限与服务启动
    chown -R hysteria:hysteria /etc/hysteria/certs
    systemctl enable --now hysteria-server
    systemctl restart hysteria-server
    
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}安装成功!${NC}"
    echo -e "域名: ${YELLOW}$DOMAIN${NC}"
    echo -e "端口: ${YELLOW}$PORT${NC}"
    echo -e "密码: ${YELLOW}$PASSWORD${NC}"
    echo -e "----------------------------------------"
    echo -e "Surge 配置行:"
    echo -e "${GREEN}Hy2-Node = hysteria2, $DOMAIN, $PORT, password=$PASSWORD, sni=$DOMAIN${NC}"
    echo -e "${GREEN}========================================${NC}"
}

# 卸载功能
uninstall_hy2() {
    echo -e "${YELLOW}正在清理 Hysteria 2...${NC}"
    systemctl stop hysteria-server
    systemctl disable hysteria-server
    rm -rf /etc/hysteria
    rm -f /usr/local/bin/hysteria
    rm -f /etc/systemd/system/hysteria-server.service
    echo -e "${GREEN}卸载完成。${NC}"
}

# 主菜单
clear
echo -e "${GREEN}Hysteria 2 一键管理脚本 (2026 修正版)${NC}"
check_status
echo "--------------------------------"
echo "1. 安装 / 覆盖安装"
echo "2. 卸载"
echo "3. 重启服务"
echo "4. 查看实时日志 (排障必备)"
echo "5. 退出"
read -p "请选择 [1-5]: " opt

case $opt in
    1) install_hy2 ;;
    2) uninstall_hy2 ;;
    3) systemctl restart hysteria-server && echo -e "${GREEN}已重启${NC}" ;;
    4) journalctl -u hysteria-server -f ;;
    *) exit 0 ;;
esac
