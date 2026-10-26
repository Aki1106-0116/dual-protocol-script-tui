# TUI 版验证记录

## 实现范围

从本电脑已通过测试的最新版 fix 节点后端派生，使用独立源码目录、独立安装目录和独立状态目录。原 fix 源码及 ZIP 保持不变。

只交付 Bash 节点/TUI 管理、Python 存储与密钥辅助、文档和测试。没有 Go 工程、管理 HTTP 服务、前端管理资源、VPN Gate/OpenVPN 出口代码或管理守护进程。协议客户端导出和 REALITY 的短时自检保留原有本地 SOCKS 用途，不是出口网关。

两种协议组合的配置生成、Core 版本兼容、Gecko、端口跳跃、指纹、密钥轮换、Swap 和客户端导出沿用经过修复的节点实现。TUI 新增完整参数菜单、服务状态/日志、单独及全部重启。

## 已通过的检查

测试环境：Windows Git Bash/Python/OpenSSL；隔离 Ubuntu 24.04 虚拟机，真实 systemd、Bash、OpenSSL 3、Python/YAML、Caddy 2.6.2。

| 检查 | 结果 |
|---|---|
| Bash 语法 | 全部脚本通过 |
| ShellCheck error 级检查 | 全部脚本通过 |
| Python 回归 | Windows/Linux 18 项通过，含 I/O 恢复、失败原子替换、校验和、无效 JSON/YAML、危险赋值、备份失败、读回失败及 OpenSSL X25519 独立验证 |
| 两种组合配置与导出 | Bash 回归通过，含特殊字符密码、端口跳跃、Gecko、Xray/HY2 客户端 JSON/YAML |
| 菜单失败处理 | 无效修改返回菜单，状态保持原内容 |
| 损坏状态 | 拒绝把读取失败当成新安装，不创建默认节点覆盖配置 |
| 首次安装失败 | 停止并禁用此次核心服务，清除半套配置及恢复记录；下载依赖和证书缓存可保留供重试 |
| 服务启动失败 | 修改前的状态、协议配置和分享文件恢复 |
| 真实 Caddy 校验 | 候选文件成功校验后提交；未改变配置不重启 Caddy；域名变更只进入相应签发分支 |
| 部分导出提交失败 | 旧状态、分享链接和客户端配置恢复到真实输出目录，无残留 stage 目录 |
| 共享 flock | 子操作继承持锁信息不重复等待，独立操作不能抢锁，释放后可获得锁 |
| 真实 systemd 自动重启 | 自建隔离测试服务第一次退出 1，约定的重启策略实际拉起服务，`NRestarts=1`；手动停止后保持停止 |
| 手动服务重启 | 重置失败限流；任何服务健康检查失败都报告失败并显示日志 |
| 安装与升级 | 完整版本目录原子切换、旧版本仍可执行、CLI 帮助和路径别名通过 |
| fix 保护 | 安装器遇到现有 fix 安装拒绝覆盖；隔离测试中 fix 测试文件按校验和完整恢复；本电脑 fix 源码逐文件 SHA-256 与派生前一致 |

关键输出：

```text
TUI_FAILED_EDIT_RETURNS_TO_MENU_OK
CORRUPT_STATE_DOES_NOT_REINSTALL_OK
FIRST_INSTALL_FAILURE_CLEANUP_OK
RESTART_CHECK_REPORTS_FAILURE_AND_RESETS_LIMIT_OK
REAL_CADDY_COMMIT_AND_NODE_CERT_BRANCHES_OK
PARTIAL_EXPORT_FAILURE_RESTORES_REAL_DESTINATION_OK
SHARED_LOCK_INHERITANCE_AND_SERIALIZATION_OK
SYSTEMD_UNEXPECTED_EXIT_RESTART_OK restarts=1
SYSTEMD_MANUAL_STOP_REMAINS_STOPPED_OK
INSTALLER_PRESERVES_EXISTING_FIX_OK
ATOMIC_DEPLOY_UPGRADE_AND_CLI_ALIASES_OK
```

额外修复了导出函数局部变量遮蔽真实输出目录的问题：导出部分提交失败时，旧实现的退出回滚可能在 stage 目录中重新生成文件；TUI 版使用隔离生成环境，回滚始终写回实际输出目录。验证之前先检查请求参数，避免无效输入触发无必要的服务重启。

## 运行与验证边界

没有新增常驻管理服务或定时管理进程。关闭 TUI 后，保留的常驻进程只有协议组合所需的核心程序；Python/OpenSSL 仅在管理操作中执行。systemd 针对进程退出自动重启，不能据此声称能自动识别所有活进程的网络故障。连续失败有频率限制，TUI 的重启操作会重置失败状态。

本轮使用了真实 Caddy 校验器和 systemd；外部协议服务的配置事务与公开 ACME 签发分支使用测试替身。安装部署烟测替换 APT 调用，验证部署、升级和保护逻辑，没有在 Windows 安装系统服务。未对新 TUI 版进行用户公网域名的完整首次签发、完整公网安装和真实 Xray/HY2 客户端吞吐测试；这些节点实现来自用户已验收的 fix 后端，本记录不把继承实现等同于新环境已实测。

永久损坏的磁盘无法由脚本修复；读回/恢复失败时保留运行服务并拒绝不安全操作，备份和错误信息用于恢复。

X25519 ASN.1 格式依据 [RFC 8410](https://www.rfc-editor.org/rfc/rfc8410.html)，OpenSSL 实际派生结果用于验证公私钥配对；未自行实现曲线算法。
