# 测试说明

一键全矩阵（在仓库根目录运行；自动起停实例、切换 TOTP 模式）：

```sh
bash test/matrix/runall.sh
```

## 前置条件

- Linux；本机 sshd 监听 `127.0.0.1:22`（多数套件经堡垒连本机做端到端验证）；
- 测试用户 `basttest`，其 `~/.ssh/authorized_keys` 放入 `test/out_test.pub`；
- 已构建 `./agentkeeper`（`go build -o agentkeeper .`）；
- 需要 `ssh / ssh-keygen / rsync / scp / sftp / python3`。

> 注意：`git clone` / `checkout` / `rebase` 会把文件权限重置为默认值（0644/0664），而 ssh 拒绝使用权限过宽的私钥——测试脚本会先自动 `chmod 600` 私钥夹具（ticket_test、out_test、host_ed25519_test）。

录像按"当天"写进 `test/rec/$(date +%F)/`，可反复跑；生成的临时文件（`kh_scan`、`wrongkey` 等）已由 `.gitignore` 排除。

## 套件一览

- `t1` 认证边界 + 命令模式（流/退出码/二进制/元字符）
- `t2` 交互模式 + 灰名单（正则 / MD5 连续确认）
- `t3a` / `t3b` TOTP `all` / `patterns` 模式（含传输带码）
- `t4` 录制与审计（并发无串流、断线续录）
- `t5` rsync 深测（20MB、增量、--delete、特殊文件名）
- `t6` CLI / 协议（check 校验、畸形输入、连击）
- `t7` 用户名语法与 sftp / scp / rsync
- `t8` SOCKS5 出口

共约 119 项断言。测试面向本机环境，勿在生产机直接跑（会创建/删除 `/tmp` 下的测试文件）。
