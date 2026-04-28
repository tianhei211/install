set -euo pipefail

VERSION='Proxy Installer v1.1-Fix'
GITHUB_PROXY=('' 'https://v6.gh-proxy.org/' 'https://gh-proxy.com/' 'https://hub.glowp.xyz/' 'https://proxy.vvvv.ee/' 'https://ghproxy.lvedong.eu.org/')
GH_PROXY=''
TEMP_DIR='/tmp/proxyinstaller'
WORK_DIR='/etc/sing-box'
LOG_DIR="${WORK_DIR}/logs"
CONF_DIR="${WORK_DIR}/conf"
DEFAULT_PORT_REALITY=$((RANDOM % 50001 + 10000))
DEFAULT_PORT_WS=$((RANDOM % 50001 + 10000))
DEFAULT_PORT_SS=$((RANDOM % 50001 + 10000))
TLS_SERVER_DEFAULT='addons.mozilla.org'
DEFAULT_NEWEST_VERSION='1.13.0-rc.4'
export DEBIAN_FRONTEND=noninteractive

trap 'rm -rf "$TEMP_DIR" >/dev/null 2>&1 || true' EXIT
mkdir -p "$TEMP_DIR" "$WORK_DIR" "$CONF_DIR" "$LOG_DIR"

ok()     { echo -e "\033[32m\033[01m$*\033[0m"; }
warn()   { echo -e "\033[33m\033[01m$*\033[0m"; }
err()    { echo -e "\033[31m\033[01m$*\033[0m" >&2; }

ESC=$(printf '\033')
YELLOW="${ESC}[33m"
GREEN="${ESC}[32m"
RED="${ESC}[31m"
RESET="${ESC}[0m"
die()    { err "$*"; exit 1; }

need_root() { [ "$(id -u)" -eq 0 ] || die "请使用 root 运行。"; }

detect_arch() {
  case "$(uname -m)" in
    aarch64|arm64)  SB_ARCH=arm64 ;;
    x86_64|amd64)   SB_ARCH=amd64 ;;
    armv7l)         SB_ARCH=armv7 ;;
    *) die "不支持的架构: $(uname -m)" ;;
  esac
}

detect_os() {
  local pretty=""
  [ -s /etc/os-release ] && pretty="$(. /etc/os-release; echo "$PRETTY_NAME")"
  case "$pretty" in
    *Debian*|*Ubuntu*)  OS_FAMILY="Debian"; PKG_INSTALL="apt -y install";;
    *CentOS*|*Rocky*|*Alma*|*Red\ Hat*) OS_FAMILY="CentOS"; PKG_INSTALL="yum -y install";;
    *Fedora*)           OS_FAMILY="Fedora"; PKG_INSTALL="dnf -y install";;
    *Alpine*)           OS_FAMILY="Alpine"; PKG_INSTALL="apk add --no-cache";;
    *Arch*)             OS_FAMILY="Arch";   PKG_INSTALL="pacman -S --noconfirm";;
    *) die "不支持的系统: $pretty" ;;
  esac
}

install_deps() {
  if command -v apt >/dev/null 2>&1; then
    sed -i 's|http://|https://|g' /etc/apt/sources.list 2>/dev/null || true
    [ -d /etc/apt/sources.list.d ] && find /etc/apt/sources.list.d -name "*.list" -exec sed -i 's|http://|https://|g' {} \; 2>/dev/null || true
  fi
  local deps=(wget curl jq tar openssl)
  for d in "${deps[@]}"; do
    if ! command -v "$d" >/dev/null 2>&1; then
      ok "安装依赖: $d"
      $PKG_INSTALL "$d" || die "安装 $d 失败"
    fi
  done
}

sync_system_time() {
  ok "尝试同步系统时间..."
  command -v timedatectl >/dev/null 2>&1 && timedatectl set-ntp true >/dev/null 2>&1
  if command -v systemctl >/dev/null 2>&1; then
    systemctl restart systemd-timesyncd chronyd chrony 2>/dev/null || true
  fi
  command -v chronyc >/dev/null 2>&1 && chronyc -a makestep 2>/dev/null || true
  command -v ntpdate >/dev/null 2>&1 && ntpdate -u time.google.com 2>/dev/null || true
  sleep 1
}

