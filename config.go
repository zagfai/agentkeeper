package main

import (
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"

	"gopkg.in/yaml.v3"
)

// Config 对应 agentkeeper.yaml。相对路径一律相对配置文件所在目录解析。
//
// users 列表 = 远端机的用户身份：每个条目 = 一个"远端机的用户名" + 一组门票公钥
// + 一个 TOTP 密钥（TOTP 与该身份的公钥配对）。连接用户名第一段即该远端用户名：
//
//	'<远端用户名>[+<6位码>]+<目标>'@堡垒
//
// 目标只含主机/别名，不再携带用户名。
type Config struct {
	Listen        string     `yaml:"listen"`
	HostKey       string     `yaml:"host_key"`
	Users         []UserConf `yaml:"users"`
	KeysDir       string     `yaml:"keys_dir"`
	DefaultKey    string     `yaml:"default_key"`
	RecordingsDir string     `yaml:"recordings_dir"`
	KnownHosts    string     `yaml:"known_hosts"`
	Proxy         string     `yaml:"proxy"`
	TOTP          TOTPConf   `yaml:"totp"`
	Gray          GrayConf   `yaml:"gray"`

	BaseDir string `yaml:"-"`
}

// UserConf = 一个远端机身份。
type UserConf struct {
	Name       string   `yaml:"name"`        // 远端机的用户名（堡垒以该身份连目标机）
	Keys       []string `yaml:"keys"`        // 门票公钥：agent 持对应私钥连堡垒
	TOTPSecret string   `yaml:"totp_secret"` // 与该身份（公钥）配对的 TOTP 密钥（base32）
}

type TOTPConf struct {
	Mode     string   `yaml:"mode"` // off | all | patterns（默认 all：统一都要 TOTP）
	Patterns []string `yaml:"patterns"`
}

type GrayConf struct {
	Patterns []string `yaml:"patterns"` // 正则（RE2）；命中后"连续两条 MD5 一致"视为确认执行
}

func loadConfig(path string) (*Config, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read config: %w", err)
	}
	c := &Config{}
	if err := yaml.Unmarshal(raw, c); err != nil {
		return nil, fmt.Errorf("parse config: %w", err)
	}
	c.BaseDir = filepath.Dir(path)

	c.HostKey = c.resolve(c.HostKey, "host_ed25519")
	c.KeysDir = c.resolve(c.KeysDir, "keys")
	c.RecordingsDir = c.resolve(c.RecordingsDir, "recordings")
	c.DefaultKey = c.resolve(c.DefaultKey, "")
	c.KnownHosts = c.resolve(c.KnownHosts, "")
	if c.Proxy != "" {
		if u, err := url.Parse(c.Proxy); err != nil || u.Scheme != "socks5" || u.Host == "" {
			return nil, fmt.Errorf("bad proxy %q (want socks5://[user:pass@]host:port)", c.Proxy)
		}
	}

	if c.Listen == "" {
		c.Listen = "127.0.0.1:2222"
	}
	if c.TOTP.Mode == "" {
		c.TOTP.Mode = "all" // 设计取向：统一都要 TOTP
	}
	switch c.TOTP.Mode {
	case "off", "all", "patterns":
	default:
		return nil, fmt.Errorf("totp.mode must be off/all/patterns (got %q)", c.TOTP.Mode)
	}
	if len(c.Users) == 0 {
		return nil, fmt.Errorf("no users configured")
	}
	seen := map[string]bool{}
	for i := range c.Users {
		u := &c.Users[i]
		if u.Name == "" {
			return nil, fmt.Errorf("users[%d]: name required", i)
		}
		if strings.ContainsAny(u.Name, "+ \t") {
			return nil, fmt.Errorf("user %q: name must not contain '+' or spaces (it goes into the SSH username)", u.Name)
		}
		if seen[u.Name] {
			return nil, fmt.Errorf("duplicate user %q", u.Name)
		}
		seen[u.Name] = true
		if len(u.Keys) == 0 {
			return nil, fmt.Errorf("user %q: no keys", u.Name)
		}
		if c.TOTP.Mode != "off" {
			if u.TOTPSecret == "" {
				return nil, fmt.Errorf("user %q: totp_secret required (totp.mode=%s)", u.Name, c.TOTP.Mode)
			}
			if _, err := totpCode(u.TOTPSecret, time.Now()); err != nil {
				return nil, fmt.Errorf("user %q: bad totp_secret: %w", u.Name, err)
			}
		}
	}
	return c, nil
}

func (c *Config) resolve(p, def string) string {
	if p == "" {
		p = def
	}
	if p == "" {
		return ""
	}
	if filepath.IsAbs(p) {
		return p
	}
	return filepath.Join(c.BaseDir, p)
}

func printSummary(c *Config) {
	fmt.Printf("listen         : %s\n", c.Listen)
	fmt.Printf("host_key       : %s\n", c.HostKey)
	fmt.Printf("keys_dir       : %s\n", c.KeysDir)
	fmt.Printf("default_key    : %s\n", c.DefaultKey)
	fmt.Printf("recordings_dir : %s\n", c.RecordingsDir)
	fmt.Printf("known_hosts    : %s\n", c.KnownHosts)
	pr := c.Proxy
	if pr == "" {
		pr = "(direct)"
	}
	fmt.Printf("proxy          : %s\n", pr)
	names := make([]string, 0, len(c.Users))
	for _, u := range c.Users {
		stat := fmt.Sprintf("%s(%d keys", u.Name, len(u.Keys))
		if u.TOTPSecret != "" {
			stat += ", totp"
		}
		stat += ")"
		names = append(names, stat)
	}
	fmt.Printf("users          : %v\n", names)
	fmt.Printf("totp           : mode=%s patterns=%v\n", c.TOTP.Mode, c.TOTP.Patterns)
	fmt.Printf("gray           : patterns=%d\n", len(c.Gray.Patterns))

	for _, p := range []struct{ label, path string }{
		{"host_key", c.HostKey},
		{"keys_dir", c.KeysDir},
	} {
		if _, err := os.Stat(p.path); err != nil {
			fmt.Printf("[warn] %s not found: %s\n", p.label, p.path)
		}
	}
}
