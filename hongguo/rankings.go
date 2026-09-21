package hongguo

import (
	"context"
	"encoding/json"
	"errors"
	"strconv"
	"strings"
)

type rankingContent struct {
	Success bool `json:"isSuccess"`
	Rows    []struct {
		ID          string   `json:"id"`
		SeriesID    string   `json:"seriesId"`
		Rank        int      `json:"rank"`
		Title       string   `json:"title"`
		Heat        string   `json:"heatText"`
		Score       string   `json:"scoreText"`
		Tags        []string `json:"tags"`
		Description string   `json:"description"`
		EpisodeIDs  []string `json:"episodeVids"`
		Cover       any      `json:"cover"`
	} `json:"rankList"`
	Pagination struct {
		Page       int `json:"pageNum"`
		TotalPages int `json:"totalPages"`
	} `json:"pagination"`
}

func parseMergeLoader(body, loaderKey string) (rankingContent, bool) {
	for _, tag := range rankingScriptTags.FindAllString(body, -1) {
		if extractAttr(tag, "data-fn-name") != "mergeLoaderData" || extractAttr(tag, "data-script-src") != "modern-run-window-fn" {
			continue
		}
		var args []json.RawMessage
		if json.Unmarshal([]byte(extractAttr(tag, "data-fn-args")), &args) != nil || len(args) != 2 {
			continue
		}
		var route string
		if json.Unmarshal(args[0], &route) != nil || route != loaderKey {
			continue
		}
		var fields []struct {
			Key  string            `json:"key"`
			Name string            `json:"routerDataFnName"`
			Args []json.RawMessage `json:"routerDataFnArgs"`
		}
		if json.Unmarshal(args[1], &fields) != nil {
			continue
		}
		for _, field := range fields {
			if field.Key != "content" || field.Name != "p" {
				continue
			}
			var content rankingContent
			var raw string
			if len(field.Args) != 1 || json.Unmarshal(field.Args[0], &raw) != nil || json.Unmarshal([]byte(raw), &content) != nil {
				return rankingContent{}, true
			}
			return content, true
		}
	}
	return rankingContent{}, false
}

func ParseRanking(body string, board RankingBoard, page int) (RankingPage, error) {
	failure := errors.New("红果榜单格式或分页已变化，请稍后重试")
	loaderKey := "rank_" + board.Path + "/page"
	loader := nestedMap(ParseRouterData(body), "loaderData", loaderKey)
	if mapString(loader, "rankKey") != board.UpstreamKey || mapString(loader, "pageNum") != strconv.Itoa(page) {
		return RankingPage{}, failure
	}
	var content rankingContent
	if inline := nestedMap(loader, "content"); len(inline) > 0 {
		raw, err := json.Marshal(inline)
		if err != nil || json.Unmarshal(raw, &content) != nil {
			return RankingPage{}, failure
		}
	} else if merged, found := parseMergeLoader(body, loaderKey); found {
		content = merged
	} else {
		for _, tag := range rankingScriptTags.FindAllString(body, -1) {
			if extractAttr(tag, "data-fn-name") != "r" || extractAttr(tag, "data-script-src") != "modern-run-router-data-fn" {
				continue
			}
			var args []json.RawMessage
			if json.Unmarshal([]byte(extractAttr(tag, "data-fn-args")), &args) != nil || len(args) != 3 {
				continue
			}
			var route, field string
			if json.Unmarshal(args[0], &route) != nil || json.Unmarshal(args[1], &field) != nil || route != loaderKey || field != "content" {
				continue
			}
			if json.Unmarshal(args[2], &content) != nil {
				return RankingPage{}, failure
			}
			break
		}
	}
	if !content.Success || content.Rows == nil || content.Pagination.Page != page || content.Pagination.TotalPages < page || content.Pagination.TotalPages > 500 {
		return RankingPage{}, failure
	}
	result := RankingPage{
		BoardID: board.ID, Page: page, Items: make([]RankingItem, 0, len(content.Rows)),
		TotalPages: content.Pagination.TotalPages, HasMore: page < content.Pagination.TotalPages,
		UpdatedText: mapString(loader, "updatedText"),
	}
	seen := map[string]bool{}
	previous := (page - 1) * 20
	for _, row := range content.Rows {
		id := firstNonEmpty(row.SeriesID, row.ID)
		if !NumericID.MatchString(id) || row.ID != "" && row.SeriesID != "" && row.ID != row.SeriesID || strings.TrimSpace(row.Title) == "" || row.Rank <= previous || row.Rank > page*20 || seen[id] {
			return RankingPage{}, failure
		}
		seen[id], previous = true, row.Rank
		drama := Drama{
			ID: DramaID(id), Source: Source, SourceID: id, Title: row.Title, Name: row.Title,
			Desc: row.Description, Intro: row.Description, Tags: row.Tags, Heat: row.Heat,
			Score: strings.TrimPrefix(row.Score, "评分"), ChannelName: "红果",
		}
		if cover := CoverAddress(coverPathFromAny(row.Cover)); cover != "" {
			drama.Cover, drama.CoverURL = cover, cover
		}
		if len(row.Tags) > 0 {
			drama.CategoryName = row.Tags[0]
		}
		if len(row.EpisodeIDs) > 0 {
			drama.TotalEpisode = strconv.Itoa(len(row.EpisodeIDs))
		}
		result.Items = append(result.Items, RankingItem{Rank: row.Rank, Drama: drama, Metric: row.Heat})
	}
	if len(result.Items) == 0 && result.HasMore {
		return RankingPage{}, failure
	}
	return result, nil
}

func FindRankingBoard(id string) (RankingBoard, bool) {
	for _, board := range RankingBoards {
		if board.ID == id {
			return board, true
		}
	}
	return RankingBoard{}, false
}

func (c *Client) FetchRanking(ctx context.Context, board RankingBoard, page int) (RankingPage, error) {
	pageURL := c.webBase() + "/rank/" + board.Path + "?page=" + strconv.Itoa(page)
	body, err := c.FetchText(ctx, pageURL, c.webBase()+"/")
	if err != nil {
		return RankingPage{}, err
	}
	return ParseRanking(body, board, page)
}
