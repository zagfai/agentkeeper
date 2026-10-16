package main

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha1"
	"encoding/base32"
	"encoding/binary"
	"fmt"
	"net/url"
	"strings"
	"time"
)

var b32 = base32.StdEncoding.WithPadding(base32.NoPadding)

func genTOTPSecret() (string, error) {
	buf := make([]byte, 20)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	return b32.EncodeToString(buf), nil
}

func normalizeSecret(s string) string {
	s = strings.ToUpper(s)
	s = strings.ReplaceAll(s, " ", "")
	s = strings.ReplaceAll(s, "-", "")
	s = strings.TrimRight(s, "=")
	return s
}

// totpCode 按 RFC 6238（SHA1/6位/30秒）计算某时刻的动态口令。
func totpCode(secret string, t time.Time) (string, error) {
	key, err := b32.DecodeString(normalizeSecret(secret))
	if err != nil {
		return "", err
	}
	counter := uint64(t.Unix() / 30)
	var buf [8]byte
	binary.BigEndian.PutUint64(buf[:], counter)
	mac := hmac.New(sha1.New, key)
	mac.Write(buf[:])
	sum := mac.Sum(nil)
	off := sum[len(sum)-1] & 0x0f
	code := (uint32(sum[off])&0x7f)<<24 | uint32(sum[off+1])<<16 | uint32(sum[off+2])<<8 | uint32(sum[off+3])
	return fmt.Sprintf("%06d", code%1000000), nil
}

// totpBackWindows：向前容错的窗口数（每窗 30 秒）。往前 10 窗 ≈ 5 分钟有效。
const totpBackWindows = 10

// verifyTOTP 接受往前 totpBackWindows 个窗口的码、当前窗口，以及往后 1 窗（时钟超前容错）。
func verifyTOTP(secret, input string) bool {
	input = strings.TrimSpace(input)
	if len(input) != 6 {
		return false
	}
	now := time.Now()
	for skew := -totpBackWindows; skew <= 1; skew++ {
		code, err := totpCode(secret, now.Add(time.Duration(skew)*30*time.Second))
		if err == nil && code == input {
			return true
		}
	}
	return false
}

func totpURI(secret, label, issuer string) string {
	q := url.Values{}
	q.Set("secret", normalizeSecret(secret))
	q.Set("issuer", issuer)
	q.Set("algorithm", "SHA1")
	q.Set("digits", "6")
	q.Set("period", "30")
	return fmt.Sprintf("otpauth://totp/%s:%s?%s", url.PathEscape(issuer), url.PathEscape(label), q.Encode())
}
