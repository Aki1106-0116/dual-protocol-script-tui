#!/usr/bin/env bash
# Opt-in: use only on an isolated Linux runner. Creates one unique test unit.
set -Eeuo pipefail
[[ "${DPS_RUN_INTEGRATION:-0}" == 1 && "$EUID" == 0 ]] || { echo '需要独立 Linux 测试环境及 DPS_RUN_INTEGRATION=1/root' >&2; exit 1; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/node-common.sh"
source "$ROOT/lib/node-services.sh"
SANDBOX="$(mktemp -d /tmp/dual-protocol-tui-systemd.XXXXXX)"
UNIT="dps-tui-smoke-$$"
cleanup() {
  systemctl disable --now "$UNIT" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/$UNIT.service"
  rm -rf "/etc/systemd/system/$UNIT.service.d" "$SANDBOX"
  systemctl daemon-reload
}
trap cleanup EXIT
export DPS_CONFIG_LOCK="$SANDBOX/config.lock"
config_lock
( config_lock; echo inherited > "$SANDBOX/inherited" )
[[ -s "$SANDBOX/inherited" ]]
set +e
flock -n "$DPS_CONFIG_LOCK" true
conflict=$?
set -e
[[ "$conflict" -ne 0 ]]
config_unlock
flock -n "$DPS_CONFIG_LOCK" true
echo 'SHARED_LOCK_INHERITANCE_AND_SERIALIZATION_OK'

cat > "$SANDBOX/core" <<CORE
#!/bin/sh
if [ ! -f "$SANDBOX/failed-once" ]; then touch "$SANDBOX/failed-once"; exit 1; fi
exec /bin/sleep infinity
CORE
chmod 700 "$SANDBOX/core"
cat > "/etc/systemd/system/$UNIT.service" <<UNITFILE
[Unit]
Description=Isolated TUI core restart validation
[Service]
ExecStart=$SANDBOX/core
UNITFILE
write_service_restart_override "$UNIT"
systemctl daemon-reload
systemctl start "$UNIT" || true
ready=0
for _ in $(seq 1 30); do
  count="$(systemctl show "$UNIT" -p NRestarts --value)"
  if (( count >= 1 )) && systemctl is-active --quiet "$UNIT"; then ready=1; break; fi
  sleep 1
done
[[ "$ready" == 1 && "$(systemctl show "$UNIT" -p Restart --value)" == always ]]
echo "SYSTEMD_UNEXPECTED_EXIT_RESTART_OK restarts=$count"
systemctl stop "$UNIT"
sleep 6
if systemctl is-active --quiet "$UNIT"; then echo 'manual stop incorrectly restarted' >&2; exit 1; fi
echo 'SYSTEMD_MANUAL_STOP_REMAINS_STOPPED_OK'
