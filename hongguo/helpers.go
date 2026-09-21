package hongguo

import (
	"encoding/json"
	"fmt"
	"html"
	"net/netip"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"
)

var (
	NumericID            = regexp.MustCompile(`^[0-9]{1,32}$`)
	qualityNumber        = regexp.MustCompile(`[0-9]+`)
	reDateText           = regexp.MustCompile(`\d{4}-\d{1,2}-\d{1,2}`)
	finishedEpisodeRemark = regexp.MustCompile(`(?:全\s*\d+\s*集|\d+\s*集全|已完结|大结局)`)
	rankingScriptTags    = regexp.MustCompile(`(?is)<script\b[^>]*>`)
)

func DramaID(sourceID string) string {
	return Source + ":" + strings.TrimSpace(sourceID)
}

func ChapterID(sourceID, videoID string) string {
	return Source + ":" + strings.TrimSpace(sourceID) + ":" + strings.TrimSpace(videoID)
}

func SplitDramaID(identifier string) (sourceID string, ok bool) {
	identifier = strings.TrimSpace(identifier)
	source, id, prefixed := strings.Cut(identifier, ":")
	if prefixed {
		if CanonicalSource(source) != Source {
			return "", false
		}
		sourceID = id
	} else {
		sourceID = identifier
	}
	sourceID = strings.TrimSpace(strings.TrimPrefix(sourceID, "hg-series-v1:"))
	if !NumericID.MatchString(sourceID) {
		return "", false
	}
	return sourceID, true
}

func CanonicalSource(source string) string {
	switch strings.ToLower(strings.TrimSpace(source)) {
	case Source, "hongguoduanju.com", "www.hongguoduanju.com":
		return Source
	default:
		return ""
	}
}

func VideoIDFromURL(videoURL string) string {
	return strings.TrimPrefix(strings.TrimSpace(videoURL), MediaScheme)
}

func MediaPlaceholder(videoID string) string {
	return MediaScheme + strings.TrimSpace(videoID)
}

func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if strings.TrimSpace(v) != "" {
			return strings.TrimSpace(v)
		}
	}
	return ""
}

func mapString(m map[string]any, keys ...string) string {
	for _, key := range keys {
		if v, ok := m[key]; ok {
			switch x := v.(type) {
			case string:
				if text := strings.TrimSpace(x); text != "" {
					return text
				}
			case bool:
				return strconv.FormatBool(x)
			case float64:
				if x == float64(int64(x)) {
					return strconv.FormatInt(int64(x), 10)
				}
				return strconv.FormatFloat(x, 'f', -1, 64)
			case int:
				return strconv.Itoa(x)
			case json.Number:
				return x.String()
			}
		}
	}
	return ""
}

func mapStringSlice(m map[string]any, keys ...string) []string {
	seen := map[string]bool{}
	var out []string
	add := func(s string) {
		s = strings.TrimSpace(s)
		if s != "" && !seen[s] {
			seen[s] = true
			out = append(out, s)
		}
	}
	for _, key := range keys {
		v, ok := m[key]
		if !ok {
			continue
		}
		switch x := v.(type) {
		case string:
			for _, part := range strings.FieldsFunc(x, func(r rune) bool { return r == ',' || r == '/' || r == '，' || r == '、' }) {
				add(part)
			}
		case []any:
			for _, item := range x {
				add(fmt.Sprint(item))
			}
		}
	}
	return out
}

func nestedMap(v any, keys ...string) map[string]any {
	cur, _ := v.(map[string]any)
	for _, key := range keys {
		if cur == nil {
			return nil
		}
		cur, _ = cur[key].(map[string]any)
	}
	return cur
}

func anyList(v any) []any {
	switch x := v.(type) {
	case []any:
		return x
	case map[string]any:
		for _, key := range []string{"list", "items", "data"} {
			if out := anyList(x[key]); len(out) > 0 {
				return out
			}
		}
	}
	return nil
}

func IsHTTPMediaURL(raw string) bool {
	parsed, err := url.Parse(strings.TrimSpace(raw))
	return err == nil && (parsed.Scheme == "http" || parsed.Scheme == "https") && parsed.Hostname() != "" && parsed.User == nil
}

