package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sync"
	"time"
)

// Recorder 负责一次会话的落盘：
//
//	<stem>.cast      —— asciinema v2 格式（输出流，可回放）
//	<stem>.in.raw    —— 原始输入字节（0600）
//	<stem>.cmd.log   —— 解析出的命令时间线（含灰名单标记）
//	<stem>.meta.json —— 元数据
//
// 根目录另有 sessions.jsonl 汇总索引。
type Recorder struct {
	mu     sync.Mutex
	base   string
	root   string
	castF  *os.File
	inF    *os.File
	cmdF   *os.File
	start  time.Time
	user   string
	target string
	peer   string
	in     int64
	out    int64
	events []map[string]string
	closed bool
}

var filenameSafe = regexp.MustCompile(`[^A-Za-z0-9._@-]+`)

func newRecorder(cfg *Config, user, target, peer string, width, height int) (*Recorder, error) {
	now := time.Now()
	dir := filepath.Join(cfg.RecordingsDir, now.Format("2006-01-02"))
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, err
	}
	stem := now.Format("150405") + "-" + filenameSafe.ReplaceAllString(target, "_")
	base := filepath.Join(dir, stem)
	for i := 2; ; i++ {
		if _, err := os.Stat(base + ".cast"); os.IsNotExist(err) {
			break
		}
		base = filepath.Join(dir, fmt.Sprintf("%s-%d", stem, i))
	}

	castF, err := os.OpenFile(base+".cast", os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o644)
	if err != nil {
		return nil, err
	}
	inF, err := os.OpenFile(base+".in.raw", os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		castF.Close()
		return nil, err
	}
	cmdF, err := os.OpenFile(base+".cmd.log", os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o644)
	if err != nil {
		castF.Close()
		inF.Close()
		return nil, err
	}

	r := &Recorder{
		base: base, root: cfg.RecordingsDir, castF: castF, inF: inF, cmdF: cmdF,
		start: now, user: user, target: target, peer: peer,
	}
	header := map[string]any{
		"version": 2, "width": width, "height": height,
		"timestamp": now.Unix(), "title": user + " -> " + target,
		"env": map[string]string{"TERM": "xterm-256color", "SHELL": "/bin/sh"},
	}
	hj, _ := json.Marshal(header)
	fmt.Fprintf(castF, "%s\n", hj)
	return r, nil
}

func (r *Recorder) WriteOutput(b []byte) {
	if len(b) == 0 {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.closed {
		return
	}
	r.out += int64(len(b))
	r.writeCast("o", b)
}

func (r *Recorder) WriteInput(b []byte) {
	if len(b) == 0 {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.closed {
		return
	}
	r.in += int64(len(b))
	_, _ = r.inF.Write(b)
}

func (r *Recorder) writeCast(kind string, b []byte) {
	ev := []any{time.Since(r.start).Seconds(), kind, string(b)}
	j, _ := json.Marshal(ev)
	_, _ = r.castF.Write(j)
	_, _ = r.castF.Write([]byte("\n"))
}

// Cmd 记录一行命令（warn 表示它是被灰名单拦下、尚未执行的）。
func (r *Recorder) Cmd(line string, warn bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.closed {
		return
	}
	tag := ""
	if warn {
		tag = "[graylist] "
	}
	fmt.Fprintf(r.cmdF, "%s  %s%s\n", time.Now().Format("15:04:05"), tag, line)
}

func (r *Recorder) Event(kind, detail string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.events = append(r.events, map[string]string{"t": time.Now().Format(time.RFC3339), "kind": kind, "detail": detail})
}

func (r *Recorder) Close(exit int) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.closed {
		return
	}
	r.closed = true
	dur := time.Since(r.start)

	meta := map[string]any{
		"user": r.user, "target": r.target, "peer": r.peer,
		"started": r.start.Format(time.RFC3339), "duration_s": dur.Seconds(),
		"exit": exit, "bytes_in": r.in, "bytes_out": r.out,
		"cast": filepath.Base(r.base) + ".cast", "events": r.events,
	}
	mj, _ := json.MarshalIndent(meta, "", "  ")
	_ = os.WriteFile(r.base+".meta.json", mj, 0o644)

	idx, _ := json.Marshal(map[string]any{
		"t": r.start.Format(time.RFC3339), "user": r.user, "target": r.target, "peer": r.peer,
		"file": filepath.Base(r.base) + ".cast", "dir": filepath.Base(filepath.Dir(r.base)),
		"duration_s": dur.Seconds(), "exit": exit,
	})
	f, err := os.OpenFile(filepath.Join(r.root, "sessions.jsonl"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err == nil {
		_, _ = f.Write(idx)
		_, _ = f.Write([]byte("\n"))
		_ = f.Close()
	}

	_ = r.castF.Close()
	_ = r.inF.Close()
	_ = r.cmdF.Close()
}
