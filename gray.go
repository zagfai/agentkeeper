package main

import (
	"bufio"
	"crypto/md5"
	"encoding/hex"
	"fmt"
	"io"
	"regexp"
	"strings"
	"sync"
)

// GrayList：危险命令灰名单。命中后不直接执行：
// 第一次返回警告并拒绝本次执行；**连续两条 MD5 完全一致**的同一条指令（重发）视为确认，放行。
// 规则为正则（RE2，Go regexp 语法），来源：配置 gray.patterns。无时间窗。
type GrayList struct {
	res []*regexp.Regexp

	mu      sync.Mutex
	lastMD5 string // 上一条指令的 MD5（单客户端，全局）
}

// newGrayList 编译灰名单正则；非法正则在启动/check 时即报错。
func newGrayList(patterns []string) (*GrayList, error) {
	g := &GrayList{}
	for _, p := range patterns {
		p = strings.TrimSpace(p)
		if p == "" {
			continue
		}
		re, err := regexp.Compile(p)
		if err != nil {
			return nil, fmt.Errorf("gray pattern %q: %w", p, err)
		}
		g.res = append(g.res, re)
	}
	return g, nil
}

// normalizeCmd 规整命令文本：去掉引号与反斜杠，再折叠空白。
// 去引号意在抵消 shell 的引号拼接（r”m -rf → rm -rf），降低拆字绕过灰名单的概率；
// 这依旧是启发式减速手段，不构成安全屏障。
func normalizeCmd(s string) string {
	s = strings.NewReplacer("'", "", "\"", "", "\\", "").Replace(s)
	return strings.Join(strings.Fields(s), " ")
}

// Check 返回（命中规则, 是否确认）。命中且未确认时，调用方应警告并拒绝本次执行。
// 命中判定：每条正则匹配"原始命令"与"去引号/反斜杠变形"两种文本（任一命中即算）。
// 确认判定：本次指令与上一条指令的 MD5 完全相同（连续两条一致的指令）。无时间窗。
func (g *GrayList) Check(cmd string) (string, bool) {
	norm := normalizeCmd(cmd)
	sum := md5.Sum([]byte(strings.TrimSpace(cmd)))
	m := hex.EncodeToString(sum[:])

	var hit string
	if norm != "" && len(g.res) > 0 {
		for _, re := range g.res {
			if re.MatchString(cmd) || re.MatchString(norm) {
				hit = re.String()
				break
			}
		}
	}

	g.mu.Lock()
	defer g.mu.Unlock()
	confirmed := hit != "" && m == g.lastMD5
	g.lastMD5 = m
	if hit == "" {
		return "", false
	}
	return hit, confirmed
}

func grayWarnText(hit string) string {
	return "────────────────────────────────────────\n" +
		"[graylist] This command may be destructive (matched rule: " + hit + ").\n" +
		"Think it over. To proceed anyway, resend the exact same command.\n" +
		"────────────────────────────────────────"
}

// eolText 规范注入会话的文本行尾：交互式会话本地 tty 处于 raw 模式，
// 必须用 CRLF，否则换行后光标停在原列（屏幕会错位）；管道/文件场景保持 LF。
func eolText(s string, rawTTY bool) string {
	nl := "\n"
	if rawTTY {
		nl = "\r\n"
	}
	return strings.ReplaceAll(s, "\n", nl) + nl
}

// lineShadow 以启发式方法从按键字节流里近似还原"当前正在编辑的行"。
// 仅用于危险命令的减速提醒，不是可靠的命令解析（依赖内容仍以录制为准）。
type lineShadow struct {
	line  []byte
	dirty bool
}

func (ls *lineShadow) reset() {
	ls.line = ls.line[:0]
	ls.dirty = false
}

// feed 处理一个字节；返回是否构成提交、提交时该行文本、以及本行是否含不可跟踪的编辑。
func (ls *lineShadow) feed(b byte) (bool, string, bool) {
	switch b {
	case '\r', '\n':
		text, dirty := string(ls.line), ls.dirty
		ls.reset()
		return true, text, dirty
	case 0x03, 0x15: // Ctrl-C / Ctrl-U
		ls.reset()
	case 0x08, 0x7f: // Backspace
		if len(ls.line) > 0 {
			ls.line = ls.line[:len(ls.line)-1]
		}
	case 0x09, 0x1b: // Tab / ESC：后续编辑无法跟踪
		ls.dirty = true
	default:
		if b >= 0x20 {
			ls.line = append(ls.line, b)
		} else {
			ls.dirty = true // 其它控制字符（光标移动等）无法跟踪
		}
	}
	return false, "", ls.dirty
}

// inputPump 把客户端输入转发给远端，并在提交行时做灰名单拦截。
func inputPump(br *bufio.Reader, dst io.WriteCloser, out *lockedWriter, rec *Recorder, gray *GrayList) {
	defer dst.Close()
	buf := make([]byte, 4096)
	var sh lineShadow
	lastCR := false
	lastSwallowed := false
	for {
		n, err := br.Read(buf)
		if n > 0 {
			chunk := buf[:n]
			rec.WriteInput(chunk)
			fwd := make([]byte, 0, n)
			for _, b := range chunk {
				if b == '\n' && lastCR { // CRLF 的后半截，与 \r 同命运
					lastCR = false
					if !lastSwallowed {
						fwd = append(fwd, b)
					}
					lastSwallowed = false
					continue
				}
				commit, text, dirty := sh.feed(b)
				if b == '\r' {
					lastCR = true
				} else {
					lastCR = false
				}
				if !commit {
					fwd = append(fwd, b)
					continue
				}
				line := strings.TrimSpace(text)
				if line == "" || dirty {
					fwd = append(fwd, b)
					lastSwallowed = false
					continue
				}
				hit, confirmed := gray.Check(line)
				if hit != "" && !confirmed {
					rec.Cmd(line, true)
					rec.Event("gray", "hit rule "+hit+", cmd: "+line)
					lastSwallowed = true
					// 向远端发 Ctrl-C 中断这条命令：行缓冲被整体作废、提示符复位，
					// readline 与屏幕状态同步干净；重发同一条命令即可执行。
					fwd = append(fwd, 0x03)
					_, _ = out.Write([]byte(eolText("\n"+grayWarnText(hit), true)))
					continue
				}
				rec.Cmd(line, false)
				fwd = append(fwd, b)
				lastSwallowed = false
			}
			if len(fwd) > 0 {
				if _, werr := dst.Write(fwd); werr != nil {
					return
				}
			}
		}
		if err != nil {
			return
		}
	}
}
