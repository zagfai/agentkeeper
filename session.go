package main

import (
	"bufio"
	"fmt"
	"io"
	"log"
	"net"
	"strings"
	"sync"

	glssh "github.com/gliderlabs/ssh"
	xssh "golang.org/x/crypto/ssh"
)

type lockedWriter struct {
	mu  *sync.Mutex
	w   io.Writer
	rec *Recorder
}

func (o *lockedWriter) Write(b []byte) (int, error) {
	if len(b) == 0 {
		return 0, nil
	}
	o.mu.Lock()
	defer o.mu.Unlock()
	if o.rec != nil {
		o.rec.WriteOutput(b)
	}
	if o.w == nil {
		return len(b), nil
	}
	return o.w.Write(b)
}

// parseIdentity 解析连接用户名：<远端用户名>+<目标>[+<6位码>]。
// 第一段是远端机上的登录名（随意填、不参与认证）；第二段是目标；第三段（如有）是 TOTP 码。
func parseIdentity(username string) (user, target, code string) {
	parts := strings.Split(username, "+")
	user = parts[0]
	if len(parts) >= 2 {
		target = parts[1]
	}
	if len(parts) >= 3 {
		code = parts[2]
	}
	if len(parts) > 3 { // 多段=格式错误：并入目标让目标解析报错
		target = strings.Join(parts[1:], "+")
		code = ""
	}
	return
}

// maskIdent 供日志使用：把用户名中任何 6 位数字段（即 TOTP 码）脱敏。
// 覆盖三种形态：<u>+<code>、<u>+<target>+<code>，以及被拒的旧序 <u>+<code>+<target>。
func maskIdent(username string) string {
	segs := strings.Split(username, "+")
	for i := 1; i < len(segs); i++ {
		if is6Digits(segs[i]) {
			segs[i] = "***"
		}
	}
	return strings.Join(segs, "+")
}

