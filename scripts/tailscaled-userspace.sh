#!/bin/sh
# 幂等启动 tailscaled（userspace-networking + SOCKS5），无 systemd / 无 TUN 的容器可用。
#
# 用法：
#   sh scripts/tailscaled-userspace.sh
#   TAILSCALE_SOCKS=127.0.0.1:9050 sh scripts/tailscaled-userspace.sh
#
# 为什么这么写：
#   * --tun=userspace-networking：容器没有 /dev/net/tun，不能创建内核 TUN；
#   * --socks5-server 只绑 127.0.0.1：绑 0.0.0.0 等于把 tailnet 出口开放给同网段；
#   * --state=...：状态落盘，进程被平台回收后不用重新登录；
#   * 脚本幂等：已在运行就跳过，配合「重启清单」可反复执行；
#   * 轮询等待 socket 出现，返回时服务已真正可用，而不是「刚 fork 完」。
set -eu

STATE=${TAILSCALE_STATE:-/var/lib/tailscale/tailscaled.state}
SOCKET=${TAILSCALE_SOCKET:-/run/tailscale/tailscaled.sock}
SOCKS=${TAILSCALE_SOCKS:-127.0.0.1:1055}
LOG=${TAILSCALE_LOG:-/tmp/tailscaled.log}
BIN=${TAILSCALE_BIN:-tailscaled}
CLI=${TAILSCALE_CLI:-tailscale}

echo "== tailscaled (userspace) =="

if ! command -v "$BIN" >/dev/null 2>&1; then
    echo "找不到 $BIN。请先安装静态二进制，或设置 TAILSCALE_BIN=/path/to/tailscaled" >&2
    exit 1
fi

case "$SOCKS" in
    127.0.0.1:*|localhost:*|'[::1]':*) ;;
    *) echo "警告：SOCKS5 应只绑回环地址，当前为 $SOCKS" >&2 ;;
esac

if [ -e /dev/net/tun ]; then
    echo "提示：检测到 /dev/net/tun，内核态模式性能更好；本脚本仍按 userspace 启动。"
fi

running=0
if command -v pgrep >/dev/null 2>&1; then
    pgrep -x tailscaled >/dev/null 2>&1 && running=1
else
    ps 2>/dev/null | grep -q '[t]ailscaled' && running=1
fi

if [ "$running" -eq 1 ]; then
    echo "tailscaled 已在运行，跳过启动。"
else
    mkdir -p "$(dirname "$STATE")" "$(dirname "$SOCKET")"
    nohup "$BIN" \
        --tun=userspace-networking \
        --socks5-server="$SOCKS" \
        --state="$STATE" \
        --socket="$SOCKET" \
        >"$LOG" 2>&1 &
    echo $! >/tmp/tailscaled.pid
    echo "已拉起 PID $(cat /tmp/tailscaled.pid)，日志：$LOG"
fi

i=0
while [ "$i" -lt 40 ]; do
    [ -S "$SOCKET" ] && break
    i=$((i + 1))
    sleep 0.5
done
if [ ! -S "$SOCKET" ]; then
    echo "socket 未就绪：$SOCKET，请查看 $LOG" >&2
    exit 1
fi
echo "socket 就绪：$SOCKET"
echo "SOCKS5   ：$SOCKS"

if command -v "$CLI" >/dev/null 2>&1; then
    echo "-- tailscale status --"
    "$CLI" --socket="$SOCKET" status 2>&1 | head -20 || true
else
    echo "提示：找不到 $CLI，跳过 status（不影响代理可用性）"
fi

echo
echo "若尚未登录： $CLI up --authkey=tskey-xxx   或   $CLI login"
echo "验证连通： curl --proxy socks5h://$SOCKS https://example.com -o /dev/null -w '%{http_code}\\n'"
