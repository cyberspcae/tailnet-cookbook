#!/bin/sh
# 经 tailnet SOCKS5 代理登录设备，自动选择可用的 ProxyCommand 实现。
#
# 用法：
#   sh scripts/ssh-via-socks5.sh root@100.x.y.z -p 2222
#   sh scripts/ssh-via-socks5.sh user@host.ts.net
#
# 为什么需要这个脚本：
#   * userspace-networking 没有虚拟网卡，SSH 必须显式走 SOCKS5；
#   * BusyBox 的 nc 不支持 -X（SOCKS5），OpenBSD netcat 支持；ncat 也要换写法；
#   * ProxyCommand 必须把 %h 原样交给代理解析，否则 *.ts.net（MagicDNS）解析不了；
#   * 用 socks5h / 代理端解析，而不是本地 DNS。
set -eu

SOCKS=${TAILSCALE_SOCKS:-127.0.0.1:1055}

if [ $# -eq 0 ]; then
    echo "用法： sh $0 user@host [ssh 参数...]" >&2
    echo "示例： sh $0 root@100.x.y.z -p 2222" >&2
    exit 2
fi

PROXY=""
if command -v nc >/dev/null 2>&1 && \
   { nc -h 2>&1 || nc --help 2>&1; } | grep -q -- '-X'; then
    # OpenBSD netcat：-X 5 = SOCKS5，-x 指定代理
    PROXY="nc -X 5 -x $SOCKS %h %p"
elif command -v ncat >/dev/null 2>&1; then
    PH=${SOCKS%:*}
    PP=${SOCKS##*:}
    PROXY="ncat --proxy-type socks5 --proxy $PH:$PP %h %p"
else
    cat >&2 <<'EOF'
找不到支持 SOCKS5 的 ProxyCommand 后端。请任选其一：
  * 安装 OpenBSD netcat（Debian/Ubuntu: apt install netcat-openbsd）
  * 安装 nmap 提供的 ncat
  * 或用 Python 标准库写一个 SOCKS5 转发器后，用 -o ProxyCommand=... 指定
注意：BusyBox 自带的 nc 不支持 -X。
EOF
    exit 1
fi

echo "ProxyCommand: $PROXY" >&2
echo "代理      : $SOCKS" >&2
echo "提示：目标主机名由代理端解析，可用 *.ts.net（MagicDNS）名字。" >&2

exec ssh \
    -o ProxyCommand="$PROXY" \
    -o ConnectTimeout=20 \
    -o ServerAliveInterval=15 \
    -o ServerAliveCountMax=3 \
    -o StrictHostKeyChecking=accept-new \
    "$@"
