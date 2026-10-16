# agentkeeper

[English](README.md) | **简体中文** | [Русский](README.ru.md) | [Español](README.es.md) | [Deutsch](README.de.md)

![MIT](https://img.shields.io/badge/license-MIT-blue.svg) ![Go](https://img.shields.io/badge/Go-1.24-00ADD8?logo=go&logoColor=white)

**面向 AI agent 的 SSH 堡垒机。** 给 agent 发一张"门票"，而不是生产机私钥。
全程录像、危险命令多想一步、客户端零安装。

![demo](demo/agentkeeper-demo.gif)

面向自主客户端——LLM agent、CI 流水线、部署机器人：走标准 `ssh`，全程零交互提示（动态码拼在用户名里），rsync / scp / sftp 原生可用。堡垒把连接一分为二、再向目标发起新的连接——所以中间这一段可以审计、可以录像。

## 为什么

AI agent 正在从"写代码"走向"管机器"。惯常做法——把 SSH 私钥塞进 agent 的沙箱 / CI 密钥库 / 上下文窗口——有三个坑：

- **密钥会外泄**：能读 `~/.ssh/id_ed25519` 的 agent，早晚会把它漏出去；沙箱和上下文窗口都不是保险柜。
- **无据可查**：agent 凌晨重启了服务，证据在哪？
- **`rm -rf` 只差一次幻觉**：自主循环，应该在不可逆命令前加一道减速带。

agentkeeper 就是那扇小门：

- 私钥**只留在堡垒**——agent 手里只有一张随时可吊销的门票；
- 每个会话**全程录像**（asciinema cast + 原始字节 + 命令时间线）；
- 危险命令触发**"再想一步"警告**，直接进入 agent 的上下文——LLM 会读到它并重新考虑；原样重发同一条命令才算确认。

## 特性

- **客户端零安装**：任何支持 ssh 的客户端——命令模式、交互 shell、rsync / scp / sftp。
- **永不弹提示**：动态码拼在用户名里（`<远端用户名>+<目标>+<6位码>`），非交互 agent 绝不会卡在密码提示上——rsync 之类场景同样适用。
- **身份 = 公钥 + TOTP**：`users` 表每项是一对「门票公钥 ↔ TOTP 密钥」；连接用户名不参与认证。
- **默认录像、fail-closed**：录像写不出就拒绝连接。每会话四件套 + JSONL 汇总索引。
- **灰名单**：内置 50 条 RE2 规则——首次命中只警告；同一条命令原样重发（MD5 一致）才执行；匹配前会去掉引号和反斜杠。
- **可选 SOCKS5 出口**：让堡垒经代理出网。
- **单二进制**：Go 静态编译、无 cgo、一个 YAML。任意小 Linux 机器即可跑。

## 快速开始

```sh
# 一行安装（Linux；普通用户装到 ~/.local/bin，免 sudo）
curl -fsSL https://raw.githubusercontent.com/zagfai/agentkeeper/main/install.sh | sh

# 或从源码构建：
git clone https://github.com/zagfai/agentkeeper.git && cd agentkeeper
CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o agentkeeper .

./agentkeeper gen-secret                                  # 给 agent 身份生成 TOTP 密钥
ssh-keygen -t ed25519 -N '' -f ticket -C my-agent     # agent 的门票
ssh-keygen -t ed25519 -N '' -f host_ed25519 -C agentkeeper-host

cp agentkeeper.example.yaml agentkeeper.yaml      # 填门票公钥、TOTP 密钥、default_key
./agentkeeper check -c agentkeeper.yaml
./agentkeeper -c agentkeeper.yaml                 # 或装 systemd（见 agentkeeper.service）
```

## agent 怎么连

```sh
# 命令模式——agent 循环实际执行的形式
ssh -p2222 -i ticket 'deploy+10.0.0.5+123456'@<堡垒> 'systemctl status nginx'

# 危险的一条：第一次只给警告（而 agent 会读到它）
ssh -p2222 -i ticket 'deploy+10.0.0.5+123456'@<堡垒> 'rm -rf /var/lib/app'
# [graylist] This command may be destructive (matched rule: ...). Think it over.
# To proceed anyway, resend the exact same command.

# 传文件，同一语法
rsync -a -e 'ssh -p2222 -i ticket' ./dist/ 'deploy+10.0.0.5+123456'@<堡垒>:/srv/app/
```

绑定认证器：`./agentkeeper totp-uri -c agentkeeper.yaml`（逐身份输出 otpauth URI）。

## 配置

见 [`agentkeeper.example.yaml`](agentkeeper.example.yaml)（全文带注释）。要点：

- `users[]`：唯一身份表——名字 + 门票公钥 + TOTP 密钥；
- `default_key`：堡垒连生产机的私钥（永不离开堡垒）；
- `proxy`：可选 `socks5://…` 出口；
- `gray.patterns`：危险命令规则（RE2）。

## 审计

`recordings/<日期>/` 每会话四件套：`*.cast`（asciinema v2 可回放）、`*.in.raw`（0600）、`*.cmd.log`（时间线）、`*.meta.json`；另有 `recordings/sessions.jsonl` 总索引。

## 测试

```sh
bash test/matrix/runall.sh    # 9 组 ~119 项断言，约 10 分钟
```

## 安全说明

- 生产机私钥只在堡垒；门票泄露 ≠ 直达生产（还要 TOTP）。
- 在客户端固定堡垒主机密钥指纹。
- 灰名单是减速带，不是安全边界——以录像为准。

## License

MIT —— 见 [LICENSE](LICENSE)。
