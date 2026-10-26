# dual-protocol-script-tui

基于已通过实机测试的 `dual-protocol-script-fix` 节点后端派生的独立终端版。
使用 Shell 主流程，保留按需执行的 Python 配置处理和 OpenSSL 密钥验证。

支持且仅支持两种组合：

- **VLESS XHTTP + TLS + Hysteria2**：两个不同的直连域名；Caddy 负责 TLS、续期、XHTTP 转发与伪装站。
- **VLESS REALITY Vision + Hysteria2**：REALITY 使用 TCP 443；HY2 使用自己的 ACME 证书。

没有网页管理面板、面板账号/端口/随机路径、Go 管理服务、家宽出口网关或后台出口巡检。保留的 Caddy 网页是 XHTTP 协议组合的伪装站，不提供管理功能。TCP Brutal 和 Mimic 不包含在本版本中。

## 安装

要求 Debian/Ubuntu、systemd、root。域名直连 VPS，首次签发时关闭 CDN 代理；放行 TCP 80/443 和 HY2 的 UDP 单端口或跳跃范围。

将本目录全部内容上传到 **Aki1106-0116/dual-protocol-script-tui** 仓库根目录。发布后，以 root 执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Aki1106-0116/dual-protocol-script-tui/main/install.sh)
```

本地源码安装：

```bash
bash install.sh
```

仅更新已经安装的 TUI 程序，保留节点参数：

```bash
bash install.sh --update
```

安装器部署完整的版本目录，然后原子切换管理入口；已经打开的菜单继续使用它所加载的那一版模块和辅助程序，避免升级时混用文件。

这是独立部署版本。两版均使用标准 Xray/HY2 服务与配置路径，因此安装器检测到现有 fix 版会停止，不覆盖、停用或删除它；请在独立服务器部署 TUI 版。本电脑上的 fix 源码与 ZIP 也独立保留。

## 随时管理

安装后执行：

```bash
tui
```

完整命令名为 `dual-protocol-script-tui`。如果系统已有其他 `tui` 命令，安装器保留它，使用完整命令名进入本版本。

菜单提供节点名称、UUID、客户端指纹、REALITY 地址/SNI/密钥、XHTTP 域名/路径、HY2 域名/密码/端口跳跃/Gecko 的修改，以及分享链接、客户端配置、状态、日志、单独/全部重启、组合切换和卸载。

快捷命令：

```bash
dual-protocol-script-tui info
dual-protocol-script-tui status
dual-protocol-script-tui restart
dual-protocol-script-tui log
dual-protocol-script-tui uninstall
```

配置与分享文件位于 `/root/dual-protocol-script-tui/`，包括两条分享链接、Xray 客户端 JSON、HY2 客户端 YAML/JSON 和节点详情。状态位于 `/etc/dual-protocol-script-tui/state.env`，管理程序位于 `/usr/local/lib/dual-protocol-script-tui/`。

## 服务与正确性

TUI 随时可以打开，退出后不需要常驻管理程序。Xray、HY2 和当前组合需要的 Caddy 仍由 systemd 运行：异常退出后按 5 秒间隔自动重启，并限制连续失败的重试频率。手动停止和组合切换期间不会被自动重启打断。TUI 重启会重置失败限流状态、检查启动结果并在失败时显示日志。

自动重启针对进程退出；仍在运行的进程遇到外网故障，不会被脚本盲目反复重启。可随时使用 TUI 的状态、日志和重启选项排查。

配置修改、组合切换使用共享锁、校验、原子写入和失败回滚。读取故障会尝试经过校验和验证的 `.recovery` 副本；无法恢复时拒绝保存/重启，保留已运行服务。修改失败返回菜单，读回实际已保存状态；不把请求值当成成功结果。客户端导出部分写入失败也恢复原输出目录中的旧文件。

只保留节点 TLS 所需的证书管理：未改域名复用已有缓存，改域名才进入对应签发流程，正常自动续期保留。XHTTP 配置使用真实 Caddy 校验器检查候选文件后提交。

可选 Swap、Gecko、全部端口跳跃设置保留。卸载只清理本版本管理的节点与命令，保留已有 Swap、系统内核与无关系统包。

## 验证

```bash
for script in *.sh lib/*.sh scripts/*.sh; do bash -n "$script"; done
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts -p 'test_*.py'
bash scripts/test_backend.sh
```

独立 Linux 测试机可额外执行真实 systemd 重启与锁测试：

```bash
DPS_RUN_INTEGRATION=1 bash scripts/test_linux.sh
```

测试结果与边界见 [VALIDATION.md](VALIDATION.md)，来源与许可见 [NOTICE.md](NOTICE.md) 和 [LICENSE](LICENSE)。
