set -euo pipefail

VERSION='Sing-box Installer Pure'
GITHUB_PROXY=('' 'https://raw.githubusercontent.com' 'https://ghproxy.net/https://raw.githubusercontent.com')
GH_PROXY=''
TEMP_DIR='/tmp/proxyinstaller'
WORK_DIR='/etc/sing-box'
LOG_DIR="${WORK_DIR}/logs"
CONF_DIR="${WORK_DIR}/conf"
DEFAULT_PORT_REALITY=$((RANDOM%50000+10000))
DEFAULT_PORT_WS=$((RANDOM%50000+10000))
DEFAULT_PORT_SS=$((RANDOM%50000+10000))
TLS_SERVER_DEFAULT='addons.mozilla.org'
DEFAULT_NEWEST_VERSION='1.10.0'

export PATH=$PATH:/usr/local/bin
mkdir -p "$WORK_DIR" "$CONF_DIR" "$LOG_DIR" "$TEMP_DIR"

ok() { echo -e "\033[32m[√] $1\033[0m"; }
warn() { echo -e "\033[33m[!] $1\033[0m"; }
err() { echo -e "\033[31m[×] $1\033[0m"; exit 1; }

need_root() {
  [ "$(id -u)" != "0" ] && err "请使用 root 权限运行"
}

detect_arch() {
  arch=$(uname -m)
  case $arch in
    x86_64|amd64) SB_ARCH="amd64" ;;
    aarch64|arm64) SB_ARCH="arm64" ;;
    armv7|armv7l) SB_ARCH="armv7" ;;
    *) err "不支持的架构: $arch" ;;
  esac
}

detect_os() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
  fi
}

install_deps() {
  if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
    apt update >/dev/null 2>&1
    apt install -y wget curl jq qrencode tar >/dev/null 2>&1
  elif [[ "$OS" == "centos" || "$OS" == "rhel" ]]; then
    yum install -y wget curl jq qrencode tar >/dev/null 2>&1
  fi
}

get_latest_version() {
  latest=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name | sed 's/v//g')
  [ -z "$latest" ] && echo "$DEFAULT_NEWEST_VERSION" || echo "$latest"
}

download_singbox() {
  ver=$(get_latest_version)
  url="https://github.com/SagerNet/sing-box/releases/download/v${ver}/sing-box-${ver}-linux-${SB_ARCH}.tar.gz"
  wget -q -O "$TEMP_DIR/sing-box.tar.gz" "$url" || err "下载失败"
  tar -xf "$TEMP_DIR/sing-box.tar.gz" -C "$TEMP_DIR"
  mv -f "$TEMP_DIR"/sing-box-*/sing-box /usr/local/bin/
  chmod +x /usr/local/bin/sing-box
}

install_vless() {
  uuid=$(cat /proc/sys/kernel/random/uuid)
  port=$((RANDOM%50000+10000))
  cat > "$CONF_DIR/config.json" << EOF
{
  "log": {"level": "info"},
  "inbounds": [
    {
      "type": "vless",
      "listen": "::",
      "listen_port": $port,
      "users": [{"uuid": "$uuid"}],
      "tls": {
        "enabled": true,
        "server_name": "$TLS_SERVER_DEFAULT",
        "reality": {
          "enabled": true,
          "handshake": {"server": "$TLS_SERVER_DEFAULT","server_port": 443}
        }
      }
    }
  ],
  "outbounds": [{"type": "direct"}]
}
EOF
  ok "VLESS 安装成功"
  ok "端口: $port"
  ok "UUID: $uuid"
  qrencode -t ansi "vless://${uuid}@$(curl -s ip.sb):${port}?security=reality&sni=${TLS_SERVER_DEFAULT}&fp=chrome#VLESS"
}

show_menu() {
  echo "====================================="
  echo "        Sing-box 一键管理脚本        "
  echo "====================================="
  echo "1. 安装 VLESS Reality"
  echo "2. 安装 VMess WS"
  echo "3. 安装 Shadowsocks"
  echo "4. 查看配置"
  echo "5. 重启服务"
  echo "6. 卸载"
  echo "7. 退出"
  echo "====================================="
  read -p "请输入选项: " opt
  case $opt in
    1) install_vless ;;
    7) exit 0 ;;
    *) warn "输入错误" && show_menu ;;
  esac
}

need_root
detect_arch
detect_os
install_deps
download_singbox
show_menu
