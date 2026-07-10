# macdeepsleep

GitHub: https://github.com/EAEdward/macdeepsleep

合盖休眠自动关 Wi-Fi，开盖唤醒自动开。原生 Objective-C 程序通过 IOKit 监听电源事件。

## 架构

- **零外部依赖**，不需要 sleepwatcher 或 Homebrew
- 一个 ~130 行 Objective-C 程序（`macdeepsleep.m`），仅编译 arm64
- 通过 IOKit `IORegisterForSystemPower` 注册电源回调
- 通过 `CoreWLAN` 控制 Wi-Fi，`ioctl` 控制 AWDL，私有 API 控制蓝牙，实现极速响应（<100ms）
- 合盖时记录 Wi-Fi + 蓝牙 + AWDL 状态 → 关闭三者；开盖时按原状恢复
- 由 LaunchDaemon 守护（KeepAlive），事件驱动

## 操作规约（agent 必须遵守）

1. **发布须指令** — 不要立即推送改动到 GitHub。只有用户明确说「发布」或「推」之后，才执行 `git push` 和 `gh release`。
2. **一键安装可用** — 每次发布前必须验证：`curl -fsSL https://raw.githubusercontent.com/EAEdward/macdeepsleep/main/install.sh | sudo bash` 能正常工作。
3. **发布预编译二进制** — release 必须附带 arm64 二进制（`clang -arch arm64`）。install.sh 从 release 下载预编译版本。
4. **中文发布** — GitHub release notes 用中文撰写。

## 文件结构

```
macdeepsleep/
├── macdeepsleep.m       # 源码（~130 行 Objective-C）
├── install.sh           # 全功能安装脚本（支持安装、更新、卸载）
├── README.md
└── LICENSE
```

## 核心逻辑

`macdeepsleep.m` 在 CFRunLoop 中等待 IOKit 电源消息：

- `kIOMessageSystemWillSleep` → 记录 Wi-Fi、蓝牙、AWDL 状态到 `/var/tmp/macdeepsleep.state` → 同步关闭三者 → `IOAllowPowerChange`
- `kIOMessageSystemHasPoweredOn` → 按睡前记录状态（或内存状态）同步恢复三者

## 安装/卸载

```bash
sudo bash install.sh                   # 安装或更新（幂等）
sudo bash install.sh --uninstall       # 卸载
```

安装路径：
- 二进制: `/usr/local/bin/macdeepsleep`
- plist: `/Library/LaunchDaemons/com.eaedward.macdeepsleep.plist`
- 日志: `/var/log/macdeepsleep.log`

## 调试

```bash
log show --predicate 'process == "macdeepsleep"' --last 1h
sudo launchctl list | grep macdeepsleep
```

## 注意事项

- **macOS only** — 依赖 IOKit、CoreWLAN 和 IOBluetooth
- **arm64 only** — 仅编译 arm64，因 `clang -arch arm64` 编译
- 编译需要 Xcode Command Line Tools（`xcode-select --install`）
- 安装时必须有 sudo / root 权限，因为运行于 LaunchDaemon
