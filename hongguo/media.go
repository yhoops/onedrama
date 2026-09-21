package hongguo

import (
	"context"
	"crypto/aes"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"
)

func SelectAppMedia(model map[string]any) (Media, error) {
	variants := anyList(model["video_list"])
	if rows, ok := model["video_list"].(map[string]any); ok && len(variants) == 0 {
		keys := make([]string, 0, len(rows))
		for key := range rows {
			keys = append(keys, key)
		}
		sort.Strings(keys)
		for _, key := range keys {
			variants = append(variants, rows[key])
		}
	}
	duration, _ := strconv.ParseFloat(mapString(model, "video_duration", "duration"), 64)
	var selected Media
	bestQuality := -1
	var keyErr error
	choices := make(map[int]Media)
	scores := make(map[int]int)
	for _, row := range variants {
		variant, _ := row.(map[string]any)
		meta := nestedMap(variant, "video_meta")
		codec := strings.ToLower(mapString(meta, "codec_type"))
		if codec == "bytevc2" || strings.Contains(strings.ToLower(mapString(variant, "gear_des_key")), "bytevc2") {
			continue
		}
		address := mapString(variant, "main_url")
		if len(address) > 8192 || !IsHTTPMediaURL(address) {
			continue
		}
		media := Media{URL: address, Referer: "https://novel.snssdk.com/", Duration: time.Duration(duration * float64(time.Second))}
		encryption := nestedMap(variant, "encrypt_info")
		spade := mapString(encryption, "spade_a")
		if spade != "" || encryption["encrypt"] == true || mapString(encryption, "encryption_method") == "cenc-aes-ctr" {
			var err error
			media.CENCKey, err = ContentKey(spade)
			if err != nil {
				keyErr = err
				continue
			}
		}
		width, _ := strconv.Atoi(mapString(meta, "vwidth"))
		height, _ := strconv.Atoi(mapString(meta, "vheight"))
		// 真实像素尺寸单独留一份：下面的 height 会被 definition（档位标签）覆盖成 Quality。
		media.Width, media.Height = width, height
		if definition, err := strconv.Atoi(qualityNumber.FindString(mapString(meta, "definition"))); err == nil && definition > 0 {
			height = definition
		} else if width > 0 && (height == 0 || width < height) {
			height = width
		}
		media.Quality = height
		quality := height * 10
		if codec == "h264" || codec == "avc1" {
			quality++
		}
		if previous, exists := scores[height]; !exists || quality > previous {
			choices[height], scores[height] = media, quality
		}
		if selected.URL == "" || quality > bestQuality {
			selected, bestQuality = media, quality
		}
	}
	if selected.URL != "" {
		for _, media := range choices {
			selected.Variants = append(selected.Variants, media)
		}
		sort.Slice(selected.Variants, func(i, j int) bool { return selected.Variants[i].Quality > selected.Variants[j].Quality })
		return selected, nil
	}
	if keyErr != nil {
		return Media{}, fmt.Errorf("红果 App 媒体密钥不可用: %w", keyErr)
	}
	return Media{}, errors.New("红果 App 未返回兼容的媒体，已跳过不支持的编码")
}

func ParseWebMedia(body, seriesID, videoID string) (Media, error) {
	page := RouterLoaderMap(ParseRouterData(body), "player_", "player_page")
	if mapString(page, "vid") != videoID || mapString(page, "series_id") != seriesID {
		return Media{}, fmt.Errorf("红果未返回所请求的剧集，可能仅允许网页试看；请在站点确认该集的访问权限")
	}
	info, _ := page["video_player_info"].(map[string]any)
	mediaURL := mapString(info, "main_url")
	if !IsHTTPMediaURL(mediaURL) {
		return Media{}, fmt.Errorf("红果该集未提供公开播放地址，可能需要登录或 App 授权；不会将试看集冒充该集下载")
	}
	duration, _ := strconv.ParseFloat(mapString(info, "duration"), 64)
	return Media{URL: mediaURL, Referer: WebBaseURL + "/", Duration: time.Duration(duration * float64(time.Second))}, nil
}

type playbackReference struct {
	ContentType   int    `json:"content_type"`
	FromVideoID   string `json:"from_video_id"`
	SeriesID      string `json:"series_id"`
	VideoID       string `json:"vid"`
	VideoPlatform int    `json:"video_platform"`
}

type playbackResponse struct {
	Parse   json.RawMessage `json:"parse"`
	JX      json.RawMessage `json:"jx"`
	KeyURLs []struct {
		Name   string `json:"name"`
		URL    string `json:"src"`
		KeyID  string `json:"kid"`
		SpadeA string `json:"spade_a"`
	} `json:"key_urls"`
}

