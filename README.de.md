# agentkeeper

[English](README.md) | [简体中文](README.zh-CN.md) | [Русский](README.ru.md) | [Español](README.es.md) | **Deutsch**

![MIT](https://img.shields.io/badge/license-MIT-blue.svg) ![Go](https://img.shields.io/badge/Go-1.24-00ADD8?logo=go&logoColor=white)

**Die SSH-Bastion für KI-Agenten.** Gib deinem Agenten ein *Ticket* — nicht deine Produktionsschlüssel.
Jede Sitzung wird aufgezeichnet. Jeder gefährliche Befehl bekommt eine Denkpause. Null Installation auf dem Client.

![demo](demo/agentkeeper-demo.gif)

Gebaut für autonome Clients — LLM-Agenten, CI-Pipelines, Deploy-Bots: normales `ssh`, keine interaktiven Abfragen (der OTP wird im Benutzernamen mitgeführt), und rsync / scp / sftp funktionieren nativ. Die Bastion beendet die eingehende Verbindung und baut eine neue zum Ziel auf — deshalb lässt sich die Mitte auditieren und aufzeichnen.

## Warum

KI-Agenten entwickeln sich vom *Schreiben* von Code zum *Betreiben* von Infrastruktur. Der übliche Weg — einen privaten SSH-Schlüssel in die Sandbox des Agenten / die CI-Secrets / das Kontextfenster zu legen — scheitert an drei Fronten:

- **Der Schlüssel liegt offen.** Ein Agent, der `~/.ssh/id_ed25519` lesen kann, gibt ihn früher oder später weiter; Sandboxes und Kontextfenster sind keine Tresore.
- **Nichts wird aufgezeichnet.** Der Agent hat um 3 Uhr nachts einen Dienst neu gestartet — wo sind die Beweise?
- **Bis `rm -rf` fehlt nur eine Halluzination.** Eine autonome Schleife verdient eine Bremse vor irreversiblen Befehlen.

agentkeeper ist das kleine Tor, das alle drei löst:

- private Schlüssel bleiben **auf der Bastion** — der Agent hält nur ein widerrufbares Ticket;
- jede Sitzung wird **von Anfang bis Ende aufgezeichnet** (asciinema-Cast + Rohbytes + Befehls-Timeline);
- gefährliche Befehle lösen eine **„Denk nochmal nach“-Warnung** aus, die direkt im Kontext des Agenten landet — ein LLM liest sie und entscheidet erneut. Zum Bestätigen den exakt selben Befehl noch einmal senden.

## Funktionen

- **Null Installation auf dem Client** — alles, was ssh spricht: Kommandomodus, interaktive Shell, rsync / scp / sftp.
- **Niemals Prompts** — der OTP wird im Benutzernamen mitgeführt (`<Benutzer>+<Ziel>+<Code>`); nicht-interaktive Agenten hängen nie an einer Passwortabfrage — auch bei rsync und Co.
- **Identität = Schlüssel + TOTP** — jeder `users`-Eintrag kombiniert einen Ticket-Public-Key mit seinem eigenen TOTP-Secret; der Benutzername der Verbindung spielt für die Authentifizierung keine Rolle.
- **Aufzeichnung als Standard, fail-closed** — lässt sich nicht aufzeichnen, wird die Verbindung abgelehnt. Vier Artefakte pro Sitzung + JSONL-Index.
- **Graue Liste** — 50 RE2-Regeln ab Werk: beim ersten Treffer nur eine Warnung; derselbe Befehl erneut gesendet (MD5-identisch) wird ausgeführt. Anführungszeichen und Backslashes werden vor dem Abgleich aufgelöst.
- **Optionaler SOCKS5-Ausgang** — die Bastion wählt sich über deinen Proxy nach draußen.
- **Ein einziges Binary** — Go, statisch, kein cgo, eine YAML-Datei. Läuft auf jeder kleinen Linux-Maschine.

## Schnellstart

```sh
# Ein-Zeilen-Installation (Linux, letztes Release → /usr/local/bin)
curl -fsSL https://raw.githubusercontent.com/zagfai/agentkeeper/main/install.sh | sh

# oder aus dem Quellcode bauen:
git clone https://github.com/zagfai/agentkeeper.git && cd agentkeeper
CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o agentkeeper .

./agentkeeper gen-secret                                   # TOTP-Secret für den Agenten
ssh-keygen -t ed25519 -N '' -f ticket -C my-agent      # das Ticket des Agenten
ssh-keygen -t ed25519 -N '' -f host_ed25519 -C agentkeeper-host

cp agentkeeper.example.yaml agentkeeper.yaml    # Ticket-Pubkey, Secret und default_key eintragen
./agentkeeper check -c agentkeeper.yaml
./agentkeeper -c agentkeeper.yaml               # oder systemd — siehe agentkeeper.service
```

## Wie ein Agent sich verbindet

```sh
# Kommandomodus — was eine Agenten-Schleife wirklich ausführt
ssh -p2222 -i ticket 'deploy+10.0.0.5+123456'@<bastion> 'systemctl status nginx'

# ein destruktiver: beim ersten Mal nur die Warnung (die der Agent dann liest)
ssh -p2222 -i ticket 'deploy+10.0.0.5+123456'@<bastion> 'rm -rf /var/lib/app'
# [graylist] This command may be destructive (matched rule: ...). Think it over.
# To proceed anyway, resend the exact same command.

# Dateien — dieselbe Syntax
rsync -a -e 'ssh -p2222 -i ticket' ./dist/ 'deploy+10.0.0.5+123456'@<bastion>:/srv/app/
```

Authenticator-App anbinden: `./agentkeeper totp-uri -c agentkeeper.yaml` (otpauth-URI je Identität).

## Konfiguration

Siehe [`agentkeeper.example.yaml`](agentkeeper.example.yaml) — voll kommentiert. Das Wesentliche:

- `users[]` — die einzige Identitätstabelle: Name + Ticket-Public-Key + TOTP-Secret;
- `default_key` — der Schlüssel der Bastion zur Produktion (verlässt sie nie);
- `proxy` — optionaler `socks5://…`-Ausgang;
- `gray.patterns` — die Regeln für gefährliche Befehle (RE2).

## Audit

`recordings/<Datum>/` pro Sitzung: `*.cast` (asciinema v2, abspielbar), `*.in.raw` (0600), `*.cmd.log` (Timeline), `*.meta.json`; dazu `recordings/sessions.jsonl`.

## Test

```sh
bash test/matrix/runall.sh    # 9 Suiten, ~119 Assertions, ~10 Min
```

## Sicherheitshinweise

- Produktionsschlüssel liegen nur auf der Bastion; ein geleaktes Ticket ≠ Produktionszugang (TOTP bleibt Pflicht).
- Hinterlege den Host-Key-Fingerabdruck der Bastion fest auf den Clients.
- Die graue Liste ist eine Bremse, keine Sicherheitsgrenze — die Quelle der Wahrheit sind die Aufzeichnungen.

## Lizenz

MIT — siehe [LICENSE](LICENSE).
