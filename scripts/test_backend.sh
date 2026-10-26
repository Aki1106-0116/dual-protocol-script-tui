#!/usr/bin/env bash
# Sandbox all paths and external services. No real package or service changes.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX="$(mktemp -d)"
cleanup_test() { case "$SANDBOX" in /tmp/tmp.*) rm -rf -- "$SANDBOX" ;; *) echo "保留测试目录：$SANDBOX" >&2 ;; esac; }
trap cleanup_test EXIT
if [[ -n "${TEST_PYTHON:-}" ]]; then python3() { "$TEST_PYTHON" "$@"; }; fi
for module in node-common node-services node-transaction node-menu; do source "$ROOT/lib/${module}.sh"; done
ORIGINAL_CADDY_WRITER="$(declare -f write_caddyfile_xhttp_hy2)"
STATE_DIR="$SANDBOX/state";STATE_FILE="$STATE_DIR/state.env";XRAY_CONFIG="$SANDBOX/xray/config.json";HY2_CONFIG="$SANDBOX/hy2/config.yaml";CADDYFILE="$SANDBOX/caddy/Caddyfile";OUT_DIR="$SANDBOX/output"
HY2_CLIENT_YAML="$OUT_DIR/hy2-client.yaml";HY2_CLIENT_JSON="$OUT_DIR/hy2-client.json";XRAY_CLIENT_JSON="$OUT_DIR/xray-client.json";INFO_FILE="$OUT_DIR/node-info.txt"
STORAGE_HELPER="$ROOT/scripts/storage.py";mkdir -p "$STATE_DIR" "$(dirname "$XRAY_CONFIG")" "$(dirname "$HY2_CONFIG")" "$(dirname "$CADDYFILE")" "$OUT_DIR"
export DPS_CONFIG_LOCK_HELD=1
XRAY_BIN="$SANDBOX/fake-xray";printf '#!/usr/bin/env bash\nexit 0\n' > "$XRAY_BIN";chmod +x "$XRAY_BIN"
systemctl() { return 0; }
ensure_hysteria_capabilities() { return 0; }
start_xray() { return 0; }
start_caddy() { return 0; }
start_hy2() { return 0; }
reality_local_self_test() { return 0; }
node_cleanup_replaced_domains() { return 0; }
write_hy2_config_acme() { write_hy2_config_tls; }
write_caddyfile_xhttp_hy2() { printf 'test\n' > "$CADDYFILE"; }
MAIN_MODE=reality;STACK_MODE=reality_hy2;NODE_NAME='fixture';FP=chrome;REALITY_ADDRESS=203.0.113.10;REALITY_SNI=example.com;REALITY_UUID=123e4567-e89b-12d3-a456-426614174000;REALITY_PRIVATE_KEY=fixture-private;REALITY_PUBLIC_KEY=fixture-public;REALITY_SHORT_ID=abcdef
HY2_DOMAIN=h.example.com;HY2_PASSWORD='original-secret';HY2_PORT_MODE=single;HY2_PORT=45678;HY2_CERT_SOURCE=acme;HY2_ACME_EMAIL=admin@example.com;HY2_OBFS_TYPE=none;HY2_GECKO_MIN_PACKET_SIZE=512;HY2_GECKO_MAX_PACKET_SIZE=1200;HY2_CERT_PATH=/fixture/cert;HY2_KEY_PATH=/fixture/key;CADDY_REQUIRED=0
save_state;write_reality_xray_config;write_hy2_config_tls;generate_main_outputs
HY2_PASSWORD='new-secret-with-$()-quotes'
apply_current_shell_config
load_state
[[ "$HY2_PASSWORD" == 'new-secret-with-$()-quotes' ]] || { echo 'saved credentials differ' >&2; exit 1; }
cp "$XRAY_CONFIG" "$SANDBOX/old-xray";cp "$HY2_CONFIG" "$SANDBOX/old-hy2";cp "$STATE_FILE" "$SANDBOX/old-state"
HY2_PASSWORD=must-rollback
# Failure inside an unconditional transaction triggers the EXIT rollback trap.
start_hy2() { echo 'injected HY2 startup failure' >&2; return 1; }
set +e
(set -e;apply_current_shell_config)
RC=$?
set -e
[[ "$RC" -ne 0 ]] || { echo 'failure reported success' >&2;exit 1; }
cmp "$XRAY_CONFIG" "$SANDBOX/old-xray";cmp "$HY2_CONFIG" "$SANDBOX/old-hy2";cmp "$STATE_FILE" "$SANDBOX/old-state"
start_hy2() { return 0; }
load_state;MAIN_MODE=xhttp;STACK_MODE=xhttp_hy2;CADDY_REQUIRED=1;HY2_CERT_SOURCE=caddy;XHTTP_DOMAIN=x.example.com;XHTTP_UUID=123e4567-e89b-12d3-a456-426614174000;XHTTP_PATH=/fixture;XHTTP_BACKEND_PORT=10080
save_state;write_xhttp_xray_config;write_hy2_config_tls;generate_main_outputs
HY2_PORT_MODE=hop;HY2_FIRST_PORT=30000;HY2_END_PORT=30050;HY2_PORT=30000;HY2_HOP_INTERVAL=25;HY2_OBFS_TYPE=gecko;HY2_OBFS_PASSWORD='gecko-secret'
apply_current_shell_config
python3 - "$XRAY_CONFIG" "$HY2_CONFIG" "$HY2_CLIENT_JSON" "$XRAY_CLIENT_JSON" <<'PY'
import json,sys,yaml
x=json.load(open(sys.argv[1]));assert x['inbounds'][0]['tag']=='vless-xhttp-in';assert x['inbounds'][0]['port']==10080
h=yaml.safe_load(open(sys.argv[2]));assert h['listen']==':30000-30050';assert h['obfs']['type']=='gecko';assert h['auth']['password']=='new-secret-with-$()-quotes'
c=json.load(open(sys.argv[3]));assert c['server']=='h.example.com:30000-30050';assert c['obfs']['gecko']['password']=='gecko-secret'
json.load(open(sys.argv[4]))
PY
grep -Fq "$OUT_DIR/hy2-client.yaml" "$INFO_FILE"
echo 'Backend regression passed: Reality save, startup rollback, XHTTP, hopping, Gecko, client JSON/YAML.'