func ParsePlaybackAPI(body string) (Media, error) {
	decoded, err := DecodePlaybackResponse(body)
	if err != nil {
		return Media{}, err
	}
	var response playbackResponse
	if err := json.Unmarshal(decoded, &response); err != nil {
		return Media{}, errors.New("红果备用播放接口返回了无效数据")
	}
	for _, flag := range []json.RawMessage{response.Parse, response.JX} {
		switch strings.TrimSpace(string(flag)) {
		case "", "null", "false", "0", `"0"`, `""`:
		default:
			return Media{}, errors.New("红果备用播放接口没有返回直接媒体地址")
		}
	}
	var selected Media
	bestQuality := -1
	var keyErr error
	var variants []Media
	for _, option := range response.KeyURLs {
		mediaURL := strings.TrimSpace(option.URL)
		if len(mediaURL) > 8192 || !IsHTTPMediaURL(mediaURL) {
			continue
		}
		keyID, err := hex.DecodeString(strings.TrimSpace(option.KeyID))
		if err != nil || len(keyID) != aes.BlockSize {
			keyErr = errors.New("红果媒体密钥标识无效")
			continue
		}
		_ = keyID
		key, err := ContentKey(option.SpadeA)
		if err != nil {
			keyErr = err
			continue
		}
		quality, _ := strconv.Atoi(qualityNumber.FindString(option.Name))
		media := Media{URL: mediaURL, Referer: "https://novel.snssdk.com/", CENCKey: key, Quality: quality}
		variants = append(variants, media)
		if selected.URL == "" || quality > bestQuality {
			selected = media
			bestQuality = quality
		}
	}
	if selected.URL != "" {
		selected.Variants = variants
		return selected, nil
	}
	if keyErr != nil {
		return Media{}, keyErr
	}
	return Media{}, errors.New("红果备用播放接口未返回该集可用的媒体和密钥，请稍后重试或确认该集是否仍可访问")
}

func (c *Client) ResolveAppMedia(ctx context.Context, videoID string) (Media, error) {
	if !NumericID.MatchString(videoID) {
		return Media{}, errors.New("红果视频 ID 无效")
	}
	payload := map[string]any{
		"video_id": videoID, "content_type": 1,
		"biz_param": map[string]any{"need_all_video_definition": true, "video_platform": 3},
	}
	result, err := c.AppRequest(ctx, http.MethodPost, "/novel/player/video_model/v1/", nil, payload)
	if err != nil {
		return Media{}, err
	}
	data := nestedMap(result, "data")
	model, _ := data["video_model"].(map[string]any)
	if encoded, ok := data["video_model"].(string); ok {
		decoder := json.NewDecoder(strings.NewReader(encoded))
		decoder.UseNumber()
		if err := decoder.Decode(&model); err != nil {
			return Media{}, errors.New("红果 App 播放信息格式异常")
		}
	}
	return SelectAppMedia(model)
}

func (c *Client) ResolveWebMedia(ctx context.Context, seriesID, videoID string) (Media, error) {
	pageURL := c.webBase() + "/player/" + url.PathEscape(seriesID) + "/" + url.PathEscape(videoID)
	body, err := c.FetchText(ctx, pageURL, c.webBase()+"/")
	if err != nil {
		return Media{}, err
	}
	return ParseWebMedia(body, seriesID, videoID)
}

func (c *Client) ResolvePlaybackAPI(ctx context.Context, seriesID, videoID string) (Media, error) {
	if !NumericID.MatchString(seriesID) || !NumericID.MatchString(videoID) {
		return Media{}, errors.New("红果播放请求缺少有效的剧集 ID")
	}
	reference, err := json.Marshal(playbackReference{ContentType: 1004, SeriesID: seriesID, VideoID: videoID, VideoPlatform: 3})
	if err != nil {
		return Media{}, err
	}
	query := url.Values{"id": {base64.StdEncoding.EncodeToString(reference)}}
	body, err := c.FetchText(ctx, PlaybackAPIURL+"?"+query.Encode(), c.webBase()+"/")
	if err != nil {
		return Media{}, err
	}
	return ParsePlaybackAPI(body)
}

func (c *Client) ResolveMedia(ctx context.Context, seriesID, videoID string) (Media, error) {
	if !NumericID.MatchString(seriesID) || !NumericID.MatchString(videoID) {
		return Media{}, fmt.Errorf("红果章节 ID 无效，请重新获取章节")
	}
	media, nativeErr := c.ResolveAppMedia(ctx, videoID)
	if nativeErr == nil {
		return media, nil
	}
	if err := ctx.Err(); err != nil {
		return Media{}, err
	}
	media, pageErr := c.ResolveWebMedia(ctx, seriesID, videoID)
	if pageErr == nil {
		return media, nil
	}
	if err := ctx.Err(); err != nil {
		return Media{}, err
	}
	media, apiErr := c.ResolvePlaybackAPI(ctx, seriesID, videoID)
	if apiErr == nil {
		return media, nil
	}
	return Media{}, fmt.Errorf("红果 App 取流失败：%v；网页取流失败：%v；备用取流失败：%w", nativeErr, pageErr, apiErr)
}
