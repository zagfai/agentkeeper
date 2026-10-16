package main

import (
	"fmt"
	"io"
	"log"
	"net"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"

	xssh "golang.org/x/crypto/ssh"
	"golang.org/x/crypto/ssh/knownhosts"
)

type Target struct {
	Name string
	Addr string
	User string
	Key  string
}

// resolveTarget 把目标规格解析为拨号目标：host[:port]（用 default_key）。
// 远端用户名（remoteUser）来自连接用户名第一段，不在目标里携带。
func resolveTarget(cfg *Config, spec, remoteUser string) (*Target, error) {
	if remoteUser == "" {
		return nil, fmt.Errorf("empty remote user")
	}
	if spec == "" || strings.ContainsAny(spec, "@ 	+") {
		return nil, fmt.Errorf("unrecognized target %q (use host[:port])", spec)
	}
	host, port := spec, "22"
	if strings.Contains(spec, ":") {
		h, p, err := net.SplitHostPort(spec)
		if err != nil {
			return nil, fmt.Errorf("bad target %q: %v", spec, err)
		}
		host, port = h, p
	}
	if host == "" {
		return nil, fmt.Errorf("bad target %q", spec)
	}
	if cfg.DefaultKey == "" {
		return nil, fmt.Errorf("no key for outbound connection; set default_key (agentkeeper's private key for target machines)")
	}
	return &Target{Name: spec, Addr: net.JoinHostPort(host, port), User: remoteUser, Key: cfg.DefaultKey}, nil
}

func loadSigner(path string) (xssh.Signer, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return xssh.ParsePrivateKey(b)
}

func dialTarget(cfg *Config, t *Target) (*xssh.Client, error) {
	signer, err := loadSigner(t.Key)
	if err != nil {
		return nil, fmt.Errorf("load private key %s: %w", t.Key, err)
	}
	var hkcb xssh.HostKeyCallback
	if cfg.KnownHosts != "" {
		hk, err := knownhosts.New(cfg.KnownHosts)
		if err != nil {
			return nil, fmt.Errorf("known_hosts: %w", err)
		}
		hkcb = hk
	} else {
		hkcb = func(hostname string, remote net.Addr, key xssh.PublicKey) error {
			log.Printf("no known_hosts configured; accepting host key %s for %s", xssh.FingerprintSHA256(key), hostname)
			return nil
		}
	}
	cc := &xssh.ClientConfig{
		User:            t.User,
		Auth:            []xssh.AuthMethod{xssh.PublicKeys(signer)},
		HostKeyCallback: hkcb,
		Timeout:         10 * time.Second,
	}

	if cfg.Proxy == "" {
		return xssh.Dial("tcp", t.Addr, cc)
	}
	// 经 SOCKS5 出去：先穿代理建 TCP，再做 SSH 握手
	log.Printf("dialing %s via socks5 %s", t.Addr, cfg.Proxy)
	conn, err := dialSocks5(cfg.Proxy, t.Addr, 10*time.Second)
	if err != nil {
		return nil, fmt.Errorf("socks5 %s: %w", cfg.Proxy, err)
	}
	c, chans, reqs, err := xssh.NewClientConn(conn, t.Addr, cc)
	if err != nil {
		conn.Close()
		return nil, err
	}
	return xssh.NewClient(c, chans, reqs), nil
}

// dialSocks5 经 SOCKS5 代理建立到 target 的 TCP 连接（CONNECT；支持无认证与用户名/口令）。
// proxyURL 形如 socks5://[user:pass@]host:port。
func dialSocks5(proxyURL, target string, timeout time.Duration) (net.Conn, error) {
	u, err := url.Parse(proxyURL)
	if err != nil || u.Scheme != "socks5" || u.Host == "" {
		return nil, fmt.Errorf("bad proxy %q", proxyURL)
	}
	conn, err := net.DialTimeout("tcp", u.Host, timeout)
	if err != nil {
		return nil, err
	}
	_ = conn.SetDeadline(time.Now().Add(timeout))
	fail := func(e error) (net.Conn, error) { conn.Close(); return nil, e }

	user, pass := "", ""
	haveAuth := false
	if u.User != nil {
		user = u.User.Username()
		if pw, ok := u.User.Password(); ok {
			pass, haveAuth = pw, true
		}
	}

	// 问候：无认证 / 用户名口令
	greet := []byte{5}
	if haveAuth {
		greet = append(greet, 2, 0, 2)
	} else {
		greet = append(greet, 1, 0)
	}
	if _, err := conn.Write(greet); err != nil {
		return fail(err)
	}
	resp := make([]byte, 2)
	if _, err := io.ReadFull(conn, resp); err != nil {
		return fail(err)
	}
	if resp[0] != 5 {
		return fail(fmt.Errorf("bad protocol version %d", resp[0]))
	}
	switch resp[1] {
	case 0:
	case 2:
		if !haveAuth {
			return fail(fmt.Errorf("proxy requires username/password"))
		}
		if len(user) > 255 || len(pass) > 255 {
			return fail(fmt.Errorf("username/password too long"))
		}
		auth := append([]byte{1, byte(len(user))}, user...)
		auth = append(auth, byte(len(pass)))
		auth = append(auth, pass...)
		if _, err := conn.Write(auth); err != nil {
			return fail(err)
		}
		if _, err := io.ReadFull(conn, resp); err != nil {
			return fail(err)
		}
		if resp[1] != 0 {
			return fail(fmt.Errorf("authentication failed"))
		}
	default:
		return fail(fmt.Errorf("no acceptable auth method (proxy chose %d)", resp[1]))
	}

	// CONNECT 请求
	host, portStr, err := net.SplitHostPort(target)
	if err != nil {
		return fail(fmt.Errorf("bad target %q: %w", target, err))
	}
	port, err := strconv.Atoi(portStr)
	if err != nil || port < 1 || port > 65535 {
		return fail(fmt.Errorf("bad port in %q", target))
	}
	req := []byte{5, 1, 0}
	if ip := net.ParseIP(host); ip != nil {
		if v4 := ip.To4(); v4 != nil {
			req = append(req, 1)
			req = append(req, v4...)
		} else {
			req = append(req, 4)
			req = append(req, ip.To16()...)
		}
	} else {
		if len(host) > 255 {
			return fail(fmt.Errorf("target host too long"))
		}
		req = append(req, 3, byte(len(host)))
		req = append(req, host...)
	}
	req = append(req, byte(port>>8), byte(port))
	if _, err := conn.Write(req); err != nil {
		return fail(err)
	}

	// 应答：VER REP RSV ATYP BND.ADDR BND.PORT
	hdr := make([]byte, 4)
	if _, err := io.ReadFull(conn, hdr); err != nil {
		return fail(err)
	}
	if hdr[1] != 0 {
		return fail(fmt.Errorf("connect rejected (code %d)", hdr[1]))
	}
	var skip int
	switch hdr[3] {
	case 1:
		skip = 4 + 2
	case 4:
		skip = 16 + 2
	case 3:
		l := make([]byte, 1)
		if _, err := io.ReadFull(conn, l); err != nil {
			return fail(err)
		}
		skip = int(l[0]) + 2
	default:
		return fail(fmt.Errorf("bad reply address type %d", hdr[3]))
	}
	if _, err := io.ReadFull(conn, make([]byte, skip)); err != nil {
		return fail(err)
	}
	_ = conn.SetDeadline(time.Time{})
	return conn, nil
}