func is6Digits(s string) bool {
	if len(s) != 6 {
		return false
	}
	for _, c := range s {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}

func handleSession(sc *serverCtx, s glssh.Session) {
	raw := strings.TrimSpace(s.RawCommand())
	subsys := s.Subsystem()
	base, userTarget, code := parseIdentity(s.User())
	peer := s.RemoteAddr().String()
	if h, _, err := net.SplitHostPort(peer); err == nil {
		peer = h
	}
	pty0, winch, hasPty := s.Pty()
	log.Printf("session start: user=%s peer=%s target=%q cmd=%q pty=%v subsystem=%q", maskIdent(s.User()), peer, userTarget, raw, hasPty, subsys)

	if subsys != "" && subsys != "sftp" {
		fmt.Fprintf(s, "[agentkeeper] subsystem %q is not supported.\n", subsys)
		_ = s.Exit(1)
		return
	}

	br := bufio.NewReader(s)
	var mu sync.Mutex
	out := &lockedWriter{mu: &mu, w: s}
	outErr := &lockedWriter{mu: &mu, w: s.Stderr()}

	targetSpec, remoteCmd := userTarget, raw
	if userTarget == "" {
		// 目标必须随连接指定（用户名里）：<user>+<target>[+code]；不接受旧写法
		if subsys == "sftp" {
			fmt.Fprintln(outErr, "[agentkeeper] sftp requires the target in the username: '<user>+<target>[+<code>]'@host.")
		} else {
			fmt.Fprintln(outErr, "[agentkeeper] no target in username; connect as '<user>+<target>[+<code>]'@host (e.g. 'root+10.0.0.5+123456'@host).")
		}
		_ = s.Exit(1)
		return
	}
	if remoteCmd == "" && subsys == "" && !hasPty {
		fmt.Fprintln(outErr, "[agentkeeper] interactive shell requires a TTY; connect with ssh -t.")
		_ = s.Exit(1)
		return
	}

	width, height := 80, 24
	if pty0.Window.Width > 0 {
		width = pty0.Window.Width
	}
	if pty0.Window.Height > 0 {
		height = pty0.Window.Height
	}

	rec, err := newRecorder(sc.cfg, base, targetSpec, peer, width, height)
	if err != nil {
		log.Printf("recorder error; refusing connection: %v", err)
		fmt.Fprintf(outErr, "[agentkeeper] cannot start session recording; refusing this connection: %v\n", err)
		_ = s.Exit(1)
		return
	}
	out.rec = rec
	outErr.rec = rec

	exit := 1
	defer func() {
		rec.Close(exit)
		_ = s.Exit(exit)
		log.Printf("session end: user=%s target=%s peer=%s exit=%d", base, targetSpec, peer, exit)
	}()

	// TOTP：码随用户名携带，不做交互提示；密钥取自"呈现的公钥"对应的身份条目
	if totpRequired(sc.cfg, targetSpec) {
		u := entryFor(sc, s)
		if u == nil || u.TOTPSecret == "" {
			rec.Event("totp", "fail")
			fmt.Fprintf(outErr, "[agentkeeper] no TOTP configured for user %q.\n", base)
			return
		}
		if code == "" {
			rec.Event("totp", "fail")
			fmt.Fprintf(outErr, "[agentkeeper] TOTP required for %q; include the code in the username (e.g. '%s+%s+<code>'@host).\n", targetSpec, base, targetSpec)
			return
		}
		if !verifyTOTP(u.TOTPSecret, code) {
			rec.Event("totp", "fail")
			fmt.Fprintf(outErr, "[agentkeeper] invalid TOTP code for %q.\n", targetSpec)
			return
		}
		rec.Event("totp", "ok")
	}

	if remoteCmd != "" && subsys == "" {
		if hit, confirmed := sc.gray.Check(remoteCmd); hit != "" && !confirmed {
			rec.Cmd(remoteCmd, true)
			rec.Event("gray", "hit rule "+hit+", cmd: "+remoteCmd)
			fmt.Fprint(outErr, eolText(grayWarnText(hit), hasPty))
			return
		}
		rec.Cmd(remoteCmd, false)
	}

	tgt, err := resolveTarget(sc.cfg, targetSpec, base)
	if err != nil {
		fmt.Fprintf(outErr, "[agentkeeper] target resolution failed: %v\n", err)
		return
	}
	client, err := dialTarget(sc.cfg, tgt)
	if err != nil {
		fmt.Fprintf(outErr, "[agentkeeper] cannot connect to target: %v\n", err)
		return
	}
	defer client.Close()
	rec.Event("connect", tgt.Addr+" (user="+tgt.User+")")

	b := &bridge{s: s, client: client, br: br, out: out, outErr: outErr, rec: rec, gray: sc.gray, pty: pty0, winch: winch, hasPty: hasPty, width: width, height: height}
	switch {
	case subsys == "sftp":
		exit = runSubsystem(b, subsys)
	case remoteCmd != "":
		exit = runCommandMode(b, remoteCmd)
	default:
		exit = runShellMode(b)
	}
}

type bridge struct {
	s      glssh.Session
	client *xssh.Client
	br     *bufio.Reader
	out    *lockedWriter
	outErr *lockedWriter
	rec    *Recorder
	gray   *GrayList
	pty    glssh.Pty
	winch  <-chan glssh.Window
	hasPty bool
	width  int
	height int
}

func defaultTermModes() xssh.TerminalModes {
	return xssh.TerminalModes{
		xssh.ECHO:          1,
		xssh.TTY_OP_ISPEED: 14400,
		xssh.TTY_OP_OSPEED: 14400,
	}
}

func runCommandMode(b *bridge, cmd string) int {
	xss, err := b.client.NewSession()
	if err != nil {
		fmt.Fprintf(b.outErr, "[agentkeeper] cannot open remote session: %v\n", err)
		return 1
	}
	defer xss.Close()

	if b.hasPty {
		term := b.pty.Term
		if term == "" {
			term = "xterm-256color"
		}
		_ = xss.RequestPty(term, b.height, b.width, defaultTermModes())
	}
	xss.Stdout = b.out
	xss.Stderr = b.outErr

	stdinR, stdinW := io.Pipe()
	xss.Stdin = stdinR
	go func() {
		buf := make([]byte, 4096)
		for {
			n, err := b.br.Read(buf)
			if n > 0 {
				b.rec.WriteInput(buf[:n])
				if _, werr := stdinW.Write(buf[:n]); werr != nil {
					break
				}
			}
			if err != nil {
				break
			}
		}
		_ = stdinW.Close()
	}()

	err = xss.Run(cmd)
	code := 0
	if err != nil {
		if ee, ok := err.(*xssh.ExitError); ok {
			code = ee.ExitStatus()
		} else {
			fmt.Fprintf(b.outErr, "[agentkeeper] remote execution error: %v\n", err)
			code = 255
		}
	}
	b.rec.Event("exit", fmt.Sprint(code))
	return code
}

func runShellMode(b *bridge) int {
	xss, err := b.client.NewSession()
	if err != nil {
		fmt.Fprintf(b.outErr, "[agentkeeper] cannot open remote session: %v\n", err)
		return 1
	}
	defer xss.Close()

	term := b.pty.Term
	if term == "" {
		term = "xterm-256color"
	}
	if err := xss.RequestPty(term, b.height, b.width, defaultTermModes()); err != nil {
		fmt.Fprintf(b.outErr, "[agentkeeper] remote pty request failed: %v\n", err)
		return 1
	}
	go func() {
		for w := range b.winch {
			if w.Width <= 0 || w.Height <= 0 {
				continue // 客户端未报尺寸（管道输入等）：保留回落的 80x24
			}
			_ = xss.WindowChange(w.Height, w.Width)
		}
	}()
	xss.Stdout = b.out
	xss.Stderr = b.outErr

	stdinR, stdinW := io.Pipe()
	xss.Stdin = stdinR
	go inputPump(b.br, stdinW, b.out, b.rec, b.gray)

	if err := xss.Shell(); err != nil {
		fmt.Fprintf(b.outErr, "[agentkeeper] cannot start remote shell: %v\n", err)
		return 1
	}
	err = xss.Wait()
	code := 0
	if err != nil {
		if ee, ok := err.(*xssh.ExitError); ok {
			code = ee.ExitStatus()
		} else {
			code = 255
		}
	}
	b.rec.Event("exit", fmt.Sprint(code))
	return code
}

// runSubsystem 直通一个子系统（当前仅 sftp）。目标在连接建立时已确定，
// 因此无需解析报文，两个方向字节透传即可。
//
// 注意：x/crypto 的 RequestSubsystem 不会触发 session.start()，Wait() 与
// Stdin/Stdout 字段的拷贝机制都不工作；必须用 Pipe 接口直接读写底层通道
// （pkg/sftp 同款做法），并以读端 EOF 作为收尾信号。
func runSubsystem(b *bridge, name string) int {
	xss, err := b.client.NewSession()
	if err != nil {
		fmt.Fprintf(b.outErr, "[agentkeeper] cannot open remote session: %v\n", err)
		return 1
	}
	defer xss.Close()

	stdinW, err := xss.StdinPipe()
	if err != nil {
		fmt.Fprintf(b.outErr, "[agentkeeper] remote stdin pipe failed: %v\n", err)
		return 1
	}
	stdoutR, err := xss.StdoutPipe()
	if err != nil {
		fmt.Fprintf(b.outErr, "[agentkeeper] remote stdout pipe failed: %v\n", err)
		return 1
	}
	stderrR, err := xss.StderrPipe()
	if err != nil {
		fmt.Fprintf(b.outErr, "[agentkeeper] remote stderr pipe failed: %v\n", err)
		return 1
	}
	if err := xss.RequestSubsystem(name); err != nil {
		fmt.Fprintf(b.outErr, "[agentkeeper] remote subsystem %q failed: %v\n", name, err)
		return 1
	}

	done := make(chan struct{})
	go func() {
		_, _ = io.Copy(b.out, stdoutR)
		close(done)
	}()
	go func() { _, _ = io.Copy(b.outErr, stderrR) }()
	go func() {
		buf := make([]byte, 32768)
		for {
			n, err := b.br.Read(buf)
			if n > 0 {
				b.rec.WriteInput(buf[:n])
				if _, werr := stdinW.Write(buf[:n]); werr != nil {
					break
				}
			}
			if err != nil {
				break
			}
		}
		_ = stdinW.Close()
	}()

	<-done
	b.rec.Event("exit", "0")
	return 0
}

// entryFor 由本次连接认证所用的公钥找到身份条目。
// 用户名只是"远端机的登录名"，不参与认证、也不与条目绑定。
func entryFor(sc *serverCtx, s glssh.Session) *UserConf {
	pk := s.PublicKey()
	if pk == nil {
		return nil
	}
	return sc.keyEntry[xssh.FingerprintSHA256(pk)]
}

func totpRequired(cfg *Config, spec string) bool {
	switch cfg.TOTP.Mode {
	case "all":
		return true
	case "patterns":
		for _, p := range cfg.TOTP.Patterns {
			if p != "" && strings.Contains(spec, p) {
				return true
			}
		}
	}
	return false
}