func extractAttr(block string, names ...string) string {
	for _, name := range names {
		re := regexp.MustCompile(`(?is)\b` + regexp.QuoteMeta(name) + `\s*=\s*["']([^"']+)["']`)
		if m := re.FindStringSubmatch(block); len(m) > 1 {
			return strings.TrimSpace(html.UnescapeString(m[1]))
		}
	}
	return ""
}

func normalizeDate(s string) string {
	s = strings.TrimSpace(s)
	if s == "" {
		return ""
	}
	matches := reDateText.FindAllString(s, -1)
	for _, m := range matches {
		parts := strings.Split(m, "-")
		if len(parts) != 3 {
			continue
		}
		y, yErr := strconv.Atoi(parts[0])
		mo, moErr := strconv.Atoi(parts[1])
		d, dErr := strconv.Atoi(parts[2])
		if yErr == nil && moErr == nil && dErr == nil && y >= 2000 && y <= 2100 && mo >= 1 && mo <= 12 && d >= 1 && d <= 31 {
			return fmt.Sprintf("%04d-%02d-%02d", y, mo, d)
		}
	}
	return ""
}

func timestampDate(value string) string {
	stamp, err := strconv.ParseInt(strings.TrimSpace(value), 10, 64)
	if err != nil || stamp <= 0 {
		return ""
	}
	if stamp > 100_000_000_000 {
		stamp /= 1000
	}
	date := timeUnixInChina(stamp)
	if date.Year() < 2000 || date.Year() > 2100 {
		return ""
	}
	return date.Format("2006-01-02")
}

func releaseStatusFromRemark(remark string) string {
	if strings.Contains(remark, "未完结") || strings.Contains(remark, "更新至") || strings.Contains(remark, "连载") {
		return "ongoing"
	}
	if finishedEpisodeRemark.MatchString(remark) || strings.Contains(remark, "完结") {
		return "finished"
	}
	return "unknown"
}

func coverPathFromAny(v any) string {
	switch x := v.(type) {
	case nil:
		return ""
	case string:
		s := strings.TrimSpace(x)
		if s == "" {
			return ""
		}
		if u, err := url.Parse(s); err == nil && u.IsAbs() {
			return u.String()
		}
		return strings.TrimLeft(s, "/")
	case map[string]any:
		for _, key := range []string{"url", "src", "path", "cover", "coverUrl", "cover_url", "image", "pic", "poster"} {
			if s := coverPathFromAny(x[key]); s != "" {
				return s
			}
		}
	}
	return ""
}

func validImageURL(remote *url.URL) bool {
	if remote == nil || remote.Scheme != "https" || remote.Opaque != "" || remote.User != nil ||
		(remote.Port() != "" && remote.Port() != "443") {
		return false
	}
	host := strings.ToLower(strings.TrimSuffix(remote.Hostname(), "."))
	if ip, err := netip.ParseAddr(host); err == nil {
		return publicImageAddress(ip)
	}
	if len(host) > 253 || !strings.Contains(host, ".") || strings.ContainsAny(host, ":%\\") {
		return false
	}
	for _, suffix := range []string{"localhost", "local", "internal", "lan", "home", "invalid", "test", "example"} {
		if host == suffix || strings.HasSuffix(host, "."+suffix) {
			return false
		}
	}
	for _, label := range strings.Split(host, ".") {
		if label == "" || len(label) > 63 || label[0] == '-' || label[len(label)-1] == '-' {
			return false
		}
		for _, ch := range label {
			if ch != '-' && (ch < 'a' || ch > 'z') && (ch < '0' || ch > '9') {
				return false
			}
		}
	}
	return true
}

func publicImageAddress(address netip.Addr) bool {
	if address.Zone() != "" {
		return false
	}
	address = address.Unmap()
	if !address.IsGlobalUnicast() || address.IsPrivate() {
		return false
	}
	for _, network := range []string{
		"0.0.0.0/8", "100.64.0.0/10", "192.0.0.0/24", "192.0.2.0/24",
		"198.18.0.0/15", "198.51.100.0/24", "203.0.113.0/24", "240.0.0.0/4",
		"64:ff9b::/96", "64:ff9b:1::/48", "100::/64", "2001::/32",
		"2001:db8::/32", "2002::/16",
	} {
		prefix := netip.MustParsePrefix(network)
		if prefix.Contains(address) {
			return false
		}
	}
	return true
}

