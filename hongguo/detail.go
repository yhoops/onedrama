package hongguo

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
)

func ParseAppDetail(result map[string]any, seriesID string) (Detail, error) {
	detail := nestedMap(result, "data", "video_data")
	returnedID := mapString(detail, "series_id_str", "series_id")
	if returnedID != seriesID {
		return Detail{}, errors.New("红果 App 未返回所请求的剧集")
	}
	entry := Detail{Drama: DramaFromAny(detail, "短剧")}
	seen := map[string]bool{}
	episodes := map[int]bool{}
	for _, row := range anyList(detail["video_list"]) {
		video, _ := row.(map[string]any)
		videoID := mapString(video, "vid")
		index, err := strconv.Atoi(mapString(video, "vid_index"))
		if err != nil || index < 1 || !NumericID.MatchString(videoID) {
			return entry, errors.New("红果 App 分集编号或视频 ID 无效")
		}
		if identifier := mapString(video, "series_id"); identifier != "" && identifier != seriesID {
			return entry, errors.New("红果 App 返回了其他剧集的分集")
		}
		if seen[videoID] || episodes[index] {
			return entry, errors.New("红果 App 返回了重复分集")
		}
		seen[videoID], episodes[index] = true, true
		entry.Chapters = append(entry.Chapters, Chapter{
			ID: ChapterID(seriesID, videoID), Source: Source,
			Title: fmt.Sprintf("第%d集", index), VideoURL: MediaPlaceholder(videoID), CurrentEpisode: rawEpisode(index),
		})
	}
	sort.Slice(entry.Chapters, func(left, right int) bool {
		leftIndex, _ := strconv.Atoi(entry.Chapters[left].EpisodeString(left + 1))
		rightIndex, _ := strconv.Atoi(entry.Chapters[right].EpisodeString(right + 1))
		return leftIndex < rightIndex
	})
	total, _ := strconv.Atoi(mapString(detail, "episode_cnt"))
	if len(entry.Chapters) == 0 || total > len(entry.Chapters) {
		return entry, errors.New("红果 App 未返回完整分集，已尝试其他详情入口")
	}
	for index, chapter := range entry.Chapters {
		if chapter.EpisodeString(index+1) != strconv.Itoa(index+1) {
			return entry, errors.New("红果 App 分集列表不连续")
		}
	}
	return entry, nil
}

func ParseWebDetail(body, seriesID string) (Detail, error) {
	page := RouterLoaderMap(ParseRouterData(body), "detail_page", "detail_")
	detail, _ := page["seriesDetail"].(map[string]any)
	if len(detail) == 0 {
		return Detail{}, fmt.Errorf("hongguo detail is empty")
	}
	title := firstNonEmpty(mapString(detail, "series_name", "series_title", "name"), seriesID)
	vids := anyList(detail["vid_list"])
	chapters := make([]Chapter, 0, len(vids))
	for i, v := range vids {
		vid := strings.TrimSpace(fmt.Sprint(v))
		if vid == "" || vid == "<nil>" {
			continue
		}
		idx := i + 1
		chapters = append(chapters, Chapter{
			ID: ChapterID(seriesID, vid), Source: Source,
			Title: fmt.Sprintf("第%d集", idx), VideoURL: MediaPlaceholder(vid), CurrentEpisode: rawEpisode(idx),
		})
	}
	if len(chapters) == 0 {
		return Detail{}, errors.New("红果详情没有返回剧集 ID")
	}
	drama := DramaFromAny(detail, "短剧")
	if drama.Title == "" {
		drama.Title, drama.Name = title, title
	}
	if drama.SourceID == "" {
		drama.ID, drama.Source, drama.SourceID = DramaID(seriesID), Source, seriesID
	}
	return Detail{Drama: drama, Chapters: chapters}, nil
}

// SocialInfo 是网页详情里的社交数据。
//
// **App 详情接口没有这些字段。** App 的 `/novel/player/video_detail/v1/` 返回 39 个字段，
// 键名含 score/rating/heat/hot 的只有一个 `hot_score`——评分只能从网页拿。
type SocialInfo struct {
	// Rating 是评分，如 9.2；HasRating 为 false 表示这部剧本就没评分
	// （实测 5 部里 2 部没有），不是解析失败。
	Rating    float64
	HasRating bool
	// RatingCount 是评分人数，如 "33371"（上游给的是字符串）。
	RatingCount string
}

// ParseWebSocialInfo 从网页详情 HTML 里取社交数据——目前只有评分。
//
// 注意 `seriesSocialInfo` 与 `seriesDetail` 是**同级**字段，不在它里面；写进
// `seriesDetail` 里查会永远查不到。
func ParseWebSocialInfo(body string) SocialInfo {
	page := RouterLoaderMap(ParseRouterData(body), "detail_page", "detail_")
	social := nestedMap(page, "seriesSocialInfo")
	if len(social) == 0 {
		return SocialInfo{}
	}
	info := SocialInfo{RatingCount: mapString(social, "rating_count")}
	// ParseRouterData 走 UseNumber，所以这里拿到的是 json.Number，不是 float64；
	// 用 fmt.Sprint 一并兜住两种类型。
	if rating, err := strconv.ParseFloat(fmt.Sprint(social["rating"]), 64); err == nil && rating > 0 {
		info.Rating, info.HasRating = rating, true
	}
	return info
}

// FetchWebSocialInfo 取网页详情的社交数据（评分）。
//
// **取不到就当没有**，不返回 error：评分是锦上添花，不该因为它拖垮整个详情页。
func (c *Client) FetchWebSocialInfo(ctx context.Context, seriesID string) SocialInfo {
	if !NumericID.MatchString(seriesID) {
		return SocialInfo{}
	}
	body, err := c.FetchText(ctx, c.webBase()+"/detail?series_id="+url.QueryEscape(seriesID), c.webBase()+"/")
	if err != nil {
		return SocialInfo{}
	}
	return ParseWebSocialInfo(body)
}

func (c *Client) FetchDetail(ctx context.Context, seriesID string) (Detail, error) {
	seriesID = strings.TrimPrefix(strings.TrimSpace(seriesID), "hg-series-v1:")
	if !NumericID.MatchString(seriesID) {
		return Detail{}, errors.New("红果剧集 ID 无效")
	}
	result, appErr := c.AppRequest(ctx, http.MethodPost, "/novel/player/video_detail/v1/", nil, map[string]any{"series_id": seriesID})
	if appErr == nil {
		if entry, err := ParseAppDetail(result, seriesID); err == nil {
			return entry, nil
		} else {
			appErr = err
		}
	}
	if ctx.Err() != nil {
		return Detail{}, ctx.Err()
	}
	body, webErr := c.FetchText(ctx, c.webBase()+"/detail?series_id="+url.QueryEscape(seriesID), c.webBase()+"/")
	if webErr == nil {
		return ParseWebDetail(body, seriesID)
	}
	return Detail{}, fmt.Errorf("App 详情失败: %v；网页详情失败: %w", appErr, webErr)
}
