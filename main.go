package main

import (
	"fmt"
	"log"
	"os"
)

const usage = `agentkeeper — a small SSH bastion

Usage:
  agentkeeper [-c config]            start the service (default ./agentkeeper.yaml)
  agentkeeper check   [-c config]    validate config and print a summary
  agentkeeper gen-secret             generate a TOTP secret (base32) + binding URI
  agentkeeper totp-uri [-c config]   print otpauth URIs for all users' TOTP secrets
`

func main() {
	log.SetFlags(log.LstdFlags)
	log.SetPrefix("[agentkeeper] ")

	cmd := "run"
	confPath := "agentkeeper.yaml"
	args := os.Args[1:]
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "-c", "--config":
			if i+1 >= len(args) {
				fatal("-c requires a path")
			}
			confPath = args[i+1]
			i++
		case "run", "check", "gen-secret", "totp-uri":
			cmd = args[i]
		case "-h", "--help", "help":
			fmt.Print(usage)
			return
		default:
			fatal("unknown argument %q\n%s", args[i], usage)
		}
	}

	switch cmd {
	case "gen-secret":
		sec, err := genTOTPSecret()
		if err != nil {
			fatal("generation failed: %v", err)
		}
		fmt.Println("secret:", sec)
		fmt.Println("uri:   ", totpURI(sec, "user", "AgentKeeper"))
		fmt.Println("Put the secret into a user entry (users[].totp_secret); bind your authenticator app with the uri (or enter the secret manually).")
	case "totp-uri":
		cfg, err := loadConfig(confPath)
		if err != nil {
			fatal("%v", err)
		}
		n := 0
		for _, u := range cfg.Users {
			if u.TOTPSecret != "" {
				fmt.Printf("%s : %s\n", u.Name, totpURI(u.TOTPSecret, u.Name, "AgentKeeper"))
				n++
			}
		}
		if n == 0 {
			fatal("no user has totp_secret set")
		}
	case "check":
		cfg, err := loadConfig(confPath)
		if err != nil {
			fatal("bad config: %v", err)
		}
		if _, err := loadAuthorized(cfg); err != nil {
			fatal("bad config: %v", err)
		}
		if _, err := os.ReadFile(cfg.HostKey); err != nil {
			fatal("bad config: host key: %v", err)
		}
		if _, err := newGrayList(cfg.Gray.Patterns); err != nil {
			fatal("bad config: %v", err)
		}
		printSummary(cfg)
	case "run":
		cfg, err := loadConfig(confPath)
		if err != nil {
			fatal("bad config: %v", err)
		}
		if err := runServer(cfg); err != nil {
			fatal("server exited: %v", err)
		}
	}
}

func fatal(f string, a ...any) {
	fmt.Fprintf(os.Stderr, f+"\n", a...)
	os.Exit(1)
}
