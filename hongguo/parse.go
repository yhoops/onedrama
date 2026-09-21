package hongguo

import (
	"encoding/json"
	"math"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"time"
)

func ParseRouterData(raw string) map[string]any {
	idx := regexp.MustCompile(`(?s)(?:window\.)?_ROUTER_DATA\s*=\s*`).FindStringIndex(raw)
	if idx == nil {
		return nil
	}
	var data map[string]any
	dec := json.NewDecoder(strings.NewReader(raw[idx[1]:]))
	dec.UseNumber()
	if err := dec.Decode(&data); err != nil {
		return nil
	}
	return data
}

func RouterLoaderMap(data map[string]any, names ...string) map[string]any {
	loader, _ := data["loaderData"].(map[string]any)
	for _, name := range names {
		if page, _ := loader[name].(map[string]any); len(page) > 0 {
			return page
		}
	}
	for key, value := range loader {
		for _, name := range names {
			if strings.TrimSuffix(name, "$") != "" && strings.HasPrefix(key, strings.TrimSuffix(name, "$")) {
				if page, _ := value.(map[string]any); len(page) > 0 {
					return page
				}
			}
		}
	}
	return nil
}

func Heat(row map[string]any) string {
	hot := nestedMap(row, "hot_score_data")
	if score := firstNonEmpty(mapString(hot, "score"), mapString(row, "hot_score")); score != "" {
		value, err := strconv.ParseFloat(score, 64)
		if err == nil && value >= 0 && !math.IsInf(value, 0) && !math.IsNaN(value) {
			return score
		}
	}
	return mapString(hot, "text")
}

func OnlineDate(row map[string]any, now time.Time) string {
	if date := timestampDate(mapString(row, "first_visible_time")); date != "" {
		return date
	}
	for _, label := range subtitleLabels(row) {
		day := now.In(ChinaTime)
		switch label {
		case "今日上新":
			return day.Format("2006-01-02")
		case "昨日上新":
			return day.AddDate(0, 0, -1).Format("2006-01-02")
		default:
			if strings.HasSuffix(label, "上新") {
				date := normalizeDate(label)
				if _, err := time.Parse("2006-01-02", date); err == nil {
					return date
				}
			}
		}
	}
	return ""
}

// subtitleLabels 取出副标题文案（「今日上新」「红果热度值4203万」这类）。
//
// **两种形状都认**：App 详情给的是 `series_sub_title_list`（纯字符串数组），网页给的是
// `sub_title_list`（对象数组，文案在 `content` 里）。此前只读后者，于是 App 路径上
// OnlineDate 永远走不到这一段。
func subtitleLabels(row map[string]any) []string {
	var out []string
	for _, key := range []string{"series_sub_title_list", "sub_title_list"} {
		for _, value := range anyList(row[key]) {
			if label := mapString(nestedMap(value), "content"); label != "" {
				out = append(out, label)
				continue
			}
			if text, ok := value.(string); ok && strings.TrimSpace(text) != "" {
				out = append(out, strings.TrimSpace(text))
			}
		}
	}
	return out
}

// DramaFromAny 把 App / 网页 / 搜索 / 推荐返回的任意一行映射为 Drama。
func DramaFromAny(v any, category string) Drama {
	m, ok := v.(map[string]any)
	if !ok {
		return Drama{}
	}
	vd, _ := m["video_data"].(map[string]any)
	if len(vd) == 0 {
		vd = m
	}
	sourceID := firstNonEmpty(mapString(vd, "series_id_str", "series_id"), mapString(m, "series_id_str", "series_id"), mapString(vd, "keyword"), mapString(m, "keyword"))
	if !NumericID.MatchString(sourceID) {
		return Drama{}
	}
	title := firstNonEmpty(mapString(vd, "series_title", "series_name", "title"), mapString(m, "series_name", "name"), sourceID)
	cover := firstNonEmpty(mapString(vd, "series_cover", "cover"), mapString(m, "series_cover"))
	intro := firstNonEmpty(mapString(vd, "series_intro", "video_desc"), mapString(m, "series_intro"))
	count := firstNonEmpty(mapString(vd, "episode_cnt"), mapString(m, "episode_cnt"))
	remark := firstNonEmpty(mapString(vd, "episode_right_text"), mapString(m, "episode_right_text"))
	releaseStatus := releaseStatusFromRemark(remark)
	if mapString(vd, "series_status") == "1" {
		releaseStatus = "finished"
	} else if mapString(vd, "series_status") == "0" {
		releaseStatus = "ongoing"
	}
	if remark == "" && count != "" {
		remark = "共" + count + "集"
	}
	tags := mapStringSlice(vd, "tags")
	for _, value := range anyList(vd["category_list"]) {
		item, _ := value.(map[string]any)
		if name := mapString(item, "name"); name != "" && !slices.Contains(tags, name) {
			tags = append(tags, name)
		}
	}
	var categories []struct {
		Name string `json:"name"`
	}
	if json.Unmarshal([]byte(mapString(vd, "category_schema")), &categories) == nil {
		for _, item := range categories {
			if item.Name != "" && !slices.Contains(tags, item.Name) {
				tags = append(tags, item.Name)
			}
		}
	}
	genre := mapString(vd, "category_name", "categoryName", "category")
	if genre == "" && len(tags) > 0 {
		genre = tags[0]
	}
	return Drama{
		ID: DramaID(sourceID), Source: Source, SourceID: sourceID, Title: title, Name: title,
		Desc: intro, Intro: intro, Cover: cover, CoverURL: cover,
		CategoryName: firstNonEmpty(genre, category), ChannelName: "红果", Remark: remark,
		TotalEpisode: count, EpisodeCount: count, Tags: tags, ReleaseStatus: releaseStatus,
		Score: mapString(vd, "score"), Views: mapString(vd, "series_play_cnt", "play_cnt"),
		Heat: Heat(vd), OnlineDate: OnlineDate(vd, time.Now()),
	}
}