# A failed interactive edit must return to the menu with the old state intact.
check_os() { return 0; }
cp "$STATE_FILE" "$SANDBOX/menu-before"
printf '2\n\n0\n' | menu > "$SANDBOX/menu.log" 2>&1
cmp "$STATE_FILE" "$SANDBOX/menu-before"
grep -q '操作未完成' "$SANDBOX/menu.log"
echo 'TUI_FAILED_EDIT_RETURNS_TO_MENU_OK'

# Invalid stored state is an error, not permission to reinstall defaults.
set +e
(
  set -e
  STATE_DIR="$SANDBOX/bad"; STATE_FILE="$STATE_DIR/state.env"
  mkdir -p "$STATE_DIR"; printf 'broken\n' > "$STATE_FILE"
  prompt_swap_setup() { touch "$SANDBOX/forbidden-fresh-install"; }
  menu </dev/null
) > "$SANDBOX/bad-state.log" 2>&1
bad_rc=$?
set -e
[[ "$bad_rc" -ne 0 && ! -e "$SANDBOX/forbidden-fresh-install" ]]
echo 'CORRUPT_STATE_DOES_NOT_REINSTALL_OK'

# First-install failure clears partial configuration and recovery records.
set +e
(
  set -e
  STATE_DIR="$SANDBOX/fresh/state"; STATE_FILE="$STATE_DIR/state.env"
  XRAY_CONFIG="$SANDBOX/fresh/xray/config.json"; HY2_CONFIG="$SANDBOX/fresh/hy2/config.yaml"
  CADDYFILE="$SANDBOX/fresh/caddy/Caddyfile"; OUT_DIR="$SANDBOX/fresh/outputs"
  mkdir -p "$STATE_DIR" "$(dirname "$XRAY_CONFIG")" "$(dirname "$HY2_CONFIG")" "$(dirname "$CADDYFILE")"
  ensure_tui_ownership() { :; } # the VM may contain the independently tested fix edition
  prompt_swap_setup() { :; }; choose_stack_initial() { MAIN_MODE=reality; STACK_MODE=reality_hy2; CADDY_REQUIRED=0; HY2_CERT_SOURCE=acme; }
  install_selected_stack() { save_state; write_reality_xray_config; write_hy2_config_tls; return 1; }
  initial_install
) > "$SANDBOX/first-install.log" 2>&1
fresh_rc=$?
set -e
[[ "$fresh_rc" -ne 0 && ! -e "$SANDBOX/fresh/state/state.env" && ! -e "$SANDBOX/fresh/state/state.env.recovery" && ! -e "$SANDBOX/fresh/xray/config.json" ]]
echo 'FIRST_INSTALL_FAILURE_CLEANUP_OK'

