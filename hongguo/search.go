package hongguo

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"golang.org/x/text/unicode/norm"
)

type suggestionRecord struct {
	Name      string         `json:"name"`
	WordType  string         `json:"word_type"`
	Keyword   any            `json:"keyword"`
	VideoData map[string]any `json:"video_data"`
}

func SearchKeyword(keyword string) (string, error) {
	keyword = strings.TrimSpace(keyword)
	if keyword == "" || !utf8.ValidString(keyword) || utf8.RuneCountInString(keyword) > 80 || strings.IndexFunc(keyword, unicode.IsControl) >= 0 {
		return "", errors.New("请输入 1 至 80 个字符的搜索词")
	}
	return keyword, nil
}

func SearchText(text string) string {
	normalized := strings.Map(func(r rune) rune {
		if unicode.IsSpace(r) || unicode.IsPunct(r) {
			return -1
		}
		return unicode.ToLower(r)
	}, norm.NFKC.String(text))
	if normalized == "" {
		return strings.ToLower(strings.TrimSpace(text))
	}
	return normalized
}

func TitleSearchRank(title, query string) int {
	title = SearchText(title)
	switch {
	case title == query:
		return 0
	case strings.HasPrefix(title, query):
		return 1
	case strings.Contains(title, query):
		return 2
	default:
		return 3
	}
}

func ParseSearchPage(body, keyword string) (SearchResult, error) {
	page := RouterLoaderMap(ParseRouterData(body), "search_(keyword)/page", "search_")
	rows, valid := page["searchList"].([]any)
	if page["isSuccess"] != true || !valid || mapString(page, "query") != keyword {
		return SearchResult{}, errors.New("红果搜索未返回有效结果")
	}
	entry := SearchResult{Dramas: make([]Drama, 0, len(rows))}
	seen := make(map[string]bool, len(rows))
	for _, row := range rows {
		if len(nestedMap(row, "video_data")) == 0 {
			continue
		}
		drama := DramaFromAny(row, "短剧")
		if drama.ID != "" && !seen[drama.ID] {
			seen[drama.ID] = true
			entry.Dramas = append(entry.Dramas, drama)
		}
	}
	if len(rows) > 0 && len(entry.Dramas) == 0 {
		return SearchResult{}, errors.New("红果搜索结果中没有可识别的剧集")
	}
	entry.Total, _ = strconv.Atoi(mapString(page, "totalCount"))
	entry.Limited = entry.Total > len(entry.Dramas)
	if entry.Total < len(entry.Dramas) {
		entry.Total = len(entry.Dramas)
	}
	return entry, nil
}

func (c *Client) FetchSuggestionRecords(ctx context.Context, query string, count int) ([]suggestionRecord, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	params := url.Values{"app_id": {AppAID}, "query": {query}, "count": {strconv.Itoa(count)}}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, c.webBase()+"/incent_resource/suggestion?"+params.Encode(), nil)
	if err != nil {
		return nil, err
	}
	request.Header.Set("User-Agent", WebUserAgent)
	request.Header.Set("Referer", c.webBase()+"/")
	request.Header.Set("Accept", "application/json")
	request.Header.Set("Accept-Language", "zh-CN,zh;q=0.9")
	response, err := c.HTTP.Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	const bodyLimit = 256 * 1024
	body, err := io.ReadAll(io.LimitReader(response.Body, bodyLimit+1))
	if err != nil {
		return nil, err
	}
	if len(body) > bodyLimit {
		return nil, errors.New("红果搜索联想响应过大")
	}
	if response.StatusCode != http.StatusOK || catalogBlockReason(response.StatusCode, response.Header, body) != "" {
		reason := catalogBlockReason(response.StatusCode, response.Header, body)
		if reason != "" {
			return nil, fmtHTTP(request.URL.Hostname(), response.StatusCode, reason)
		}
		return nil, fmtHTTP(request.URL.Hostname(), response.StatusCode, "")
	}
	var result struct {
		Items []suggestionRecord `json:"suggest_list"`
	}
	decoder := json.NewDecoder(strings.NewReader(string(body)))
	decoder.UseNumber()
	if err := decoder.Decode(&result); err != nil || result.Items == nil {
		return nil, errors.New("红果搜索联想未返回有效数据")
	}
	if decoder.Decode(new(any)) != io.EOF {
		return nil, errors.New("红果搜索联想未返回有效数据")
	}
	return result.Items, nil
}

