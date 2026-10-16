# agentkeeper

**English** | [简体中文](README.zh-CN.md) | [Русский](README.ru.md) | [Español](README.es.md) | [Deutsch](README.de.md)

![MIT](https://img.shields.io/badge/license-MIT-blue.svg) ![Go](https://img.shields.io/badge/Go-1.24-00ADD8?logo=go&logoColor=white)

**The SSH gate for AI agents.** Give your agent a *ticket* — not your production keys.
Every session recorded. Every destructive command gets one more thought. Zero install on the client.

![demo](demo/agentkeeper-demo.gif)

Built for autonomous clients — LLM agents, CI pipelines, deploy bots: plain `ssh`, no interactive prompts anywhere (the OTP travels in the username), and rsync / scp / sftp work natively. The gate terminates the incoming connection and opens a fresh one to the target — that's why the middle is auditable and recordable.

## Why

AI agents are moving from *writing* code to *operating* infrastructure. The usual shortcut — dropping an SSH private key into the agent's sandbox / CI secrets / context window — breaks in three ways:

- **The key leaks.** An agent that can read `~/.ssh/id_ed25519` will eventually leak it; sandboxes and context windows are not vaults.
- **Nothing is recorded.** The agent restarted a service at 3 a.m. — where's the evidence?
- **`rm -rf` is one hallucination away.** An autonomous loop deserves a speed bump before irreversible commands.

agentkeeper is the small gate that fixes all three:

- private keys stay **on the gate** — the agent holds only a revocable ticket;
- every session is **recorded end-to-end** (asciinema cast + raw bytes + command timeline);
- destructive commands trigger a **"think it over" warning** that lands straight in the agent's context — an LLM reads it and decides again. Resend the identical command to confirm.

## Features

- **Zero client install** — anything that speaks ssh: command mode, interactive shell, rsync / scp / sftp.
- **No prompts, ever** — the OTP travels inside the username (`<user>+<target>+<code>`), so non-interactive agents never hang on a password prompt — rsync and friends included.
- **Identity = key + TOTP** — each `users` entry pairs a ticket public key with its own TOTP secret; the connection username doesn't participate in auth.
- **Recorded by default, fail-closed** — if recording can't be written, the connection is refused. Four artifacts per session + a JSONL index.
- **Graylist** — 50 RE2 rules out of the box: first hit warns only; the very same command re-sent (MD5-identical) executes. Quotes and backslashes are stripped before matching.
- **Optional SOCKS5 egress** — let the gate dial out through your proxy.
- **Single binary** — Go, static, no cgo, one YAML file. Runs on any small Linux box.

## Quick start

```sh
# one-line install (Linux, latest release → /usr/local/bin)
curl -fsSL https://raw.githubusercontent.com/zagfai/agentkeeper/main/install.sh | sh

# or build from source:
git clone https://github.com/zagfai/agentkeeper.git && cd agentkeeper
CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o agentkeeper .

./agentkeeper gen-secret                                   # TOTP secret for the agent
ssh-keygen -t ed25519 -N '' -f ticket -C my-agent      # the agent's ticket
ssh-keygen -t ed25519 -N '' -f host_ed25519 -C agentkeeper-host

cp agentkeeper.example.yaml agentkeeper.yaml    # fill in the ticket pubkey, secret, default_key
./agentkeeper check -c agentkeeper.yaml
./agentkeeper -c agentkeeper.yaml               # or systemd — see agentkeeper.service
```

## How an agent connects

```sh
# command mode — what an agent loop actually runs
ssh -p2222 -i ticket 'deploy+10.0.0.5+123456'@<gate> 'systemctl status nginx'

# a destructive one: the first time it's only a warning (which the agent will read)
ssh -p2222 -i ticket 'deploy+10.0.0.5+123456'@<gate> 'rm -rf /var/lib/app'
# [graylist] This command may be destructive (matched rule: ...). Think it over.
# To proceed anyway, resend the exact same command.

# files — same syntax
rsync -a -e 'ssh -p2222 -i ticket' ./dist/ 'deploy+10.0.0.5+123456'@<gate>:/srv/app/
```

Bind an authenticator app: `./agentkeeper totp-uri -c agentkeeper.yaml` (prints an otpauth URI per identity).

## Configuration

See [`agentkeeper.example.yaml`](agentkeeper.example.yaml) — fully commented. The essentials:

- `users[]` — the only identity table: name + ticket public key + TOTP secret;
- `default_key` — the key the gate uses toward production (it never leaves the gate);
- `proxy` — optional `socks5://…` egress;
- `gray.patterns` — the destructive-command rules (RE2).

## Audit

`recordings/<date>/` per session: `*.cast` (asciinema v2, replayable), `*.in.raw` (0600), `*.cmd.log` (timeline), `*.meta.json`; plus `recordings/sessions.jsonl`.

## Test

```sh
bash test/matrix/runall.sh    # 9 suites, ~119 assertions, ~10 min
```

## Security notes

- Production keys live only on the gate; a leaked ticket ≠ production access (TOTP is still required).
- Pin the gate's host key fingerprint on the clients.
- The graylist is a speed bump, not a security boundary — recordings are the source of truth.

## License

MIT — see [LICENSE](LICENSE).
