#!/usr/bin/env python3
# 迷你 ANSI 渲染器：把 asciinema cast 的 "o" 事件回放到屏幕，用于检查录制观感。
# 用法: python3 render_cast.py <cast文件> [关键字]
import json, sys, unicodedata

W, H = 80, 24

class Term:
    def __init__(self):
        self.g = [[' '] * W for _ in range(H)]
        self.x = self.y = 0
    def newline(self):
        if self.y >= H - 1:
            self.g.pop(0)
            self.g.append([' '] * W)
        else:
            self.y += 1
    def put(self, ch):
        w = 2 if unicodedata.east_asian_width(ch) in 'WF' else 1
        if self.x + w > W:
            self.x = 0
            self.newline()
        self.g[self.y][self.x] = ch
        if w == 2 and self.x + 1 < W:
            self.g[self.y][self.x + 1] = ''
        self.x += w
    def erase_line(self, x0, x1):
        for i in range(max(0, x0), min(W, x1)):
            self.g[self.y][i] = ' '
    def lines(self):
        return [''.join(r).rstrip() for r in self.g]

def feed(t, s):
    i, n = 0, len(s)
    while i < n:
        c = s[i]
        if c == '\x1b':
            if i + 1 < n and s[i+1] == ']':
                j = i + 2
                while j < n and s[j] not in '\x07\x1b': j += 1
                i = j + 1
                continue
            if i + 1 < n and s[i+1] == '[':
                j = i + 2
                while j < n and not ('@' <= s[j] <= '~'): j += 1
                if j >= n: break
                params = s[i+2:j]; fin = s[j]
                ps = [int(p) if p.isdigit() else 0 for p in params.lstrip('?').split(';')] if params.lstrip('?') else []
                p0 = ps[0] if ps else 0
                if fin == 'K':
                    if p0 == 0: t.erase_line(t.x, W)
                    elif p0 == 1: t.erase_line(0, t.x + 1)
                    else: t.erase_line(0, W)
                elif fin == 'C': t.x = min(W - 1, t.x + (p0 or 1))
                elif fin == 'D': t.x = max(0, t.x - (p0 or 1))
                elif fin in 'Hf':
                    t.y = min(H - 1, (ps[0] if len(ps) > 0 and ps[0] else 1) - 1)
                    t.x = min(W - 1, (ps[1] if len(ps) > 1 and ps[1] else 1) - 1)
                elif fin == 'J':
                    if p0 in (2, 3): t.g = [[' '] * W for _ in range(H)]
                    else: t.erase_line(t.x, W)
                i = j + 1
                continue
            i += 2
            continue
        if c == '\r': t.x = 0
        elif c == '\n': t.newline()
        elif c == '\b': t.x = max(0, t.x - 1)
        elif c == '\t': t.x = min(W - 1, t.x + 8 - t.x % 8)
        elif c < ' ' or c == '\x7f': pass
        else: t.put(c)
        i += 1

def main():
    path = sys.argv[1]
    kw = sys.argv[2] if len(sys.argv) > 2 else None
    evs = []
    with open(path) as f:
        json.loads(f.readline())
        for line in f:
            if line.strip(): evs.append(json.loads(line))
    t = Term()
    for idx, e in enumerate(evs):
        feed(t, e[2])
        if kw:
            ls = t.lines()
            if any(kw in l for l in ls):
                rows = [l for l in ls if l.strip()]
                print(f'--- event {idx} @{round(e[0],2)}s')
                for r in rows[-3:]:
                    print('  |', r)
    print('=== 最终屏幕 ===')
    for l in t.lines():
        if l.strip():
            print('|', l)

if __name__ == '__main__':
    main()