check_cdn() {
  for PROXY_URL in "${GITHUB_PROXY[@]}"; do
    local code
    code=$(wget --spider --quiet --timeout=3 --tries=1 -S "${PROXY_URL}https://api.github.com" 2>&1 | awk '/HTTP\//{print $2;exit}')
    [ "$code" = "200" ] && GH_PROXY="$PROXY_URL" && break
  done
}

get_latest_version() {
  check_cdn
  local FORCE_VERSION
  FORCE_VERSION=$(wget -qT3 -t2 -O- "${GH_PROXY}https://raw.githubusercontent.com/fscarmen/sing-box/refs/heads/main/force_version" 2>/dev/null | sed 's/^[vV]//;s/\r//g')
  if [[ "$FORCE_VERSION" == *.* ]]; then
    echo "$FORCE_VERSION"
    return
  fi
  local api_ret
  api_ret=$(wget -qT3 -t2 -S -O- "${GH_PROXY}https://api.github.com/repos/SagerNet/sing-box/releases" 2>&1)
  if echo "$api_ret" | grep -q "200"; then
    echo "$api_ret" | jq -r '.[0].tag_name' | sed 's/^v//'
  else
    echo "$DEFAULT_NEWEST_VERSION"
  fi
}

# 通用空闲端口检测 兼容无ss环境
find_free_port() {
  local port="$1"
  while true; do
    if command -v ss >/dev/null 2>&1; then
      ! ss -tuln | grep -q ":${port} "
    else
      ! grep -q ":$(printf %04X "$port") " /proc/net/tcp 2>/dev/null
    fi
    if [ $? -eq 0 ]; then
      break
    fi
    port=$((port+1))
    [ "$port" -gt 65535 ] && port=10000
  done
  echo "$port"
}

ensure_singbox() {
  [ -x "${WORK_DIR}/sing-box" ] && return
  check_cdn
  local ver=$(get_latest_version)
  ok "下载 sing-box v${ver} (${SB_ARCH})"
  local url="https://github.com/SagerNet/sing-box/releases/download/v${ver}/sing-box-${ver}-linux-${SB_ARCH}.tar.gz"
  local tar="${TEMP_DIR}/sb.tar.gz"
  if [ -n "$GH_PROXY" ]; then
    wget -qT30 -t2 -O "$tar" "${GH_PROXY}${url}" || { warn "代理失败，直连下载"; wget -qT30 -t2 -O "$tar" "$url" || die "下载失败"; }
  else
    wget -qT30 -t2 -O "$tar" "$url" || die "下载失败"
  fi
  [ -s "$tar" ] || die "下载文件为空"
  tar xzf "$tar" -C "$TEMP_DIR"
  mv "$TEMP_DIR"/sing-box-${ver}-linux-${SB_ARCH}/sing-box "${WORK_DIR}/"
  chmod +x "${WORK_DIR}/sing-box"
  rm -f "$tar"
}

ensure_qrencode() {
  command -v qrencode >/dev/null 2>&1 && return 0
  ok "安装二维码工具 qrencode"
  local log="/tmp/qr.log"
  if command -v apt >/dev/null 2>&1; then
    if ! apt install -y qrencode >"$log" 2>&1; then
      apt update >"$log" 2>&1 || { sync_system_time; apt update >"$log" 2>&1; }
      apt install -y qrencode >"$log" 2>&1 || { warn "qrencode 安装失败，跳过二维码"; return 1; }
    fi
  fi
}