ensure_service_resilience() { :; }
validate_service_for_restart() { :; } # restart failure check is isolated from config validation
systemctl() {
  printf '%s\n' "$*" >> "$SANDBOX/restarts"
  [[ "$*" != 'is-active --quiet hysteria-server' ]]
}
journalctl() { :; }
set +e
restart_all > "$SANDBOX/restart-failure.log" 2>&1
restart_rc=$?
set -e
[[ "$restart_rc" -ne 0 ]]
grep -q '^reset-failed xray$' "$SANDBOX/restarts"
grep -q '^restart xray$' "$SANDBOX/restarts"
grep -q '^restart hysteria-server$' "$SANDBOX/restarts"
grep -q '^restart caddy$' "$SANDBOX/restarts"
systemctl() { return 0; }
echo 'RESTART_CHECK_REPORTS_FAILURE_AND_RESETS_LIMIT_OK'

# Exercise the actual Caddy writer on Linux with the installed parser.
if command -v caddy >/dev/null 2>&1; then
  eval "$ORIGINAL_CADDY_WRITER"
  CADDY_BIN="$(command -v caddy)"
  SITE_ROOT="$SANDBOX/site"; HY2_SITE_ROOT="$SANDBOX/hy2-site"
  mkdir -p "$SITE_ROOT" "$HY2_SITE_ROOT"
  start_caddy() { echo start >> "$SANDBOX/caddy-starts"; }
  node_wait_for_caddy_cert_only() { echo "$1" >> "$SANDBOX/issued-domains"; }
  wait_for_caddy_cert() { :; }
  grant_cert_read_permissions() { :; }
  write_caddyfile_xhttp_hy2
  cp "$CADDYFILE" "$SANDBOX/caddy-before"
  NODE_NAME='renamed node'
  apply_current_shell_config
  cmp "$CADDYFILE" "$SANDBOX/caddy-before"
  [[ ! -e "$SANDBOX/caddy-starts" && ! -e "$SANDBOX/issued-domains" ]]
  HY2_DOMAIN='new-h.example.com'; apply_current_shell_config
  [[ "$(cat "$SANDBOX/issued-domains")" == new-h.example.com ]]
  XHTTP_DOMAIN='new-x.example.com'; apply_current_shell_config
  [[ "$(cat "$SANDBOX/issued-domains")" == $'new-h.example.com\nnew-x.example.com' ]]
  grep -q '^new-x.example.com {' "$CADDYFILE"
  if grep -q 'python3' "$CADDYFILE"; then echo 'commands leaked into Caddyfile' >&2; exit 1; fi
  echo 'REAL_CADDY_COMMIT_AND_NODE_CERT_BRANCHES_OK'
  # Inject failure after some export files have been committed. Rollback must
  # regenerate in the real output directory, not a shadowed staging directory.
  export DPS_TEST_REAL_STORAGE="$STORAGE_HELPER" DPS_TEST_OUTPUT="$OUT_DIR"
  cat > "$SANDBOX/fail-once.py" <<'PY'
import os,pathlib,sys
marker=pathlib.Path(__file__).with_suffix('.used')
if sys.argv[1]=='write' and sys.argv[2]==os.environ['DPS_TEST_OUTPUT']+'/hy2-client.json' and not marker.exists():
    marker.touch()
    print('injected export commit failure',file=sys.stderr)
    sys.exit(1)
os.execv(sys.executable,[sys.executable,os.environ['DPS_TEST_REAL_STORAGE']]+sys.argv[1:])
PY
  cp "$STATE_FILE" "$SANDBOX/export-before-state"
  cp "$OUT_DIR/hy2-url.txt" "$SANDBOX/export-before-link"
  cp "$HY2_CLIENT_JSON" "$SANDBOX/export-before-client"
  set +e
  (
    set -e
    STORAGE_HELPER="$SANDBOX/fail-once.py"
    HY2_PASSWORD=must-not-commit
    apply_current_shell_config
  ) > "$SANDBOX/export-failure.log" 2>&1
  export_rc=$?
  set -e
  [[ "$export_rc" -ne 0 ]]
  cmp "$STATE_FILE" "$SANDBOX/export-before-state"
  cmp "$OUT_DIR/hy2-url.txt" "$SANDBOX/export-before-link"
  cmp "$HY2_CLIENT_JSON" "$SANDBOX/export-before-client"
  [[ -z "$(find "$SANDBOX" -maxdepth 1 -name 'output.stage.*' -print -quit)" ]]
  echo 'PARTIAL_EXPORT_FAILURE_RESTORES_REAL_DESTINATION_OK'
fi
