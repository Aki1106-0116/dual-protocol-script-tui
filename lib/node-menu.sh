#!/usr/bin/env bash
# Interactive entry points; mutations run in a strict, isolated child shell.
run_menu_action() {
  local rc
  set +e
  (
    set -Eeuo pipefail
    config_lock
    "$@"
  )
  rc=$?
  set -e
  if (( rc != 0 )); then
    err "操作未完成（退出码 $rc）；请检查上方错误与回滚结果。"
  fi
  # Always reload after a child action; never show the requested-but-uncommitted
  # values left in an interactive shell when a transaction failed.
  if [[ -f "$STATE_FILE" ]]; then
    load_state || { err "节点状态读取失败，请检查配置存储；未进入新安装。"; return 1; }
  fi
  return 0
}

ensure_tui_ownership() {
  if [[ ! -f "$STATE_FILE" ]]; then
    if [[ -e "$STATE_FILE.recovery" || -e "$XRAY_CONFIG" || -e "$HY2_CONFIG" || -e "$CADDYFILE" || -e "$OUT_DIR" || -e /etc/jb-combo/state.env ]]; then
      err "检测到现有或不完整的节点安装；本 TUI 版本不覆盖其他版本/程序的配置。请在独立服务器安装。"
      return 1
    fi
  else
    load_state || { err "已安装的节点状态读取失败，拒绝覆盖安装。"; return 1; }
  fi
}

show_info() {
  load_state || return 1
  printf '\n当前组合：%s\n节点名称：%s\n节点域名：%s\n\n' "$STACK_MODE" "$NODE_NAME" "${MANAGED_DOMAINS:-$HY2_DOMAIN}"
  for output in main-url.txt hy2-url.txt; do
    python3 "$STORAGE_HELPER" recover "$OUT_DIR/$output" || return 1
    cat "$OUT_DIR/$output"
    echo
  done
  echo "客户端配置与详情：$OUT_DIR"
}

show_service_status() {
  load_state || return 1
  local service rc=0
  local -a services=(xray hysteria-server)
  [[ "${CADDY_REQUIRED:-0}" == 1 ]] && services+=(caddy)
  for service in "${services[@]}"; do
    printf '\n%s：\n' "$service"
    systemctl --no-pager --full status "$service" || rc=1
  done
  return "$rc"
}

show_service_logs() {
  load_state || return 1
  local -a args=(-u xray -u hysteria-server)
  [[ "${CADDY_REQUIRED:-0}" == 1 ]] && args+=(-u caddy)
  journalctl "${args[@]}" -n 100 --no-pager
}

restart_selected() {
  local wanted="$1" service failed=0
  load_state || return 1
  local -a services=()
  case "$wanted" in
    all) services=(xray hysteria-server); [[ "${CADDY_REQUIRED:-0}" == 1 ]] && services+=(caddy) ;;
    xray|hysteria-server) services=("$wanted") ;;
    caddy) [[ "${CADDY_REQUIRED:-0}" == 1 ]] || { err "当前 REALITY 组合不使用 Caddy。"; return 1; }; services=(caddy) ;;
    *) return 1 ;;
  esac
  # Validate every requested service before stopping any working process.
  for service in "${services[@]}"; do validate_service_for_restart "$service" || return 1; done
  ensure_service_resilience "${services[@]}"
  for service in "${services[@]}"; do
    systemctl reset-failed "$service" || true
    if systemctl restart "$service" && systemctl is-active --quiet "$service"; then
      ok "$service 已重启并检查"
    else
      err "$service 重启失败"
      journalctl -u "$service" -n 40 --no-pager >&2 || true
      failed=1
    fi
  done
  return "$failed"
}
restart_all() { restart_selected all; }

validate_service_for_restart() {
  case "$1" in
    xray)
      python3 "$STORAGE_HELPER" recover "$XRAY_CONFIG" || return 1
      "$XRAY_BIN" run -test -config "$XRAY_CONFIG" -format json || return 1 ;;
    hysteria-server)
      python3 "$STORAGE_HELPER" recover "$HY2_CONFIG" || return 1 ;;
    caddy)
      python3 "$STORAGE_HELPER" recover "$CADDYFILE" || return 1
      "$CADDY_BIN" validate --config "$CADDYFILE" --adapter caddyfile || return 1 ;;
  esac
}

change_node_name() {
  load_state
  read -r -p "节点名称 [当前 $NODE_NAME]: " NODE_NAME
  apply_current_shell_config
}
change_hy2_domain() {
  load_state
  HY2_DOMAIN="$(prompt_domain '新的 HY2 域名' "$HY2_DOMAIN")"
  apply_current_shell_config
}
change_xhttp_domain() {
  load_state
  [[ "$MAIN_MODE" == xhttp ]] || { warn "当前组合没有 XHTTP。"; return 0; }
  XHTTP_DOMAIN="$(prompt_domain '新的 XHTTP 域名' "$XHTTP_DOMAIN")"
  apply_current_shell_config
}
change_hy2_obfs() { load_state; collect_hy2_obfs; apply_current_shell_config; }

initial_install() {
  ensure_tui_ownership
  if [[ -f "$STATE_FILE" ]]; then err "节点已安装，请在菜单中切换组合。"; return 1; fi
  prompt_swap_setup
  choose_stack_initial
  NODE_APPLY_COMMITTED=0
  NODE_BACKUP_DIR="$(mktemp -d /tmp/dual-protocol-tui-install.XXXXXX)"
  for pair in state xray hy2 caddy; do : > "$NODE_BACKUP_DIR/$pair.missing"; done
  NODE_FRESH_INSTALL=1
  trap node_apply_exit EXIT
  trap 'exit 143' HUP INT TERM
  install_selected_stack
  load_state
  NODE_APPLY_COMMITTED=1
  trap - EXIT HUP INT TERM
  rm -rf -- "$NODE_BACKUP_DIR"
}