ensure_systemd_service() {
  if [ -f /etc/init.d/sing-box ] && ! command -v systemctl >/dev/null 2>&1; then
    cat > /etc/init.d/sing-box <<'EOF'
#!/sbin/openrc-run
name="sing-box"
command="/etc/sing-box/sing-box"
command_args="run -c /etc/sing-box/config.json"
command_background="yes"
pidfile="/var/run/${RC_SVCNAME}.pid"
output_log="/etc/sing-box/logs/sing-box.log"
error_log="/etc/sing-box/logs/sing-box.log"
depend() { need net; after net; }
start_pre() { mkdir -p /etc/sing-box/logs /var/run; rm -f "$pidfile"; }
EOF
    chmod +x /etc/init.d/sing-box
    rc-update add sing-box default >/dev/null 2>&1 || true
  else
    cat > /etc/systemd/system/sing-box.service <<'EOF'
[Unit]
Description=Sing-box Service
After=network.target

[Service]
User=root
Type=simple
WorkingDirectory=/etc/sing-box
ExecStart=/etc/sing-box/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable sing-box >/dev/null 2>&1 || true
  fi
}

svc_restart() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl restart sing-box
    sleep 1
    systemctl is-active --quiet sing-box || { sleep 2; systemctl is-active --quiet sing-box; }
    systemctl is-active --quiet sing-box && ok "服务启动成功" || die "服务启动失败，日志：tail -n 200 ${LOG_DIR}/sing-box.log"
  else
    rc-service sing-box restart
  fi
}