func fmtHTTP(host string, status int, reason string) error {
	if reason != "" {
		return errors.New(host + " HTTP " + strconv.Itoa(status) + "：" + reason)
	}
	return errors.New(host + " HTTP " + strconv.Itoa(status))
}

func (c *Client) SearchSuggestions(ctx context.Context, query string) ([]Suggestion, error) {
	query, err := SearchKeyword(query)
	if err != nil {
		return nil, err
	}
	records, err := c.FetchSuggestionRecords(ctx, query, 10)
	if err != nil {
		return nil, err
	}
	items := make([]Suggestion, 0, 10)
	seen := make(map[string]bool)
	for _, item := range records {
		name, err := SearchKeyword(item.Name)
		key := strings.ToLower(name)
		if err != nil || seen[key] {
			continue
		}
		seen[key] = true
		kind := item.WordType
		switch kind {
		case "short_play_name", "short_play_category", "common_query", "actor_name", "short_play_actor":
		default:
			kind = ""
		}
		items = append(items, Suggestion{Name: name, Type: kind})
		if len(items) == 10 {
			break
		}
	}
	return items, nil
}

func (c *Client) Search(ctx context.Context, keyword string) (SearchResult, error) {
	keyword, err := SearchKeyword(keyword)
	if err != nil {
		return SearchResult{}, err
	}
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	records, namesErr := c.FetchSuggestionRecords(ctx, keyword, 50)
	var names []Drama
	if namesErr == nil {
		for _, record := range records {
			if record.WordType != "short_play_name" || !NumericID.MatchString(mapString(record.VideoData, "series_id_str", "series_id")) {
				continue
			}
			drama := DramaFromAny(map[string]any{"video_data": record.VideoData, "name": record.Name, "keyword": record.Keyword}, "短剧")
			if drama.ID != "" && drama.DisplayTitle() != drama.SourceID {
				names = append(names, drama)
			}
		}
	}
	if err := ctx.Err(); err != nil {
		return SearchResult{}, err
	}
	pageCtx, pageCancel := context.WithTimeout(ctx, 12*time.Second)
	defer pageCancel()
	body, pageErr := c.FetchText(pageCtx, c.webBase()+"/search/"+url.PathEscape(keyword), c.webBase()+"/")
	var page SearchResult
	if pageErr == nil {
		page, pageErr = ParseSearchPage(body, keyword)
	}
	if err := ctx.Err(); err != nil {
		return SearchResult{}, err
	}
	if pageErr != nil && namesErr != nil || len(page.Dramas)+len(names) == 0 && (pageErr != nil || namesErr != nil) {
		return SearchResult{}, errors.Join(pageErr, namesErr)
	}
	entry := SearchResult{Dramas: make([]Drama, 0, len(page.Dramas)+len(names)), Total: page.Total, Limited: page.Limited}
	positions := make(map[string]int)
	for _, batch := range [][]Drama{page.Dramas, names} {
		for _, drama := range batch {
			if index, found := positions[drama.ID]; found {
				entry.Dramas[index] = mergeDrama(entry.Dramas[index], drama)
			} else {
				positions[drama.ID] = len(entry.Dramas)
				entry.Dramas = append(entry.Dramas, drama)
			}
		}
	}
	query := SearchText(keyword)
	sort.SliceStable(entry.Dramas, func(left, right int) bool {
		return TitleSearchRank(entry.Dramas[left].DisplayTitle(), query) < TitleSearchRank(entry.Dramas[right].DisplayTitle(), query)
	})
	if pageErr != nil {
		entry.Warning = "红果综合搜索暂不可用，已保留名称匹配结果，可重试"
	} else if namesErr != nil {
		entry.Warning = "红果名称检索暂不可用，结果可能缺少部分剧集，可重试"
	}
	entry.Limited = entry.Limited || pageErr != nil || namesErr != nil
	if entry.Total < len(entry.Dramas) {
		entry.Total = len(entry.Dramas)
	}
	return entry, nil
}