func CoverAddress(values ...string) string {
	for _, value := range values {
		value = strings.TrimSpace(value)
		if value == "" || len(value) > 8192 {
			continue
		}
		parsed, err := url.Parse(value)
		if err == nil && validImageURL(parsed) {
			return value
		}
	}
	return ""
}

func rawEpisode(n int) json.RawMessage {
	if n <= 0 {
		n = 1
	}
	return json.RawMessage(strconv.Itoa(n))
}

func truncate(s string, n int) string {
	s = strings.TrimSpace(s)
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n]) + "..."
}

func catalogBlockReason(status int, headers map[string][]string, body []byte) string {
	if len(body) > 64*1024 {
		body = body[:64*1024]
	}
	page := strings.ToLower(string(body))
	cf := ""
	if values := headers["Cf-Mitigated"]; len(values) > 0 {
		cf = values[0]
	}
	if strings.Contains(page, "cloudflare") && (strings.Contains(page, "sorry, you have been blocked") || strings.Contains(page, "you are unable to access")) {
		return "Cloudflare 拒绝了当前请求"
	}
	if strings.EqualFold(cf, "challenge") || strings.Contains(page, "_cf_chl_opt") || strings.Contains(page, "<title>just a moment") && strings.Contains(page, "cloudflare") {
		return "站点要求浏览器验证，当前请求无法通过"
	}
	_ = status
	return ""
}

func mergeDrama(base, extra Drama) Drama {
	if strings.TrimSpace(base.ID) == "" {
		base.ID = extra.ID
	}
	if strings.TrimSpace(base.Source) == "" {
		base.Source = extra.Source
	}
	if strings.TrimSpace(base.SourceID) == "" {
		base.SourceID = extra.SourceID
	}
	if strings.TrimSpace(base.Title) == "" {
		base.Title = extra.Title
	}
	if strings.TrimSpace(base.Name) == "" {
		base.Name = extra.Name
	}
	if strings.TrimSpace(base.Desc) == "" {
		base.Desc = extra.Desc
	}
	if strings.TrimSpace(base.Intro) == "" {
		base.Intro = extra.Intro
	}
	if strings.TrimSpace(base.Cover) == "" {
		base.Cover = extra.Cover
	}
	if strings.TrimSpace(base.CoverURL) == "" {
		base.CoverURL = extra.CoverURL
	}
	if strings.TrimSpace(base.TotalEpisode) == "" {
		base.TotalEpisode = extra.TotalEpisode
	}
	if strings.TrimSpace(base.EpisodeCount) == "" {
		base.EpisodeCount = extra.EpisodeCount
	}
	if strings.TrimSpace(base.ChannelName) == "" {
		base.ChannelName = extra.ChannelName
	}
	if strings.TrimSpace(base.CategoryName) == "" || (base.CategoryName == "首页" && extra.CategoryName != "") {
		base.CategoryName = extra.CategoryName
	}
	if strings.TrimSpace(base.Remark) == "" || base.Remark == "在线观看" {
		base.Remark = extra.Remark
	}
	if strings.TrimSpace(base.Score) == "" {
		base.Score = extra.Score
	}
	if strings.TrimSpace(base.Views) == "" {
		base.Views = extra.Views
	}
	if strings.TrimSpace(base.Heat) == "" {
		base.Heat = extra.Heat
	}
	if strings.TrimSpace(base.OnlineDate) == "" {
		base.OnlineDate = extra.OnlineDate
	}
	if len(base.Tags) == 0 {
		base.Tags = extra.Tags
	}
	if base.ReleaseStatus == "" || base.ReleaseStatus == "unknown" {
		base.ReleaseStatus = extra.ReleaseStatus
	}
	return base
}

func timeUnixInChina(stamp int64) time.Time {
	return time.Unix(stamp, 0).In(ChinaTime)
}