auto_cleanup_old_configs() {
  local keep=("00_base.json" "10_vless_tcp_reality.json" "12_ss.json" "13_vmess_ws.json")
  for f in "$CONF_DIR"/*.json; do
    local bn=$(basename "$f")
    local del=1
    for k in "${keep[@]}"; do [ "$bn" = "$k" ] && del=0; done
    [ $del -eq 1 ] && rm -f "$f"
  done
}

merge_config() {
  local base="${CONF_DIR}/00_base.json"
  if [ ! -f "$base" ]; then
    cat > "$base" <<EOF
{
  "log": {"disabled":false,"level":"info","output":"${LOG_DIR}/sing-box.log","timestamp":true},
  "dns":{"servers":[{"type":"local"}],"strategy":"prefer_ipv4"},
  "outbounds":[{"type":"direct","tag":"direct"}]
}
EOF
  fi
  jq -s '
    def pick(k): (map(select(.[k]!=null)) | last?.[k]) // null;
    def arr(k): (map(.[k]//[]) | add);
    {log:pick("log"),dns:pick("dns"),ntp:pick("ntp"),outbounds:arr("outbounds"),inbounds:arr("inbounds")}
  ' "$CONF_DIR"/*.json > "$WORK_DIR/config.json.tmp"
  if jq . "$WORK_DIR/config.json.tmp" >/dev/null 2>&1; then
    mv "$WORK_DIR/config.json.tmp" "$WORK_DIR/config.json"
  else
    rm -f "$WORK_DIR/config.json.tmp"
    warn "配置合并异常，保留上一次有效配置"
  fi
}

read_ip_default() {
  SERVER_IP=$(curl -sL --max-time 5 https://api.ipify.org || curl -sL --max-time 5 https://ifconfig.me || echo "127.0.0.1")
  ok "检测公网IP: ${SERVER_IP}"
}

read_uuid() {
  UUID=$(cat /proc/sys/kernel/random/uuid)
  ok "已生成 UUID: ${UUID}"
}

read_port() {
  local hint="$1" def="$2"
  read -rp "$hint [默认:$def]： " PORT
  PORT="${PORT:-$def}"
  [[ "$PORT" =~ ^[0-9]+$ ]] || die "端口必须为数字"
  ((PORT>=100 && PORT<=65535)) || die "端口范围 100-65535"
}

# 生成随机 Reality short_id
rand_short_id() {
  head -c8 /dev/urandom | xxd -p | head -c$((RANDOM%9+6))
}

enable_bbr() {
  ok "配置 BBR 拥塞控制"
  modprobe tcp_bbr 2>/dev/null || true
  sed -i '/^net.core.default_qdisc/d;/^net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
  echo -e "net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
  sysctl -p >/dev/null 2>&1
  ok "BBR 配置完成"
}

install_vless_tcp_reality() {
  rm -f "${CONF_DIR}/10_vless_tcp_reality.json"
  ensure_singbox
  ensure_systemd_service
  merge_config
  ok "开始安装 VLESS+TCP+Reality"
  read_ip_default
  read_uuid
  read -rp "Reality SNI域名 [默认:${TLS_SERVER_DEFAULT}]： " TLS_DOMAIN
  TLS_DOMAIN="${TLS_DOMAIN:-$TLS_SERVER_DEFAULT}"
  DEFAULT_PORT_REALITY=$(find_free_port "$DEFAULT_PORT_REALITY")
  read_port "监听端口" "$DEFAULT_PORT_REALITY"
  PORT=$(find_free_port "$PORT")
  enable_bbr
  local kp priv pub sid
  kp="$("${WORK_DIR}/sing-box" generate reality-keypair)"
  priv=$(awk '/PrivateKey/{print $NF}' <<<"$kp")
  pub=$(awk '/PublicKey/{print $NF}' <<<"$kp")
  sid=$(rand_short_id)
  echo "$priv" > "${CONF_DIR}/reality_private.key"
  echo "$pub"  > "${CONF_DIR}/reality_public.key"
  cat > "${CONF_DIR}/10_vless_tcp_reality.json" <<EOF
{"inbounds":[{"type":"vless","tag":"vless-reality","listen":"::","listen_port":${PORT},"users":[{"uuid":"${UUID}"}],"tls":{"enabled":true,"server_name":"${TLS_DOMAIN}","reality":{"enabled":true,"handshake":{"server":"${TLS_DOMAIN}","server_port":443},"private_key":"${priv}","short_id":["${sid}"]}}}]}}
EOF
  merge_config
  svc_restart
  ok "✅ VLESS+Reality 安装完成"
  ensure_qrencode
  local link="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&security=reality&sni=${TLS_DOMAIN}&fp=chrome&pbk=${pub}&type=tcp#VLESS-REALITY"
  echo -e "\n导入链接：\n${YELLOW}${link}${RESET}\n"
  if command -v qrencode >/dev/null 2>&1; then qrencode -t ANSIUTF8 -m1 -s1 "$link"; fi
  echo -e "\n重新管理请输入：${YELLOW}menu${RESET}"
}

install_vmess_ws() {
  rm -f "${CONF_DIR}/13_vmess_ws.json"
  ensure_singbox
  ensure_systemd_service
  merge_config
  ok "开始安装 VMESS+WS"
  read_ip_default
  read_uuid
  DEFAULT_PORT_WS=$(find_free_port "$DEFAULT_PORT_WS")
  read_port "监听端口" "$DEFAULT_PORT_WS"
  PORT=$(find_free_port "$PORT")
  enable_bbr
  local path="/${UUID}-vmess"
  cat > "${CONF_DIR}/13_vmess_ws.json" <<EOF
{"inbounds":[{"type":"vmess","tag":"vmess-ws","listen":"::","listen_port":${PORT},"users":[{"uuid":"${UUID}"}],"transport":{"type":"ws","path":"${path}"}}]}
EOF
  merge_config
  svc_restart
  ok "✅ VMESS+WS 安装完成"
  ensure_qrencode
  local json_str=$(printf '{"v":"2","ps":"VMESS-WS","add":"%s","port":"%s","id":"%s","aid":"0","net":"ws","type":"none","path":"%s"}' "$SERVER_IP" "$PORT" "$UUID" "$path")
  local b64=$(echo -n "$json_str" | base64 -w0)
  local link="vmess://${b64}"
  echo -e "\n导入链接：\n${YELLOW}${link}${RESET}\n"
  if command -v qrencode >/dev/null 2>&1; then qrencode -t ANSIUTF8 -m1 -s1 "$link"; fi
  echo -e "\n重新管理请输入：${YELLOW}menu${RESET}"
}

install_shadowsocks() {
  rm -f "${CONF_DIR}/12_ss.json"
  ensure_singbox
  ensure_systemd_service
  merge_config
  ok "开始安装 Shadowsocks"
  read_ip_default
  SS_PASS=$(cat /proc/sys/kernel/random/uuid)
  ok "自动生成密码: ${SS_PASS}"
  DEFAULT_PORT_SS=$(find_free_port "$DEFAULT_PORT_SS")
  read_port "监听端口" "$DEFAULT_PORT_SS"
  PORT=$(find_free_port "$PORT")
  enable_bbr
  local method="aes-128-gcm"
  cat > "${CONF_DIR}/12_ss.json" <<EOF
{"inbounds":[{"type":"shadowsocks","tag":"shadowsocks","listen":"::","listen_port":${PORT},"method":"${method}","password":"${SS_PASS}"}]}
EOF
  merge_config
  svc_restart
  ok "✅ Shadowsocks 安装完成"
  ensure_qrencode
  local b64=$(printf '%s:%s@%s:%s' "$method" "$SS_PASS" "$SERVER_IP" "$PORT" | base64 -w0)
  local link="ss://${b64}#Shadowsocks"
  echo -e "\n导入链接：\n${YELLOW}${link}${RESET}\n"
  if command -v qrencode >/dev/null 2>&1; then qrencode -t ANSIUTF8 -m1 -s1 "$link"; fi
  echo -e "\n重新管理请输入：${YELLOW}menu${RESET}"
}

change_port() {
  echo "1.VLESS-Reality  2.VMESS-WS  3.Shadowsocks"
  read -rp "选择修改项 1/2/3：" w
  local file
  case $w in 1)file="${CONF_DIR}/10_vless_tcp_reality.json";;2)file="${CONF_DIR}/13_vmess_ws.json";;3)file="${CONF_DIR}/12_ss.json";;*)die "无效选择";;esac
  [ -f "$file" ] || die "未安装该协议"
  local sp=$((RANDOM%50001+10000))
  sp=$(find_free_port "$sp")
  read_port "新端口" "$sp"
  PORT=$(find_free_port "$PORT")
  jq --argjson p "$PORT" '(..|objects|select(has("listen_port"))).listen_port=$p' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
  merge_config
  svc_restart
  ok "端口修改成功：${PORT}"
}

change_user_cred() {
  echo "1.修改VLESS全部UUID  2.修改SS密码"
  read -rp "选择 1/2：" w
  case $w in
  1)
    read_uuid
    for f in "${CONF_DIR}/10_vless_tcp_reality.json" "${CONF_DIR}/13_vmess_ws.json"; do
      [ -f "$f" ] && jq --arg u "$UUID" '(..|users[]?|select(has("uuid"))).uuid=$u' "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"
    done
    merge_config;svc_restart;ok "UUID 修改完成"
    ;;
  2)
    local f="${CONF_DIR}/12_ss.json"
    [ -f "$f" ] || die "未安装SS"
    read -rp "新密码：" pwd; [ -n "$pwd" ] || die "密码不能为空"
    jq --arg p "$pwd" '(..|objects|select(has("password"))).password=$p' "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"
    merge_config;svc_restart;ok "SS密码 修改完成"
    ;;
  *)die "无效选择";;
  esac
}

uninstall_all() {
  warn "即将卸载 sing-box 全部文件与服务"
  read -rp "确认 y/N：" y
  [[ "${y,,}" == "y" ]] || { echo "已取消";return; }
  if command -v systemctl >/dev/null 2>&1; then
    systemctl stop sing-box 2>/dev/null||true
    systemctl disable sing-box 2>/dev/null||true
    rm -f /etc/systemd/system/sing-box.service
    systemctl daemon-reload
  else
    rc-service sing-box stop 2>/dev/null||true
    rc-update del sing-box default 2>/dev/null||true
    rm -f /etc/init.d/sing-box
  fi
  rm -rf "$WORK_DIR"
  ok "卸载完成"
}

show_generated_links() {
  echo -e "\n==================== 节点链接 ====================\n"
  ensure_qrencode
  local any=0
  local ip=$(curl -s --max-time 3 https://api.ip.sb/ip || echo "YOUR_IP")

  local f1="${CONF_DIR}/10_vless_tcp_reality.json"
  if [ -f "$f1" ];then
    any=1
    local uuid=$(jq -r '..|users[]?.uuid' "$f1"|head -n1)
    local port=$(jq -r '..|listen_port' "$f1"|head -n1)
    local sni=$(jq -r '..|server_name' "$f1"|head -n1)
    local pub=$(cat "${CONF_DIR}/reality_public.key" 2>/dev/null||"")
    local link="vless://${uuid}@${ip}:${port}?encryption=none&security=reality&sni=${sni}&fp=chrome&pbk=${pub}&type=tcp#VLESS"
    echo -e "🔹 VLESS-Reality\n${YELLOW}${link}${RESET}\n"
    command -v qrencode >/dev/null 2>&1 && qrencode -t ANSIUTF8 -m1 -s1 "$link";echo
  fi

  local f2="${CONF_DIR}/13_vmess_ws.json"
  if [ -f "$f2" ];then
    any=1
    local uuid=$(jq -r '..|users[]?.uuid' "$f2"|head -n1)
    local port=$(jq -r '..|listen_port' "$f2"|head -n1)
    local path=$(jq -r '..|transport.path' "$f2"|head -n1)
    local js=$(printf '{"v":"2","add":"%s","port":"%s","id":"%s","net":"ws","path":"%s"}' "$ip" "$port" "$uuid" "$path")
    local link="vmess://$(echo -n "$js"|base64 -w0)"
    echo -e "🔹 VMESS-WS\n${YELLOW}${link}${RESET}\n"
    command -v qrencode >/dev/null 2>&1 && qrencode -t ANSIUTF8 -m1 -s1 "$link";echo
  fi

  local f3="${CONF_DIR}/12_ss.json"
  if [ -f "$f3" ];then
    any=1
    local pwd=$(jq -r '..|password' "$f3"|head -n1)
    local port=$(jq -r '..|listen_port' "$f3"|head -n1)
    local m=$(jq -r '..|method' "$f3"|head -n1)
    local b64=$(printf '%s:%s@%s:%s' "$m" "$pwd" "$ip" "$port"|base64 -w0)
    echo -e "🔹 Shadowsocks\n${YELLOW}ss://${b64}#SS${RESET}\n"
    command -v qrencode >/dev/null 2>&1 && qrencode -t ANSIUTF8 -m1 -s1 "ss://${b64}";echo
  fi

  [ $any -eq 0 ] && warn "暂无已安装节点配置"
}

install_shortcut() {
  cat > /usr/local/bin/menu <<'EOF'
#!/bin/bash
bash <(curl -Ls https://raw.githubusercontent.com/tianhei211/install/main/installer.sh)
EOF
  chmod +x /usr/local/bin/menu
}

main_menu() {
  clear
  echo -e "${GREEN}┌───────────────────────────────┐${RESET}"
  echo -e "${GREEN}│    Sing-Box 一键部署工具箱    │${RESET}"
  echo -e "${GREEN}└───────────────────────────────┘${RESET}"
  echo
  echo "1) 安装 VLESS+TCP+Reality"
  echo "2) 安装 VMESS+WS"
  echo "3) 安装 Shadowsocks"
  echo "4) 一键启用 BBR"
  echo "5) 修改端口"
  echo "6) 修改UUID/SS密码"
  echo "7) 完全卸载"
  echo "8) 查看全部节点链接"
  echo "9) 退出"
  echo
  read -rp "请输入选项 [1-9]：" opt
  case $opt in
    1) install_vless_tcp_reality ;;
    2) install_vmess_ws ;;
    3) install_shadowsocks ;;
    4) enable_bbr ;;
    5) change_port ;;
    6) change_user_cred ;;
    7) uninstall_all ;;
    8) show_generated_links ;;
    9) exit 0 ;;
    *) echo "无效选项";sleep 1;main_menu ;;
  esac
}

# 初始化运行
need_root
detect_arch
detect_os
install_deps
install_shortcut
auto_cleanup_old_configs
merge_config
main_menu
