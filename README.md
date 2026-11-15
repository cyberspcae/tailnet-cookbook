# tailnet-cookbook

> 在**没有 root 能力、没有 `/dev/net/tun`、没有 systemd** 的容器 / 沙箱里，把 Tailscale 跑起来，
> 并稳定地做远程访问与排障。含可直接执行的脚本 + 完整踩坑记录。

## 适用场景

一台隔离云端沙箱想访问 tailnet 里的另一台设备（例如手机上的 SSH、家里 NAS、远程开发机），但：

- 容器无法创建 TUN 设备（缺 `CAP_NET_ADMIN`）；
- 没有 systemd，`systemctl` 不可用；
- 后台进程可能被平台回收，随时要能一键恢复；
- 只需要「从沙箱主动连出去」，不需要把沙箱变成全子网网关；
- 目标设备可能休眠 / 掉线（iOS 尤其常见），链路时不时会抖。

这套方案在这类环境下实际跑通过：GitHub API、SSH、网页抓取都通过 tailnet 侧的 SOCKS5 出口完成。

> 配套仓库 [`cyberspcae/ai-reusable-toolkit`](https://github.com/cyberspcae/ai-reusable-toolkit) 收录了通用工具；本仓库只聚焦 Tailscale 这一个主题。

## 架构（ userspace 模式的关键差异）

```
  沙箱内的应用
      │  显式配置代理 / ProxyCommand
      ▼
  tailscaled --tun=userspace-networking
      └── socks5-server=127.0.0.1:1055   ← 只监听本机
                │  (加密隧道 / DERP 中继)
                ▼
          tailnet 内的目标节点 (100.x.y.z 或 *.ts.net)
```

**最重要的一点**：`userspace-networking` 模式**不会**给沙箱装一张虚拟网卡，
所以「本机 `ping 100.x.y.z` 不通」「`curl` 不走 tailnet」都是**正常现象**，不是配置失败。
只有显式走 SOCKS5 的流量才进隧道。很多排查时间都浪费在误以为「没连上」。

## 快速开始

```bash
# 0. 先体检（可选，来自 ai-reusable-toolkit）
python3 ../ai-reusable-toolkit/tools/probe_environment.py --human

# 1. 幂等启动 tailscaled（userspace + SOCKS5，状态落盘）
sh scripts/tailscaled-userspace.sh

# 2. 登录 / 接入 tailnet（二选一）
tailscale up --authkey=tskey-xxx        # 无人值守，推荐
tailscale login                          # 交互式

# 3. 确认状态与代理可达
sh scripts/healthcheck.sh

# 4. 通过 SOCKS5 访问
curl --proxy socks5h://127.0.0.1:1055 https://api.github.com/user -H "Authorization: Bearer $TOKEN"

# 5. SSH 到 tailnet 内的设备
sh scripts/ssh-via-socks5.sh root@100.x.y.z -p 2222
```

配置片段可直接 `Include` 进 `~/.ssh/config`：见 [`config/ssh_config.snippet`](config/ssh_config.snippet)。
环境变量样例：[`config/env.example`](config/env.example)。

## 三种访问方式怎么选

| 方式 | 命令要点 | 适用 | 注意 |
|---|---|---|---|
| SOCKS5 代理 | `curl --proxy socks5h://...`、`requests` 的 `proxies` | 临时访问 HTTP/HTTPS | 必须 `socks5h`（远端解析 DNS），普通 `socks5` 解析不了 `*.ts.net` |
| SSH ProxyCommand | `ProxyCommand='nc -X 5 -x 127.0.0.1:1055 %h %p'` | 登录 tailnet 内设备 | 需要 OpenBSD 版 netcat；BusyBox `nc` 不支持 `-X` |
| `tailscale serve` | `tailscale serve --http=80 8080` | 把沙箱内 Web 服务暴露给 tailnet | 默认 HTTPS 在受限环境常被拦；不要开 funnel（公网） |

## 验证清单

- [ ] `tailscale status` 能看到自己与对端，且标注 `direct` 或 `relay`（DERP）
- [ ] `127.0.0.1:1055` 处于 LISTEN，且**没有**绑到 `0.0.0.0`
- [ ] `curl --proxy socks5h://127.0.0.1:1055 https://...` 返回预期状态码
- [ ] SSH 经 ProxyCommand 能登录
- [ ] 状态文件已落盘（重启后不需要重新 `login`）
- [ ] 已做「直连 vs 走代理」基准对照，确认链路差异不是认证或 WAF 造成的

## 安全须知

- SOCKS5 只绑 `127.0.0.1`；绑到 `0.0.0.0` 等于把 tailnet 出口开放给同网段所有人。
- **不要开 funnel**，除非明确要把服务放到公网；tailnet 内部访问已经够用。
- authkey 用一次性 / 短期、带 tag 的；用完 `tailscale logout` 或在管理后台吊销。
- 本仓库不含任何真实节点 IP、tailnet 域名、authkey、SSH 口令；示例中的 `100.x.y.z`、`*.ts.net`、`tskey-xxx` 都是占位符。
- ACL 按最小权限写：沙箱节点只应能访问它确实需要的端口。

## 文档

- [`PITFALLS.md`](PITFALLS.md) —— 15 条真实坑：无 TUN、DNS 与 `socks5h`、BusyBox netcat、HTTPS Serve 被拦、
  DERP 抖动、iOS 节点离线、进程被回收、状态持久化、出口 IP 变化导致的误判等。
- 脚本顶部注释同样写明了「为什么这么写」，可单独复制。

## License

MIT，见 [`LICENSE`](LICENSE)。
