#!/bin/bash
set -euo pipefail

BIN_DEST="/usr/local/bin/macdeepsleep"
DAEMON_PLIST="/Library/LaunchDaemons/com.eaedward.macdeepsleep.plist"
LOG_FILE="/var/log/macdeepsleep.log"

if [[ -n "${SUDO_USER:-}" ]]; then
    USER_HOME="$(dscl . -read "/Users/$SUDO_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
    [[ -n "$USER_HOME" ]] || USER_HOME="$HOME"
else
    USER_HOME="$HOME"
fi

OLD_AGENT_PLIST="$USER_HOME/Library/LaunchAgents/com.eaedward.macdeepsleep.plist"
OLD_SUDOERS="/etc/sudoers.d/wifi-automation"
OLD_STATE="$HOME/.macdeepsleep.state"
OLD_BREW_PLIST="$USER_HOME/Library/LaunchAgents/homebrew.mxcl.sleepwatcher.plist"
OLD_SCRIPT_DIR="$USER_HOME/.sleepwatcher"

info()  { printf "\033[36m%s\033[0m\n" "$*"; }
ok()    { printf "\033[32m  ✓ %s\033[0m\n" "$*"; }
warn()  { printf "\033[33m  ! %s\033[0m\n" "$*"; }
fail()  { printf "\033[31m  ✗ %s\033[0m\n" "$*"; exit 1; }

check_sudo() {
    if [[ $EUID -ne 0 ]]; then
        fail "此脚本必须以 root 权限运行，请使用 sudo bash install.sh"
    fi
}

launchctl_as_user() {
    if [[ -n "${SUDO_USER:-}" ]]; then
        sudo -u "$SUDO_USER" launchctl "$@"
    else
        launchctl "$@"
    fi
}

clean_v1() {
    local cleaned=0
    if [[ -f "$OLD_AGENT_PLIST" ]]; then
        launchctl_as_user unload "$OLD_AGENT_PLIST" 2>/dev/null || true
        rm -f "$OLD_AGENT_PLIST"
        cleaned=1
    fi
    if [[ -f "$OLD_SUDOERS" ]]; then
        rm -f "$OLD_SUDOERS"
        cleaned=1
    fi
    if [[ -f "$OLD_STATE" ]]; then
        rm -f "$OLD_STATE"
        cleaned=1
    fi
    if [[ "$cleaned" -eq 1 ]]; then
        info "已清理 v1 旧版 (LaunchAgent + sudoers)"
    fi
}

clean_old_sleepwatcher() {
    if [[ -f "$OLD_BREW_PLIST" ]]; then
        launchctl_as_user unload "$OLD_BREW_PLIST" 2>/dev/null || true
        rm -f "$OLD_BREW_PLIST"
        rm -rf "$OLD_SCRIPT_DIR" 2>/dev/null || true
        info "已清理旧版本 (sleepwatcher)"
    fi
}

deploy_bin() {
    if [[ -f "./macdeepsleep" ]]; then
        info "── 使用本地已编译的 macdeepsleep 二进制 ──"
        cp "./macdeepsleep" "$BIN_DEST"
    else
        local tmp_bin
        tmp_bin="$(mktemp /tmp/macdeepsleep.XXXXXX)"
        info "── 下载 macdeepsleep ──"
        curl -fL -o "$tmp_bin" \
            "https://github.com/EAEdward/macdeepsleep/releases/latest/download/macdeepsleep" || {
            rm -f "$tmp_bin"
            fail "下载失败，请检查网络连接"
        }
        cp "$tmp_bin" "$BIN_DEST"
        rm -f "$tmp_bin"
    fi
    chown root:wheel "$BIN_DEST"
    chmod 755 "$BIN_DEST"
    ok "二进制 → $BIN_DEST"
}

deploy_plist() {
    info "── 配置 LaunchDaemon ──"
    cat > "$DAEMON_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>com.eaedward.macdeepsleep</string>
	<key>ProgramArguments</key>
	<array>
		<string>/usr/local/bin/macdeepsleep</string>
	</array>
	<key>KeepAlive</key>
	<true/>
	<key>RunAtLoad</key>
	<true/>
	<key>StandardErrorPath</key>
	<string>${LOG_FILE}</string>
</dict>
</plist>
PLIST
    chown root:wheel "$DAEMON_PLIST"
    chmod 644 "$DAEMON_PLIST"
    ok "plist → $DAEMON_PLIST"
}

do_install() {
    check_sudo
    [[ "$(uname)" = "Darwin" ]] || fail "仅支持 macOS"

    local is_update=0
    [[ -f "$BIN_DEST" ]] && is_update=1

    clean_old_sleepwatcher
    clean_v1
    
    deploy_bin
    deploy_plist

    info "── 启动守护进程 ──"
    launchctl unload "$DAEMON_PLIST" 2>/dev/null || true
    launchctl load "$DAEMON_PLIST"
    ok "LaunchDaemon 已加载"

    if [[ "$is_update" = "1" ]]; then
        printf "\n\033[32m✓ 更新完成 (v2.1.0).\033[0m\n"
    else
        printf "\n\033[32m✓ 安装完成 (v2.1.0).\033[0m  合盖试试效果。\n"
    fi
    printf "  日志: log show --predicate 'process == \"macdeepsleep\"' --last 1h\n"
}

do_uninstall() {
    check_sudo

    info "── 终止残留进程 ──"
    killall macdeepsleep 2>/dev/null || true

    info "── 停止守护 ──"
    if launchctl unload "$DAEMON_PLIST" 2>/dev/null; then
        ok "已停止 LaunchDaemon"
    fi
    clean_v1

    info "── 删除 plist ──"
    rm -f "$DAEMON_PLIST"
    ok "plist 已删除"

    info "── 删除二进制 ──"
    rm -f "$BIN_DEST"
    ok "二进制已删除"

    clean_old_sleepwatcher
    printf "\n\033[32m✓ 已卸载.\033[0m\n"
}

show_menu() {
    local has_curr_flag=0
    [[ -f "$BIN_DEST" ]] && has_curr_flag=1

    printf "\n  \033[36m━━━ macdeepsleep v2.1.0 ━━━\033[0m\n\n"

    if [[ "$has_curr_flag" = "1" ]]; then
        printf "  当前版本已安装\n\n"
        printf "  1) 更新 / 修复安装\n"
        printf "  2) 卸载\n"
    else
        printf "  1) 安装\n"
    fi
    printf "  0) 退出\n"
    printf "\n  请输入数字: "
    read -r choice
    printf "\n"

    case "$choice" in
        1) do_install ;;
        2) [[ "$has_curr_flag" = "1" ]] && do_uninstall || warn "无效输入" ;;
        0) exit 0 ;;
        *) warn "无效输入"; exit 1 ;;
    esac
}

case "${1:-}" in
    install|update|--update)
        do_install ;;
    --uninstall|uninstall)
        do_uninstall ;;
    "")
        if [[ ! -t 0 ]]; then
            do_install
        else
            show_menu
        fi ;;
    *)
        echo "用法: sudo bash $0 [install|update|--uninstall]"
        echo "  无参数：交互式菜单"
        exit 1 ;;
esac
