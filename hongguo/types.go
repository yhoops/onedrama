package hongguo

import (
	"encoding/json"
	"strconv"
	"strings"
	"time"
)

const (
	Source          = "hongguo"
	WebBaseURL      = "https://hongguoduanju.com"
	AppBaseURL      = "https://api5-normal-sinfonlineb.fqnovel.com"
	PlaybackAPIURL  = "https://djapi.999888456.xyz/api/hongguo/play"
	AppUserAgent    = "com.phoenix.read/73532 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 QuicVersion:c67e9834 2025-09-08)"
	WebUserAgent    = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.6 Mobile/15E148 Safari/604.1"
	AppAID          = "8662"
	AppName         = "novelread"
	AppVersionCode  = "73532"
	AppVersionName  = "7.3.5.32"
	MediaScheme     = "hongguo-cenc://"
	MaxBodyBytes    = 20 * 1024 * 1024
	ChinaOffset     = 8 * 60 * 60
)

var ChinaTime = time.FixedZone("CST", ChinaOffset)

type Drama struct {
	ID            string   `json:"id"`
	Source        string   `json:"source,omitempty"`
	SourceID      string   `json:"sourceId,omitempty"`
	Title         string   `json:"title"`
	Name          string   `json:"name"`
	Desc          string   `json:"desc"`
	Intro         string   `json:"intro"`
	Cover         string   `json:"cover,omitempty"`
	CoverURL      string   `json:"coverUrl,omitempty"`
	CategoryName  string   `json:"categoryName,omitempty"`
	ChannelName   string   `json:"channelName,omitempty"`
	Remark        string   `json:"remark,omitempty"`
	TotalEpisode  string   `json:"totalEpisode,omitempty"`
	EpisodeCount  string   `json:"episodeCount,omitempty"`
	Tags          []string `json:"tags,omitempty"`
	ReleaseStatus string   `json:"releaseStatus,omitempty"`
	Score         string   `json:"score,omitempty"`
	Views         string   `json:"views,omitempty"`
	Heat          string   `json:"heat,omitempty"`
	OnlineDate    string   `json:"onlineDate,omitempty"`
}

func (d Drama) DisplayTitle() string {
	if strings.TrimSpace(d.Title) != "" {
		return d.Title
	}
	if strings.TrimSpace(d.Name) != "" {
		return d.Name
	}
	return "短剧"
}

type Chapter struct {
	ID             string          `json:"id"`
	Source         string          `json:"source,omitempty"`
	Title          string          `json:"title"`
	VideoURL       string          `json:"videoUrl"`
	CurrentEpisode json.RawMessage `json:"currentEpisode"`
}

func (c Chapter) EpisodeString(fallback int) string {
	if len(c.CurrentEpisode) > 0 && string(c.CurrentEpisode) != "null" {
		var s string
		if err := json.Unmarshal(c.CurrentEpisode, &s); err == nil && strings.TrimSpace(s) != "" {
			return strings.TrimSpace(s)
		}
		var n int
		if err := json.Unmarshal(c.CurrentEpisode, &n); err == nil && n > 0 {
			return strconv.Itoa(n)
		}
		var f float64
		if err := json.Unmarshal(c.CurrentEpisode, &f); err == nil && f > 0 {
			return strconv.Itoa(int(f))
		}
	}
	return strconv.Itoa(fallback)
}

type Media struct {
	URL     string
	Referer string
	// Duration 是整集时长。
	Duration time.Duration
	CENCKey  []byte
	// Quality 是**档位标签**（来自 definition），不是像素高：实测有剧把 1280x720 标成
	// 「1080p」。要拿真实尺寸用 Width/Height。
	Quality  int
	Width    int
	Height   int
	Variants []Media
}

type Detail struct {
	Drama    Drama
	Chapters []Chapter
}

type SearchResult struct {
	Dramas  []Drama
	Total   int
	Limited bool
	Warning string
}

type Suggestion struct {
	Name string `json:"name"`
	Type string `json:"type,omitempty"`
}

type CatalogCursor struct {
	Offset        int       `json:"offset"`
	SessionID     string    `json:"sessionId,omitempty"`
	LastID        string    `json:"lastId,omitempty"`
	PageSignature string    `json:"pageSignature,omitempty"`
	Initialized   bool      `json:"initialized"`
	Exhausted     bool      `json:"exhausted"`
	UpdatedAt     time.Time `json:"updatedAt"`
}

type RecommendationQuery struct {
	Genre     string   `json:"genre"`
	Offset    int      `json:"offset"`
	SessionID string   `json:"sessionId"`
	Seen      []string `json:"seen"`
}

type RecommendationPage struct {
	Dramas     []Drama `json:"data"`
	NextOffset int     `json:"nextOffset"`
	SessionID  string  `json:"sessionId"`
	HasMore    bool    `json:"hasMore"`
}

type RankingBoard struct {
	ID          string
	Name        string
	Description string
	Path        string
	UpstreamKey string
}

type RankingItem struct {
	Rank   int    `json:"rank"`
	Drama  Drama  `json:"drama"`
	Metric string `json:"metric,omitempty"`
}

type RankingPage struct {
	BoardID     string        `json:"boardId"`
	Page        int           `json:"page"`
	Items       []RankingItem `json:"items"`
	HasMore     bool          `json:"hasMore"`
	TotalPages  int           `json:"totalPages,omitempty"`
	UpdatedText string        `json:"updatedText,omitempty"`
}

type DanmakuItem struct {
	ID     string `json:"id"`
	Text   string `json:"text"`
	TimeMS int64  `json:"timeMs"`
}

type DanmakuPage struct {
	Items   []DanmakuItem `json:"items"`
	StartMS int64         `json:"startMs"`
	NextMS  int64         `json:"nextMs"`
	Total   int64         `json:"total"`
}

var RankingBoards = []RankingBoard{
	{ID: "hongguo-hot", Name: "总热播榜", Description: "红果观看、互动等综合热度；每日更新。", Path: "hot-drama", UpstreamKey: "hongguo"},
	{ID: "hongguo-real", Name: "真人剧榜", Description: "红果真人剧热播榜；每日更新。", Path: "hot-real-drama", UpstreamKey: "real"},
	{ID: "hongguo-comic", Name: "漫剧榜", Description: "红果漫剧热播榜；每日更新。", Path: "hot-comic-drama", UpstreamKey: "comic"},
	{ID: "hongguo-ai", Name: "AI剧榜", Description: "红果 AI 剧热播榜；每日更新。", Path: "hot-ai-drama", UpstreamKey: "ai"},
}

var AppGenres = []struct {
	Key   string
	Scene string
	Name  string
}{
	{Key: "short_play", Scene: "default", Name: "真人剧"},
	{Key: "comic_series", Scene: "comic_series", Name: "漫剧"},
	{Key: "ai_series", Scene: "ai_series", Name: "AI剧"},
}

var WebCategories = []struct {
	Path string
	Name string
}{
	{Path: "real-drama", Name: "真人剧"},
	{Path: "comic-drama", Name: "漫剧"},
	{Path: "ai-drama", Name: "AI剧"},
	{Path: "comic", Name: "动漫"},
}
