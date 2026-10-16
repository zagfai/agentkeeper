package main

import (
	"fmt"
	"log"
	"os"

	glssh "github.com/gliderlabs/ssh"
	xssh "golang.org/x/crypto/ssh"
)

type serverCtx struct {
	cfg      *Config
	gray     *GrayList
	keys     map[string][]glssh.PublicKey
	keyEntry map[string]*UserConf // ssh 公钥指纹 → 身份条目（认证与 TOTP 都走它）
}

func runServer(cfg *Config) error {
	raw, err := os.ReadFile(cfg.HostKey)
	if err != nil {
		return fmt.Errorf("read host key %s: %w", cfg.HostKey, err)
	}
	signer, err := xssh.ParsePrivateKey(raw)
	if err != nil {
		return fmt.Errorf("parse host key: %w", err)
	}
	keys, err := loadAuthorized(cfg)
	if err != nil {
		return err
	}
	keyEntry := map[string]*UserConf{}
	for i := range cfg.Users {
		for _, k := range keys[cfg.Users[i].Name] {
			keyEntry[xssh.FingerprintSHA256(k)] = &cfg.Users[i]
		}
	}
	if err := os.MkdirAll(cfg.RecordingsDir, 0o755); err != nil {
		return fmt.Errorf("create recordings dir: %w", err)
	}
	gl, err := newGrayList(cfg.Gray.Patterns)
	if err != nil {
		return err
	}
	sc := &serverCtx{cfg: cfg, gray: gl, keys: keys, keyEntry: keyEntry}

	s := &glssh.Server{
		Addr:        cfg.Listen,
		HostSigners: []glssh.Signer{signer},
		PublicKeyHandler: func(ctx glssh.Context, key glssh.PublicKey) bool {
			if _, ok := sc.keyEntry[xssh.FingerprintSHA256(key)]; ok {
				return true
			}
			log.Printf("auth failed: user=%s key=%s", maskIdent(ctx.User()), xssh.FingerprintSHA256(key))
			return false
		},
		Handler: func(s glssh.Session) {
			handleSession(sc, s)
		},
		SubsystemHandlers: map[string]glssh.SubsystemHandler{
			"sftp": func(s glssh.Session) {
				handleSession(sc, s)
			},
		},
	}

	log.Printf("listening: listen=%s users=%d totp=%s graylist=%d", cfg.Listen, len(keys), cfg.TOTP.Mode, len(cfg.Gray.Patterns))
	return s.ListenAndServe()
}

func loadAuthorized(cfg *Config) (map[string][]glssh.PublicKey, error) {
	m := map[string][]glssh.PublicKey{}
	for _, u := range cfg.Users {
		for _, line := range u.Keys {
			pk, _, _, _, err := glssh.ParseAuthorizedKey([]byte(line))
			if err != nil {
				return nil, fmt.Errorf("user %s: bad public key: %w", u.Name, err)
			}
			m[u.Name] = append(m[u.Name], pk)
		}
	}
	if len(m) == 0 {
		return nil, fmt.Errorf("no usable public keys")
	}
	return m, nil
}
