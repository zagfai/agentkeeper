# agentkeeper

[English](README.md) | [简体中文](README.zh-CN.md) | [Русский](README.ru.md) | **Español** | [Deutsch](README.de.md)

![MIT](https://img.shields.io/badge/license-MIT-blue.svg) ![Go](https://img.shields.io/badge/Go-1.24-00ADD8?logo=go&logoColor=white)

**El bastión SSH para agentes de IA.** Dale a tu agente un *ticket*, no tus claves de producción.
Cada sesión grabada. Cada comando destructivo recibe una segunda reflexión. Cero instalación en el cliente.

![demo](demo/agentkeeper-demo.gif)

Hecho para clientes autónomos — agentes LLM, pipelines de CI, bots de despliegue: `ssh` estándar, sin prompts interactivos (el OTP viaja dentro del nombre de usuario) y rsync / scp / sftp funcionan de forma nativa. El bastión termina la conexión entrante y abre una nueva hacia el destino — por eso el tramo intermedio es auditable y grabable.

## Por qué

Los agentes de IA están pasando de *escribir* código a *operar* infraestructura. La solución habitual — meter una clave SSH privada en la sandbox del agente / los secretos de CI / la ventana de contexto — falla en tres frentes:

- **La clave se filtra.** Un agente que puede leer `~/.ssh/id_ed25519` acabará filtrándola; las sandboxes y las ventanas de contexto no son cajas fuertes.
- **Nada queda registrado.** El agente reinició un servicio a las 3 a.m. — ¿dónde está la evidencia?
- **`rm -rf` está a una alucinación de distancia.** Un bucle autónomo merece un badén antes de los comandos irreversibles.

agentkeeper es la pequeña puerta que arregla los tres problemas:

- las claves privadas se quedan **en el bastión** — el agente solo tiene un ticket revocable;
- cada sesión se **graba de principio a fin** (cast de asciinema + bytes crudos + línea de tiempo de comandos);
- los comandos destructivos disparan un **aviso de «piénsalo otra vez»** que cae directo en el contexto del agente — un LLM lo lee y decide de nuevo. Para confirmar, reenvía el mismo comando idéntico.

## Características

- **Cero instalación en el cliente** — cualquier cliente que hable ssh: modo comando, shell interactivo, rsync / scp / sftp.
- **Nunca hay prompts** — el OTP viaja en el nombre de usuario (`<usuario>+<destino>+<código>`); los agentes no interactivos jamás se cuelgan esperando una contraseña — también con rsync y demás casos no interactivos.
- **Identidad = clave + TOTP** — cada entrada de `users` empareja una clave pública de ticket con su propio secreto TOTP; el nombre de usuario no participa en la autenticación.
- **Grabación por defecto, fail-closed** — si no se puede grabar, la conexión se rechaza. Cuatro artefactos por sesión + índice JSONL.
- **Lista gris** — 50 reglas RE2 de fábrica: el primer impacto solo avisa; el mismo comando reenviado (MD5 idéntico) se ejecuta. Las comillas y las barras invertidas se eliminan antes de comparar.
- **Salida SOCKS5 opcional** — el bastión sale por tu proxy.
- **Un solo binario** — Go estático, sin cgo, un YAML. Corre en cualquier Linux pequeño.

## Inicio rápido

```sh
# instalación en una línea (Linux; para el usuario → ~/.local/bin, sin sudo)
curl -fsSL https://raw.githubusercontent.com/zagfai/agentkeeper/main/install.sh | sh

# o compilar desde el código fuente:
git clone https://github.com/zagfai/agentkeeper.git && cd agentkeeper
CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o agentkeeper .

./agentkeeper gen-secret                                  # secreto TOTP del agente
ssh-keygen -t ed25519 -N '' -f ticket -C my-agent     # el ticket del agente
ssh-keygen -t ed25519 -N '' -f host_ed25519 -C agentkeeper-host

cp agentkeeper.example.yaml agentkeeper.yaml      # completa clave del ticket, secreto, default_key
./agentkeeper check -c agentkeeper.yaml
./agentkeeper -c agentkeeper.yaml                 # o systemd — ver agentkeeper.service
```

## Cómo se conecta un agente

```sh
# modo comando — lo que realmente ejecuta el bucle del agente
ssh -p2222 -i ticket 'deploy+10.0.0.5+123456'@<bastión> 'systemctl status nginx'

# uno destructivo: la primera vez solo recibe el aviso (y el agente lo leerá)
ssh -p2222 -i ticket 'deploy+10.0.0.5+123456'@<bastión> 'rm -rf /var/lib/app'
# [graylist] This command may be destructive (matched rule: ...). Think it over.
# To proceed anyway, resend the exact same command.

# archivos, misma sintaxis
rsync -a -e 'ssh -p2222 -i ticket' ./dist/ 'deploy+10.0.0.5+123456'@<bastión>:/srv/app/
```

Vincula tu app de autenticación: `./agentkeeper totp-uri -c agentkeeper.yaml` (URI otpauth por identidad).

## Configuración

Ver [`agentkeeper.example.yaml`](agentkeeper.example.yaml) — comentado por completo. Lo esencial:

- `users[]` — la única tabla de identidades: nombre + clave pública del ticket + secreto TOTP;
- `default_key` — la clave del bastión hacia producción (nunca sale del bastión);
- `proxy` — salida opcional `socks5://…`;
- `gray.patterns` — las reglas de comandos peligrosos (RE2).

## Auditoría

`recordings/<fecha>/` por sesión: `*.cast` (asciinema v2, reproducible), `*.in.raw` (0600), `*.cmd.log` (línea de tiempo), `*.meta.json`; más `recordings/sessions.jsonl`.

## Pruebas

```sh
bash test/matrix/runall.sh    # 9 suites, ~119 aserciones, ~10 min
```

## Seguridad

- Las claves de producción viven solo en el bastión; un ticket filtrado ≠ acceso a producción (el TOTP sigue siendo obligatorio).
- Fija (pin) la huella del host key del bastión en los clientes.
- La lista gris es un badén, no una frontera de seguridad — la fuente de verdad son las grabaciones.

## Licencia

MIT — ver [LICENSE](LICENSE).