full_uninstall() {
  load_state || return 1
  local answer
  read -r -p '确认卸载本 TUI 版的节点和管理命令？输入 YES: ' answer
  [[ "$answer" == YES ]] || { warn "已取消。"; return 0; }
  systemctl disable --now xray hysteria-server >/dev/null 2>&1 || true
  if [[ "$CADDY_REQUIRED" == 1 ]]; then systemctl disable --now caddy >/dev/null 2>&1 || true; fi
  remove_service_resilience_overrides
  local old_xhttp="" old_hy2="$HY2_DOMAIN"
  [[ "$CADDY_REQUIRED" != 1 ]] || old_xhttp="${XHTTP_DOMAIN:-}"
  if [[ "$CADDY_REQUIRED" == 1 ]]; then
    node_remove_domain_assets_from_root "$CADDY_DATA/certificates" "$old_xhttp" || true
    node_remove_domain_assets_from_root "$CADDY_DATA/certificates" "$old_hy2" || true
  else
    node_remove_domain_assets_from_root /var/lib/hysteria/acme/certificates "$old_hy2" || true
  fi
  for path in "$XRAY_CONFIG" "$HY2_CONFIG"; do rm -f -- "$path" "$path.recovery"; done
  if [[ "$CADDY_REQUIRED" == 1 ]]; then rm -f -- "$CADDYFILE" "$CADDYFILE.recovery"; fi
  rm -f /etc/systemd/system/xray.service /etc/systemd/system/xray@.service /etc/systemd/system/hysteria-server.service
  rm -f /usr/local/bin/xray /usr/local/bin/hysteria
  rm -rf -- "$SITE_ROOT" "$HY2_SITE_ROOT" "$OUT_DIR" "$STATE_DIR"
  # Keep unrelated packages, the OS kernel and existing Swap intact.
  rm -f /usr/local/bin/dual-protocol-script-tui
  if [[ -L /usr/bin/dual-protocol-script-tui && "$(readlink /usr/bin/dual-protocol-script-tui)" == /usr/local/bin/dual-protocol-script-tui ]]; then rm -f /usr/bin/dual-protocol-script-tui; fi
  if [[ -L /usr/local/bin/tui && "$(readlink /usr/local/bin/tui)" == /usr/local/bin/dual-protocol-script-tui ]]; then rm -f /usr/local/bin/tui; fi
  if [[ -L /usr/bin/tui && "$(readlink /usr/bin/tui)" == /usr/local/bin/dual-protocol-script-tui ]]; then rm -f /usr/bin/tui; fi
  rm -rf /usr/local/lib/dual-protocol-script-tui
  systemctl daemon-reload
  ok "TUI 版节点已卸载；已有 Swap 保留。"
}

print_result() { echo; ok "部署完成：$STACK_MODE；随时执行 tui 管理。"; show_info; }

menu() {
  check_os
  ensure_tui_ownership
  if [[ ! -f "$STATE_FILE" ]]; then run_menu_action initial_install; [[ -f "$STATE_FILE" ]] || return 1; fi
  local choice
  while true; do
    load_state || { err "节点状态读取失败，拒绝使用旧参数操作。"; return 1; }
    printf '\n========== dual-protocol-script-tui ==========\n%s · %s\n' "$STACK_MODE" "$NODE_NAME"
    cat <<'MENU'
  1) 节点信息与分享链接       2) 节点名称
  3) 主节点 UUID             4) 客户端指纹
  5) REALITY 地址/SNI/密钥    6) XHTTP 域名
  7) XHTTP 路径              8) HY2 域名
  9) HY2 密码               10) HY2 端口/跳跃
 11) HY2 Gecko 混淆         12) 状态检查
 13) 重启全部               14) 重启 Xray
 15) 重启 HY2               16) 重启 Caddy
 17) 查看服务日志           18) 切换为 XHTTP + HY2
 19) 切换为 REALITY + HY2    20) 重新生成客户端配置
 21) 彻底卸载                0) 退出
MENU
    if ! read -r -p '请选择: ' choice; then echo; return 0; fi
    case "$choice" in
      0) return 0 ;;
      1) run_menu_action show_info ;;
      2) run_menu_action change_node_name ;;
      3) run_menu_action regen_main_uuid_or_credential ;;
      4) run_menu_action change_fp ;;
      5) run_menu_action change_reality_target ;;
      6) run_menu_action change_xhttp_domain ;;
      7) run_menu_action change_xhttp_path ;;
      8) run_menu_action change_hy2_domain ;;
      9) run_menu_action change_hy2_password ;;
      10) run_menu_action change_hy2_port ;;
      11) run_menu_action change_hy2_obfs ;;
      12) run_menu_action show_service_status ;;
      13) run_menu_action restart_all ;;
      14) run_menu_action restart_selected xray ;;
      15) run_menu_action restart_selected hysteria-server ;;
      16) run_menu_action restart_selected caddy ;;
      17) run_menu_action show_service_logs ;;
      18) run_menu_action switch_to_stack xhttp_hy2 ;;
      19) run_menu_action switch_to_stack reality_hy2 ;;
      20) run_menu_action generate_main_outputs ;;
      21) run_menu_action full_uninstall; [[ -f "$STATE_FILE" ]] || return 0 ;;
      *) warn "无效选项。" ;;
    esac
  done
}
