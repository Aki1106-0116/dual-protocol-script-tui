#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
[[ "$EUID" == 0 ]] || { echo '请以 root 登录后运行 install.sh' >&2; exit 1; }
[[ -f /etc/os-release ]] || { echo '无法识别系统' >&2; exit 1; }
. /etc/os-release
case "$ID" in debian|ubuntu) ;; *) echo '仅支持 Debian/Ubuntu + systemd' >&2; exit 1 ;; esac
command -v systemctl >/dev/null || { echo '需要 systemd' >&2; exit 1; }
case "${1:-}" in ''|--update) ;; *) echo '用法: install.sh [--update]' >&2; exit 2 ;; esac

# Both variants own the standard protocol units/config paths. This standalone
# installer never disables or removes another edition on the user's behalf.
if [[ -f /etc/jb-combo/state.env || -f /etc/systemd/system/dual-protocol-script-fix.service ]]; then
  echo '检测到现有 fix 版；请在独立服务器安装 TUI 版，以保留现有安装。' >&2
  exit 1
fi
exec 8>/run/dual-protocol-script-tui-install.lock
flock -w 30 8
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ca-certificates curl tar python3 python3-yaml openssl iproute2 acl procps

source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
temporary=""
staged=""
cleanup() { [[ -z "$temporary" ]] || rm -rf -- "$temporary"; [[ -z "$staged" ]] || rm -rf -- "$staged"; }
trap cleanup EXIT
if [[ ! -f "$source_dir/lib/node-menu.sh" || ! -f "$source_dir/scripts/keys.py" ]]; then
  repo="${REPO:-Aki1106-0116/dual-protocol-script-tui}"
  [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo 'REPO 格式无效' >&2; exit 1; }
  temporary="$(mktemp -d /tmp/dual-protocol-script-tui-source.XXXXXX)"
  curl -fsSL --retry 3 "https://github.com/$repo/archive/refs/heads/main.tar.gz" -o "$temporary/source.tar.gz"
  mkdir "$temporary/source"
  tar -xzf "$temporary/source.tar.gz" -C "$temporary/source" --strip-components=1
  source_dir="$temporary/source"
fi
for file in node-installer.sh lib/node-common.sh lib/node-services.sh lib/node-transaction.sh lib/node-menu.sh scripts/storage.py scripts/keys.py; do
  [[ -s "$source_dir/$file" ]] || { echo "源码包缺少 $file" >&2; exit 1; }
done

# Hold the same lock as interactive operations while replacing modules.
exec 9>/run/dual-protocol-script-tui-config.lock
flock -w 30 9
library=/usr/local/lib/dual-protocol-script-tui
mkdir -p "$library/versions" /usr/local/bin
chmod 700 "$library" "$library/versions"
staged="$(mktemp -d "$library/versions/build.XXXXXX")"
mkdir "$staged/lib"
chmod 700 "$staged/lib"
for module in node-common node-services node-transaction node-menu; do
  install -m600 "$source_dir/lib/$module.sh" "$staged/lib/$module.sh"
done
for helper in storage keys; do
  install -m600 "$source_dir/scripts/$helper.py" "$staged/$helper.py"
done
install -m755 "$source_dir/node-installer.sh" "$staged/node-installer.sh"
"$staged/node-installer.sh" --help >/dev/null
link_candidate="$library/next-${BASHPID}-${RANDOM}"
ln -s "$staged" "$link_candidate"
mv -Tf "$link_candidate" "$library/current"
staged=""
candidate="$(mktemp /usr/local/bin/dual-protocol-script-tui.XXXXXX)"
cat > "$candidate" <<'WRAPPER'
#!/usr/bin/env bash
exec /usr/local/lib/dual-protocol-script-tui/current/node-installer.sh "$@"
WRAPPER
chmod 755 "$candidate"
mv -f "$candidate" /usr/local/bin/dual-protocol-script-tui
if [[ ! -e /usr/bin/dual-protocol-script-tui || -L /usr/bin/dual-protocol-script-tui && "$(readlink /usr/bin/dual-protocol-script-tui)" == /usr/local/bin/dual-protocol-script-tui ]]; then
  ln -sfn /usr/local/bin/dual-protocol-script-tui /usr/bin/dual-protocol-script-tui
fi
if [[ ! -e /usr/local/bin/tui || -L /usr/local/bin/tui && "$(readlink /usr/local/bin/tui)" == /usr/local/bin/dual-protocol-script-tui ]]; then
  ln -sfn /usr/local/bin/dual-protocol-script-tui /usr/local/bin/tui
else
  echo '现有 tui 命令保留；本版本使用 dual-protocol-script-tui 命令。' >&2
fi
if [[ ! -e /usr/bin/tui || -L /usr/bin/tui && "$(readlink /usr/bin/tui)" == /usr/local/bin/dual-protocol-script-tui ]]; then
  ln -sfn /usr/local/bin/dual-protocol-script-tui /usr/bin/tui
fi
flock -u 9
exec 9>&-
echo 'TUI 管理命令已安装：dual-protocol-script-tui（或 tui）'
if [[ "${1:-}" != --update ]]; then "$library/current/node-installer.sh" menu; fi
