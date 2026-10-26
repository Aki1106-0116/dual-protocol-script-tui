#!/usr/bin/env bash
# Sourced by node-installer.sh; functions have no independent entry point.
# dual-protocol-script-tui integration: verified keys, rollback and terminal transactions
# dual-protocol-script-tui-installer.sh
# patched release: v10
# Debian/Ubuntu combo installer for exactly ONE of:
#   1) VLESS + XHTTP + TLS  + Hysteria2
#   2) VLESS + REALITY + Vision + Hysteria2
#
# Design:
# - XHTTP stack uses Caddy for public TCP 80/443, certificates, and web camouflage.
# - REALITY stack uses Xray on TCP 443 and Hysteria2 built-in ACME for HY2 certificates; no Caddy.
# - Hysteria2 ports may NOT be 80, 443, 2053, or 8443, including ranges.
# - Optional simple /swapfile setup runs before protocol service installation; default enabled, 0.7 GB; skipped when any swap is already configured.
# - Optional Hysteria2 Gecko obfuscation is available during HY2 setup; default disabled.
# - When Caddy manages certificates for HY2, certificates are NOT copied or moved; HY2 reads Caddy's cert/key paths directly.
# - Run `tui` after installation to open the combined control panel.

set -Eeuo pipefail
umask 077
STORAGE_HELPER="${DPS_STORAGE_HELPER:-/usr/local/lib/dual-protocol-script-tui/storage.py}"
KEY_HELPER="${DPS_KEY_HELPER:-/usr/local/lib/dual-protocol-script-tui/keys.py}"

config_lock() {
  [[ "${DPS_CONFIG_LOCK_HELD:-0}" == "1" ]] && return 0
  exec 9>"${DPS_CONFIG_LOCK:-/run/dual-protocol-script-tui-config.lock}"
  flock -w 30 9 || { echo "另一个配置操作尚未完成" >&2; return 1; }
  DPS_CONFIG_LOCK_OWNER=1
  export DPS_CONFIG_LOCK_HELD=1
}
config_unlock() {
  if [[ "${DPS_CONFIG_LOCK_OWNER:-0}" == "1" ]]; then
    flock -u 9; exec 9>&-; unset DPS_CONFIG_LOCK_HELD DPS_CONFIG_LOCK_OWNER
  fi
}

export DEBIAN_FRONTEND=noninteractive

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

APP_NAME="dual-protocol-script-tui"
STATE_DIR="/etc/dual-protocol-script-tui"
STATE_FILE="${STATE_DIR}/state.env"
THIS_SCRIPT="/usr/local/lib/dual-protocol-script-tui/node-installer.sh"

CADDYFILE="/etc/caddy/Caddyfile"
CADDY_BIN="/usr/bin/caddy"
CADDY_DATA="/var/lib/caddy/.local/share/caddy"
XRAY_CONFIG="/usr/local/etc/xray/config.json"
XRAY_BIN="/usr/local/bin/xray"
HY2_CONFIG="/etc/hysteria/config.yaml"
HY2_BIN="/usr/local/bin/hysteria"


SWAP_FILE="/swapfile"

SITE_ROOT="/var/www/dual-protocol-script-tui-site"
HY2_SITE_ROOT="/var/www/dual-protocol-script-tui-hy2"
OUT_DIR="/root/dual-protocol-script-tui"
INFO_FILE="${OUT_DIR}/node-info.txt"
XRAY_CLIENT_JSON="${OUT_DIR}/xray-client.json"
HY2_CLIENT_JSON="${OUT_DIR}/hy2-client.json"
HY2_CLIENT_YAML="${OUT_DIR}/hy2-client.yaml"

RESERVED_HY2_PORTS=(80 443 2053 8443)
BASE_PACKAGES_INSTALLED=0

# 【已修正】将UI输出函数全部重定向到标准错误(>&2)，防止污染交互式变量捕获
log() { echo -e "${BLUE}==>${NC} $*" >&2; }
ok() { echo -e "${GREEN}✓${NC} $*" >&2; }
warn() { echo -e "${YELLOW}!${NC} $*" >&2; }
err() { echo -e "${RED}✗${NC} $*" >&2; }

pause_confirm() { read -r -p "${1:-按回车继续...}" _ || true; }
cmd_exists() { command -v "$1" >/dev/null 2>&1; }

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    err "请以 root 登录后运行：bash $0"
    exit 1
  fi
}

