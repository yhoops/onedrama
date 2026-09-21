package hongguo

import (
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"
)

func ParseCatalogPage(result map[string]any, cursor CatalogCursor, category string) ([]Drama, CatalogCursor, error) {
	data := nestedMap(result, "data")
	rows, valid := data["video_data"].([]any)
	if !valid {
		return nil, cursor, errors.New("App 分类数据格式异常")
	}
	items := make([]Drama, 0, len(rows))
	ids := make([]string, 0, len(rows))
	seen := map[string]bool{}
	for _, row := range rows {
		drama := DramaFromAny(row, category)
		if drama.ID != "" {
			items = append(items, drama)
			if !seen[drama.ID] {
				seen[drama.ID] = true
				ids = append(ids, drama.ID)
			}
		}
	}
	if len(rows) > 0 && len(items) == 0 {
		return items, cursor, errors.New("App 分类未返回可识别的剧集")
	}
	next, parseErr := strconv.Atoi(mapString(data, "next_offset"))
	hasMore, paginationOK := data["has_more"].(bool)
	if !paginationOK || hasMore && parseErr != nil {
		return items, cursor, errors.New("App 分页标记无效，已保留上次位置")
	}
	if parseErr != nil {
		next = cursor.Offset + len(rows)
	}
	lastID, signature := "", ""
	if len(items) > 0 {
		lastID = items[len(items)-1].ID
		sort.Strings(ids)
		signature = fmt.Sprintf("%x", sha256.Sum256([]byte(strings.Join(ids, "\n"))))
	}
	if hasMore && (len(items) == 0 || next <= cursor.Offset || next > 1_000_000 || signature == cursor.PageSignature) {
		return items, cursor, errors.New("App 分页未前进，已保留上次位置")
	}
	cursor.Exhausted = !hasMore
	cursor.Initialized = true
	cursor.Offset = next
	cursor.SessionID = mapString(data, "session_id")
	cursor.LastID = lastID
	cursor.PageSignature = signature
	cursor.UpdatedAt = time.Now()
	return items, cursor, nil
}

func (c *Client) FetchCatalogPage(ctx context.Context, genreKey, scene, category string, cursor CatalogCursor) ([]Drama, CatalogCursor, error) {
	if time.Since(cursor.UpdatedAt) > 30*time.Minute {
		cursor.SessionID = ""
	}
	payload := map[string]any{
		"req_scene": scene, "offset": cursor.Offset, "limit": 18,
		"req_type": "only_content", "need_selector_panel": false, "client_req_type": 3,
		"session_id": cursor.SessionID, "filter_ids": "",
		"select_items": map[string]any{
			"genre": []string{genreKey}, "sort": []string{"online_time"}, "gender": []string{},
			"category_dim_theme": []string{}, "category_dim_role": []string{}, "category_dim_epoch": []string{},
			"online_time": []string{}, "creation_status": []string{},
		},
	}
	if cursor.Offset > 0 {
		payload["client_req_type"] = 2
	}
	result, err := c.AppRequest(ctx, http.MethodPost, "/reading/distribution/category/landpage/v/", nil, payload)
	if err != nil {
		return nil, cursor, err
	}
	return ParseCatalogPage(result, cursor, category)
}

func (c *Client) FetchWebCategoryPage(ctx context.Context, route, category string) ([]Drama, int, error) {
	body, err := c.FetchText(ctx, c.webBase()+"/category/"+route, c.webBase()+"/")
	if err != nil {
		return nil, 0, err
	}
	data := ParseRouterData(body)
	page := RouterLoaderMap(data, "category_page", "category_$")
	if len(page) == 0 || page["isSuccess"] == false {
		return nil, 0, errors.New("红果分类数据不可用，可能是页面结构或访问权限变化")
	}
	items := anyList(page["recommendList"])
	out := make([]Drama, 0, len(items))
	for _, item := range items {
		if dr := DramaFromAny(item, category); dr.ID != "" {
			out = append(out, dr)
		}
	}
	pages, _ := strconv.Atoi(mapString(nestedMap(page, "pagination"), "totalPages"))
	return out, pages, nil
}

func (c *Client) FetchRecommendations(ctx context.Context, query RecommendationQuery) (RecommendationPage, error) {
	page := RecommendationPage{Dramas: []Drama{}}
	known := false
	scene, category := "", ""
	for _, genre := range AppGenres {
		if genre.Key == query.Genre {
			known, scene, category = true, genre.Scene, genre.Name
		}
	}
	if !known || query.Offset < 0 || query.Offset > 1_000_000 || len(query.SessionID) > 4096 || strings.ContainsAny(query.SessionID, "\r\n\x00") || len(query.Seen) > 540 {
		return page, errors.New("推荐分类或分页参数无效，请重新获取")
	}
	seen := make(map[string]bool, len(query.Seen))
	filterIDs := make([]string, 0, len(query.Seen))
	for _, id := range query.Seen {
		id = strings.TrimPrefix(id, Source+":")
		if !NumericID.MatchString(id) {
			return page, errors.New("推荐分页含无效剧集 ID")
		}
		if !seen[id] {
			filterIDs = append(filterIDs, id)
			seen[id] = true
		}
	}
	payload := map[string]any{
		"req_scene": scene, "offset": query.Offset, "limit": 18,
		"req_type": "only_content", "need_selector_panel": false, "client_req_type": 3,
		"session_id": query.SessionID, "filter_ids": strings.Join(filterIDs, ","),
		"select_items": map[string]any{
			"genre": []string{query.Genre}, "sort": []string{}, "gender": []string{},
			"category_dim_theme": []string{}, "category_dim_role": []string{}, "category_dim_epoch": []string{},
			"online_time": []string{}, "creation_status": []string{},
		},
	}
	if query.Offset > 0 {
		payload["client_req_type"] = 2
	}
	result, err := c.AppRequest(ctx, http.MethodPost, "/reading/distribution/category/landpage/v/", nil, payload)
	if err != nil {
		return page, err
	}
	data := nestedMap(result, "data")
	rows, valid := data["video_data"].([]any)
	hasMore, paginationOK := data["has_more"].(bool)
	next, parseErr := strconv.Atoi(mapString(data, "next_offset"))
	if !valid || !paginationOK || hasMore && parseErr != nil {
		return page, errors.New("红果推荐数据格式异常，已保留上次位置")
	}
	validRows := 0
	for _, row := range rows {
		drama := DramaFromAny(row, category)
		if drama.ID != "" {
			validRows++
		}
		id := strings.TrimPrefix(drama.ID, Source+":")
		if drama.ID == "" || seen[id] {
			continue
		}
		seen[id] = true
		page.Dramas = append(page.Dramas, drama)
	}
	if len(rows) > 0 && validRows == 0 {
		return RecommendationPage{}, errors.New("红果推荐未返回可识别的剧集")
	}
	if hasMore && (next <= query.Offset || next > 1_000_000 || len(page.Dramas) == 0) {
		return RecommendationPage{}, errors.New("红果推荐分页未前进，可重试或重新获取")
	}
	page.NextOffset, page.HasMore, page.SessionID = next, hasMore, mapString(data, "session_id")
	if len(page.SessionID) > 4096 || strings.ContainsAny(page.SessionID, "\r\n\x00") {
		return RecommendationPage{}, errors.New("红果推荐分页标记无效")
	}
	return page, ctx.Err()
}
