package hongguo

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"unicode"
)

const (
	DanmakuWindowMS     = 30_000
	DanmakuMaxDurationMS = 24 * 60 * 60 * 1000
)

func ParseDanmaku(result map[string]any, videoID string, start, duration int64) (DanmakuPage, error) {
	data := nestedMap(result, "data")
	rows, valid := data["data_list"].([]any)
	next, err := strconv.ParseInt(mapString(nestedMap(data, "extra"), "next_query_danmaku_list_time"), 10, 64)
	if !valid || err != nil || next <= start || next > DanmakuMaxDurationMS {
		return DanmakuPage{}, errors.New("红果弹幕时间段格式无效")
	}
	page := DanmakuPage{Items: []DanmakuItem{}, StartMS: start, NextMS: min(next, duration)}
	var cursor struct {
		Total int64 `json:"danmaku_count"`
	}
	if raw := mapString(nestedMap(data, "common_list_info"), "cursor"); len(raw) <= 8192 && json.Unmarshal([]byte(raw), &cursor) == nil && cursor.Total >= 0 {
		page.Total = cursor.Total
	}
	seen := map[string]bool{}
	for _, raw := range rows {
		row, _ := raw.(map[string]any)
		comment := nestedMap(row, "comment")
		common := nestedMap(comment, "common")
		if mapString(common, "group_id") != videoID || mapString(common, "status") != "1" {
			continue
		}
		position, err := strconv.ParseInt(mapString(nestedMap(comment, "expand"), "offset_time"), 10, 64)
		text := strings.TrimSpace(strings.Map(func(r rune) rune {
			if unicode.IsControl(r) || r == ' ' || r == ' ' {
				return ' '
			}
			return r
		}, mapString(nestedMap(common, "content"), "text")))
		id := mapString(comment, "comment_id")
		if err != nil || position < start || position >= page.NextMS || text == "" || id == "" || len(id) > 120 || seen[id] {
			continue
		}
		if runes := []rune(text); len(runes) > 180 {
			text = string(runes[:180]) + "…"
		}
		seen[id] = true
		page.Items = append(page.Items, DanmakuItem{ID: id, Text: text, TimeMS: position})
		if len(page.Items) == 90 {
			break
		}
	}
	sort.SliceStable(page.Items, func(i, j int) bool { return page.Items[i].TimeMS < page.Items[j].TimeMS })
	return page, nil
}

func (c *Client) FetchDanmaku(ctx context.Context, seriesID, videoID string, start, duration int64) (DanmakuPage, error) {
	if !NumericID.MatchString(seriesID) || !NumericID.MatchString(videoID) || start < 0 || duration <= start || duration > DanmakuMaxDurationMS {
		return DanmakuPage{}, errors.New("弹幕请求参数无效")
	}
	body := map[string]any{
		"comment_source": 601, "server_channel": 1000, "group_id": videoID, "group_type": 30,
		"comment_type": 20, "sort": 1, "count": 90, "cursor": "", "aid": 8662, "compliance_status": 0,
		"business_param": map[string]any{"book_id": seriesID, "start_offset_time": start, "playlet_item_duration": duration, "need_danmaku_guide_type": []int{1, 3, 4, 2}},
	}
	result, err := c.CommentRequest(ctx, http.MethodPost, "/novel/commentapi/comment/list/"+videoID+"/v1/", nil, body)
	if err != nil {
		return DanmakuPage{}, err
	}
	return ParseDanmaku(result, videoID, start, duration)
}