check_os() {
  if [[ ! -f /etc/os-release ]]; then
    err "无法识别系统。仅支持 Debian / Ubuntu。"
    exit 1
  fi
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in
    debian|ubuntu) ;;
    *) err "当前系统是 ${PRETTY_NAME:-unknown}。本脚本仅支持 Debian / Ubuntu。"; exit 1 ;;
  esac
  if ! cmd_exists systemctl; then
    err "未检测到 systemd。"
    exit 1
  fi
  ok "系统检查通过：${PRETTY_NAME:-$ID}"
}

load_state() {
  local read_owner=0 read_rc=1
  if [[ "${DPS_CONFIG_LOCK_HELD:-0}" != 1 ]]; then
    config_lock || return 2
    read_owner=1
  fi
  if [[ -f "$STATE_FILE" ]]; then
    if python3 "$STORAGE_HELPER" recover "$STATE_FILE" && source "$STATE_FILE"; then
      read_rc=0
    else
      read_rc=2
    fi
  fi
  if (( read_owner == 1 )); then config_unlock; fi
  return "$read_rc"
}

save_state() {
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"

  local tmp name val
  tmp="$(mktemp "${STATE_FILE}.tmp.XXXXXX")"
  : > "$tmp"
  chmod 600 "$tmp"

  local vars=(
    STACK_MODE MAIN_MODE MANAGED_DOMAINS CADDY_REQUIRED SITE_ENABLED
    MAIN_DOMAIN MAIN_DOMAIN2 XHTTP_DOMAIN XHTTP_PATH XHTTP_UUID XHTTP_BACKEND_PORT
    REALITY_ADDRESS REALITY_UUID REALITY_SNI REALITY_PRIVATE_KEY REALITY_PUBLIC_KEY REALITY_SHORT_ID FP NODE_NAME
    HY2_DOMAIN HY2_PASSWORD HY2_PORT_MODE HY2_PORT HY2_FIRST_PORT HY2_END_PORT HY2_HOP_INTERVAL
    HY2_MIN_HOP_INTERVAL HY2_MAX_HOP_INTERVAL HY2_CERT_SOURCE HY2_CERT_PATH HY2_KEY_PATH HY2_ACME_EMAIL
    HY2_OBFS_TYPE HY2_OBFS_PASSWORD HY2_GECKO_MIN_PACKET_SIZE HY2_GECKO_MAX_PACKET_SIZE
    SWAP_MANAGED SWAP_SIZE_GB SWAP_FILE_PATH
  )

  for name in "${vars[@]}"; do
    if [[ -v "$name" ]]; then
      val="${!name}"
    else
      case "$name" in
        CADDY_REQUIRED|SITE_ENABLED) val="0" ;;
        FP) val="chrome" ;;
        HY2_HOP_INTERVAL) val="25" ;;
        HY2_OBFS_TYPE) val="none" ;;
        HY2_GECKO_MIN_PACKET_SIZE) val="512" ;;
        HY2_GECKO_MAX_PACKET_SIZE) val="1200" ;;
        SWAP_MANAGED) val="0" ;;
        SWAP_FILE_PATH) val="$SWAP_FILE" ;;
        *) val="" ;;
      esac
    fi
    printf '%s=%q\n' "$name" "$val" >> "$tmp"
  done

  python3 "$STORAGE_HELPER" write "$STATE_FILE" "$tmp" 600
  rm -f "$tmp"
  chmod 600 "$STATE_FILE"
}

