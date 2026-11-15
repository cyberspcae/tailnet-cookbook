#!/bin/sh
# tailnet 健康检查：一次看完进程 / socket / SOCKS5 / status / 代理连通性。
#
# 用法：
#   sh scripts/healthcheck.sh
#   sh scripts/healthcheck.sh --url https://api.github.com
#   TAILSCALE_SOCKS=127.0.0.1:9050 sh scripts/healthcheck.sh
#
# 设计要点：
#   * 逐项检查、汇总退出码，不用 set -e（一项失败也要把其余项看完）；
#   * 端口检测用 Python 标准库 socket，避开各家 nc 参数差异；
#   * 用环境变量把 host/port 传进 python -c，不拼字符串，避免注入；
#   * 检查 SOCKS5 是否被绑到 0.0.0.0（常见误配置）。
SOCKET=${TAILSCALE_SOCKET:-/run/tailscale/tailscaled.sock}
SOCKS=${TAILSCALE_SOCKS:-127.0.0.1:1055}
CLI=${TAILSCALE_CLI:-tailscale}
HOST=${SOCKS%:*}
PORT=${SOCKS##*:}
URL=""
FAIL=0

while [ $# -gt 0 ]; do
    case "$1" in
        --url) URL=${2:-}; shift 2 ;;
        *) echo "未知参数：$1" >&2; shift ;;
    esac
done

ok()   { printf '  [ OK ] %s\n' "$1"; }
bad()  { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
warn() { printf '  [WARN] %s\n' "$1"; }

echo "== tailnet healthcheck ==  ($SOCKS)"

# 1. 进程
if command -v pgrep >/dev/null 2>&1 && pgrep -x tailscaled >/dev/null 2>&1; then
    ok "tailscaled 进程存在"
elif ps 2>/dev/null | grep -q '[t]ailscaled'; then
    ok "tailscaled 进程存在"
else
    bad "tailscaled 未运行 —— 先执行 scripts/tailscaled-userspace.sh"
fi

# 2. socket
if [ -S "$SOCKET" ]; then
    ok "控制 socket 存在：$SOCKET"
else
    bad "控制 socket 缺失：$SOCKET"
fi

# 3. SOCKS5 端口可达
if command -v python3 >/dev/null 2>&1; then
    if HOST="$HOST" PORT="$PORT" python3 -c \
        'import os, socket; socket.create_connection((os.environ["HOST"], int(os.environ["PORT"])), timeout=2).close()' \
        >/dev/null 2>&1; then
        ok "SOCKS5 端口可达"
    else
        bad "SOCKS5 端口连不上（$SOCKS）"
    fi
elif command -v nc >/dev/null 2>&1 && nc -z "$HOST" "$PORT" >/dev/null 2>&1; then
    ok "SOCKS5 端口可达（nc -z）"
else
    warn "无法检测端口（缺 python3 与 nc -z）"
fi

# 4. 是否误绑 0.0.0.0
if command -v netstat >/dev/null 2>&1; then
    if netstat -tln 2>/dev/null | grep -Eq "0\.0\.0\.0:$PORT[[:space:]]|:::$PORT[[:space:]]"; then
        bad "SOCKS5 似乎绑到了 0.0.0.0 —— 改回 127.0.0.1"
    else
        ok "SOCKS5 未对全部接口开放"
    fi
else
    warn "无 netstat，跳过绑定地址检查"
fi

# 5. tailscale status
if command -v "$CLI" >/dev/null 2>&1 && [ -S "$SOCKET" ]; then
    ST=$("$CLI" --socket="$SOCKET" status 2>&1) || ST=""
    if [ -n "$ST" ]; then
        ok "tailscale status 有输出"
        echo "$ST" | head -12 | sed 's/^/         /'
        if echo "$ST" | grep -qi 'offline'; then
            warn "有节点 offline（移动端锁屏/后台挂起很常见，先唤醒对端再判断）"
        fi
        if echo "$ST" | grep -qi 'relay'; then
            warn "存在 DERP 中继链路，延迟/抖动属正常，关键操作请加重试"
        fi
    else
        bad "tailscale status 无输出（可能未登录）"
    fi
else
    warn "跳过 status（缺 CLI 或 socket）"
fi

# 6. 代理连通性（可选）
if [ -n "$URL" ]; then
    if command -v curl >/dev/null 2>&1; then
        CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
               --proxy "socks5h://$SOCKS" "$URL" 2>/dev/null || echo 000)
        if [ "$CODE" = "000" ]; then
            bad "经代理访问 $URL 失败"
        else
            ok "经代理访问 $URL → HTTP $CODE（注意 403 也可能是未认证，非网络问题）"
        fi
    else
        warn "无 curl，跳过代理 HTTP 测试"
    fi
fi

echo
if [ "$FAIL" -eq 0 ]; then
    echo "结论：健康检查通过。若仍连不上，先看 PITFALLS.md 第 2 节（DNS / 验证手段）。"
    exit 0
fi
echo "结论：$FAIL 项失败。按上面 [FAIL] 逐条处理。"
exit 1
