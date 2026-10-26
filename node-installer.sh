#!/usr/bin/env bash
set -Eeuo pipefail
BACKEND_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
if [[ -f "$BACKEND_DIR/storage.py" ]]; then
  DPS_STORAGE_HELPER="$BACKEND_DIR/storage.py"; DPS_KEY_HELPER="$BACKEND_DIR/keys.py"
else
  DPS_STORAGE_HELPER="$BACKEND_DIR/scripts/storage.py"; DPS_KEY_HELPER="$BACKEND_DIR/scripts/keys.py"
fi
for module in node-common node-services node-transaction node-menu; do
  source "$BACKEND_DIR/lib/$module.sh"
done

main() {
  if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then echo '用法: dual-protocol-script-tui [menu|info|status|restart|log|uninstall]'; return 0; fi
  require_root
  case "${1:-menu}" in
    menu|'') menu ;;
    info) config_lock; show_info ;;
    status) config_lock; show_service_status ;;
    restart) config_lock; restart_all ;;
    log) show_service_logs ;;
    uninstall) config_lock; full_uninstall ;;
    *) err "未知命令：$1"; return 2 ;;
  esac
}
main "$@"