swap_size_to_mib() {
  local size="$1"
  [[ "$size" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1
  awk -v s="$size" 'BEGIN {
    if (s < 0.1 || s > 5.0) exit 1;
    printf "%d", int(s * 1024 + 0.5);
  }'
}

swap_active_exists() {
  awk 'NR > 1 { found=1 } END { exit found ? 0 : 1 }' /proc/swaps 2>/dev/null
}

swap_fstab_exists() {
  [[ -f /etc/fstab ]] || return 1
  awk '
    /^[[:space:]]*#/ { next }
    NF >= 3 && $3 == "swap" { found=1 }
    END { exit found ? 0 : 1 }
  ' /etc/fstab
}

swap_config_exists() {
  swap_active_exists || swap_fstab_exists
}

swap_config_summary() {
  local active fstab_entries
  active="$(awk 'NR > 1 { printf "%s(%s KiB) ", $1, $3 }' /proc/swaps 2>/dev/null | sed 's/[[:space:]]*$//')"
  fstab_entries=""
  if [[ -f /etc/fstab ]]; then
    fstab_entries="$(awk '
      /^[[:space:]]*#/ { next }
      NF >= 3 && $3 == "swap" { printf "%s ", $1 }
    ' /etc/fstab | sed 's/[[:space:]]*$//')"
  fi
  if [[ -n "$active" && -n "$fstab_entries" ]]; then
    printf 'active: %s; fstab: %s' "$active" "$fstab_entries"
  elif [[ -n "$active" ]]; then
    printf 'active: %s' "$active"
  elif [[ -n "$fstab_entries" ]]; then
    printf 'fstab: %s' "$fstab_entries"
  else
    printf 'none'
  fi
}

append_simple_swap_fstab_entry() {
  [[ -f /etc/fstab ]] || : > /etc/fstab
  backup_file /etc/fstab
  if ! awk -v p="$SWAP_FILE" '
      /^[[:space:]]*#/ { next }
      NF >= 3 && $1 == p && $3 == "swap" { found=1 }
      END { exit found ? 0 : 1 }
    ' /etc/fstab; then
    printf '%s none swap sw 0 0\n' "$SWAP_FILE" >> /etc/fstab
  fi
  chmod 644 /etc/fstab 2>/dev/null || true
  if cmd_exists systemctl; then
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi
}

setup_simple_swapfile() {
  local size_gb="$1" size_mib target_kib available_kib
  SWAP_MANAGED="0"
  SWAP_SIZE_GB="$size_gb"
  SWAP_FILE_PATH="$SWAP_FILE"

  if swap_config_exists; then
    ok "检测到系统已经配置了 Swap，跳过脚本创建 Swap：$(swap_config_summary)"
    return 0
  fi

  size_mib="$(swap_size_to_mib "$size_gb")" || {
    warn "Swap 大小必须在 0.1-5.0 GB 之间；已跳过 Swap，不影响节点安装。"
    return 0
  }
  target_kib=$((size_mib * 1024))

  if ! cmd_exists mkswap || ! cmd_exists swapon || ! cmd_exists dd; then
    log "安装 Swap 所需基础工具"
    install_base_packages || {
      warn "基础工具安装失败，已跳过 Swap，不影响节点安装。"
      return 0
    }
  fi

  if [[ -e "$SWAP_FILE" ]]; then
    warn "检测到 $SWAP_FILE 已存在。为避免误覆盖已有文件，已跳过创建 Swap。"
    warn "如确认该文件无用，可手动删除后重新运行脚本。"
    return 0
  fi

  available_kib="$(df -Pk "$(dirname "$SWAP_FILE")" 2>/dev/null | awk 'NR==2 {print $4}')"
  if [[ -n "$available_kib" ]] && (( available_kib < target_kib + 102400 )); then
    warn "磁盘剩余空间不足，无法创建 ${size_gb}GB Swap；请至少预留目标大小之外约 100MB 空间。已继续安装节点但不启用 Swap。"
    return 0
  fi

  log "正在创建 Swap 文件：$SWAP_FILE，大小约 ${size_gb}GB"
  if ! dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$size_mib" status=none; then
    warn "写入 Swap 文件失败，已跳过 Swap，不影响节点安装。"
    rm -f "$SWAP_FILE" 2>/dev/null || true
    return 0
  fi
  chmod 600 "$SWAP_FILE" 2>/dev/null || true

  if ! mkswap "$SWAP_FILE" >/tmp/dual-protocol-script-tui-mkswap.log 2>&1; then
    warn "mkswap 失败，已跳过 Swap，不影响节点安装。"
    cat /tmp/dual-protocol-script-tui-mkswap.log 2>/dev/null || true
    rm -f "$SWAP_FILE" 2>/dev/null || true
    return 0
  fi

  if ! swapon "$SWAP_FILE" >/tmp/dual-protocol-script-tui-swapon.log 2>&1; then
    warn "swapon 失败，可能是容器/VPS 内核或文件系统限制；已删除脚本创建的 Swap 文件并继续安装节点。"
    cat /tmp/dual-protocol-script-tui-swapon.log 2>/dev/null || true
    rm -f "$SWAP_FILE" 2>/dev/null || true
    return 0
  fi

  append_simple_swap_fstab_entry
  SWAP_MANAGED="1"
  ok "Swap 已创建并挂载：$SWAP_FILE，大小约 ${size_gb}GB。"
}

remove_managed_swap() {
  # 按用户要求：脚本的任何卸载和删除功能都不触碰已经配置好的 Swap。
  return 0
}

prompt_swap_setup() {
  echo
  echo "Swap 设置："
  if swap_config_exists; then
    SWAP_MANAGED="0"
    SWAP_SIZE_GB=""
    SWAP_FILE_PATH="$SWAP_FILE"
    ok "检测到系统已经配置了 Swap，跳过脚本创建 Swap：$(swap_config_summary)"
    return 0
  fi

  echo "  未检测到已有 Swap。默认启用 Swap，默认大小 0.7GB。"
  echo "  可输入范围：0.1-5.0，单位 GB。"
  read -r -p "是否创建 /swapfile 并启用 Swap？[Y/n]: " ans
  if [[ "${ans:-Y}" =~ ^[Nn]$ ]]; then
    SWAP_MANAGED="0"
    SWAP_SIZE_GB=""
    SWAP_FILE_PATH="$SWAP_FILE"
    warn "已选择不由脚本创建 Swap。"
    return 0
  fi

  local sg mib
  while true; do
    read -r -p "请输入 Swap 大小，单位 GB [默认 0.7]: " sg
    sg="${sg:-0.7}"
    if mib="$(swap_size_to_mib "$sg")"; then
      SWAP_SIZE_GB="$sg"
      break
    fi
    warn "Swap 大小格式不正确，必须是 0.1-5.0 之间的数字，例如 0.7、1、2.5。"
  done
  setup_simple_swapfile "$SWAP_SIZE_GB"
}

backup_file() {
  local f="$1"
  if [[ -f "$f" ]]; then
    cp -a "$f" "${f}.bak.$(date +%Y%m%d-%H%M%S)"
  fi
}

valid_domain() {
  local d="$1"
  [[ "$d" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]
}

valid_ip() {
  python3 - "$1" <<'PY' >/dev/null 2>&1
import ipaddress, sys
ipaddress.ip_address(sys.argv[1])
PY
}

valid_host_address() {
  local h="$1"
  valid_domain "$h" || valid_ip "$h"
}

normalize_host_address() {
  local h="$1" colon_count
  h="$(echo "${h:-}" | tr '[:upper:]' '[:lower:]' | sed 's#^https\?://##; s#/.*$##')"
  if [[ "$h" =~ ^\[([^]]+)\](:[0-9]+)?$ ]]; then
    h="${BASH_REMATCH[1]}"
  else
    colon_count="$(grep -o ':' <<< "$h" | wc -l | tr -d ' ')"
    if [[ "$colon_count" == "1" && "$h" =~ :[0-9]+$ ]]; then
      h="${h%%:*}"
    fi
  fi
  printf '%s' "$h"
}

prompt_host_address() {
  local prompt="$1" default="${2:-}" h
  while true; do
    if [[ -n "$default" ]]; then
      read -r -p "$prompt [默认 $default]: " h
      h="${h:-$default}"
    else
      read -r -p "$prompt: " h
    fi
    h="$(normalize_host_address "$h")"
    if valid_host_address "$h"; then
      printf '%s' "$h"
      return 0
    fi
    warn "连接地址格式不正确，请输入域名、IPv4 或 IPv6。"
  done
}

uri_host() {
  local h="$1"
  if valid_ip "$h" && [[ "$h" == *:* ]]; then
    printf '[%s]' "$h"
  else
    printf '%s' "$h"
  fi
}

normalize_domain() {
  local d="$1"
  d="$(echo "${d:-}" | tr '[:upper:]' '[:lower:]' | sed 's#^https\?://##; s#/.*$##; s/:.*$//')"
  printf '%s' "$d"
}

prompt_domain() {
  local prompt="$1" default="${2:-}" d
  while true; do
    if [[ -n "$default" ]]; then
      read -r -p "$prompt [默认 $default]: " d
      d="${d:-$default}"
    else
      read -r -p "$prompt: " d
    fi
    d="$(normalize_domain "$d")"
    if valid_domain "$d"; then
      printf '%s' "$d"
      return 0
    fi
    warn "域名格式不正确，请重新输入。"
  done
}

normalize_path() {
  local p="$1"
  p="${p%%\?*}"; p="${p%%#*}"
  [[ -z "$p" ]] && return 1
  [[ "$p" != /* ]] && p="/$p"
  [[ "$p" != "/" ]] && p="${p%/}"
  [[ "$p" == "/" ]] && return 1
  [[ "$p" =~ ^/[A-Za-z0-9._~/-]+$ ]] || return 1
  printf '%s' "$p"
}

urlencode() {
  local LC_ALL=C s="$1" out="" i c hex
  for ((i=0; i<${#s}; i++)); do
    c="${s:i:1}"
    case "$c" in
      [A-Za-z0-9.~_-]) out+="$c" ;;
      *) printf -v hex '%%%02X' "'$c"; out+="$hex" ;;
    esac
  done
  printf '%s\n' "$out"
}

json_escape() {
  python3 -c 'import json, sys; print(json.dumps(sys.argv[1], ensure_ascii=False)[1:-1])' "$1"
}

yaml_quote() {
  local s="$1"
  s="${s//\'/\'\'}"
  printf "'%s'\n" "$s"
}

generate_password() { openssl rand -base64 24 | tr -d '\n' | tr '+/' '-_' | cut -c 1-24; }
generate_shortid() { openssl rand -hex 8; }
new_uuid() { uuidgen | tr '[:upper:]' '[:lower:]'; }

public_ip() { curl -4fsS --max-time 6 https://api.ipify.org 2>/dev/null || true; }

install_base_packages() {
  if [[ "${BASE_PACKAGES_INSTALLED:-0}" == "1" ]] && cmd_exists ss && cmd_exists curl && cmd_exists python3; then
    return 0
  fi
  log "更新 APT 并安装基础依赖"
  apt-get update
  apt-get install -y ca-certificates curl gnupg debian-keyring debian-archive-keyring \
    apt-transport-https lsb-release unzip jq openssl uuid-runtime iproute2 python3 python3-yaml coreutils \
    acl procps lsof iptables nftables
  BASE_PACKAGES_INSTALLED=1
  ok "基础依赖安装完成"
}

ensure_port_tools() {
  if ! cmd_exists ss; then
    install_base_packages
  fi
}

port_in_use_tcp() {
  local port="$1"
  cmd_exists ss || return 1
  ss -H -ltn "sport = :${port}" 2>/dev/null | grep -q .
}

port_in_use_udp() {
  local port="$1"
  cmd_exists ss || return 1
  ss -H -lun "sport = :${port}" 2>/dev/null | grep -q .
}

show_port_users() {
  echo "TCP 80/443："; ss -ltnp 2>/dev/null | grep -E '(:80|:443)\s' || true
  echo "UDP 端口："; ss -lunp 2>/dev/null | grep -E ':(80|443|2053|8443)\s' || true
}

stop_known_services() {
  for svc in caddy xray hysteria-server nginx apache2 httpd x-ui 3x-ui xui; do
    if systemctl list-unit-files | grep -q "^${svc}\.service"; then
      systemctl stop "$svc" >/dev/null 2>&1 || true
      systemctl disable "$svc" >/dev/null 2>&1 || true
    fi
  done
}

ensure_tcp_80_443_free_for_caddy() {
  ensure_port_tools
  if port_in_use_tcp 80 || port_in_use_tcp 443; then
    warn "Caddy 需要占用 TCP 80/443。当前端口被占用："
    show_port_users
    read -r -p "是否停止常见服务以释放端口？[y/N]: " ans
    [[ "${ans:-}" =~ ^[Yy]$ ]] || { err "请先释放 TCP 80/443。"; exit 1; }
    stop_known_services
    sleep 2
  fi
  if port_in_use_tcp 80 || port_in_use_tcp 443; then
    err "TCP 80/443 仍被占用，请手动处理。"
    show_port_users
    exit 1
  fi
}

ensure_tcp_443_free_for_reality() {
  ensure_port_tools
  if port_in_use_tcp 443; then
    warn "REALITY 需要占用 TCP 443。当前端口被占用："
    show_port_users
    read -r -p "是否停止常见服务以释放 TCP 443？[y/N]: " ans
    [[ "${ans:-}" =~ ^[Yy]$ ]] || { err "请先释放 TCP 443。"; exit 1; }
    stop_known_services
    sleep 2
  fi
  if port_in_use_tcp 443; then
    err "TCP 443 仍被占用，请手动处理。"
    show_port_users
    exit 1
  fi
}

hy2_reserved_port() {
  local p="$1" r
  for r in "${RESERVED_HY2_PORTS[@]}"; do [[ "$p" -eq "$r" ]] && return 0; done
  return 1
}

hy2_range_contains_reserved() {
  local start="$1" end="$2" r
  for r in "${RESERVED_HY2_PORTS[@]}"; do
    if (( r >= start && r <= end )); then return 0; fi
  done
  return 1
}

find_free_local_port() {
  local p
  for p in $(seq 10000 10199); do
    if ! port_in_use_tcp "$p"; then echo "$p"; return 0; fi
  done
  python3 - <<'PY'
import socket
s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1]); s.close()
PY
}

