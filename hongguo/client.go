package hongguo

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"
)

type Client struct {
	HTTP      *http.Client
	AppBase   string
	WebBase   string
	Retries   int
	DeviceID  string
	InstallID string
	mu        sync.Mutex
}

func NewClient(httpClient *http.Client) *Client {
	if httpClient == nil {
		httpClient = &http.Client{Timeout: 25 * time.Second}
	}
	return &Client{
		HTTP:      httpClient,
		AppBase:   AppBaseURL,
		WebBase:   WebBaseURL,
		Retries:   3,
		DeviceID:  NewDeviceID(),
		InstallID: NewDeviceID(),
	}
}

func (c *Client) retries() int {
	n := c.Retries
	if n < 1 {
		return 1
	}
	if n > 3 {
		return 3
	}
	return n
}

func (c *Client) webBase() string {
	if strings.TrimSpace(c.WebBase) == "" {
		return WebBaseURL
	}
	return strings.TrimRight(c.WebBase, "/")
}

func (c *Client) appBase() string {
	if strings.TrimSpace(c.AppBase) == "" {
		return AppBaseURL
	}
	return strings.TrimRight(c.AppBase, "/")
}

func (c *Client) AppRequest(ctx context.Context, method, path string, extra url.Values, payload any) (map[string]any, error) {
	return c.appRequest(ctx, method, path, extra, payload, false)
}

func (c *Client) CommentRequest(ctx context.Context, method, path string, extra url.Values, payload any) (map[string]any, error) {
	return c.appRequest(ctx, method, path, extra, payload, true)
}

func (c *Client) appRequest(ctx context.Context, method, path string, extra url.Values, payload any, comment bool) (map[string]any, error) {
	c.mu.Lock()
	base, deviceID, installID := c.appBase(), c.DeviceID, c.InstallID
	c.mu.Unlock()
	query := url.Values{
		"aid": {AppAID}, "app_name": {AppName}, "version_code": {AppVersionCode}, "version_name": {AppVersionName},
		"manifest_version_code": {AppVersionCode}, "update_version_code": {AppVersionCode}, "channel": {"update_64"},
		"device_platform": {"android"}, "os": {"android"}, "ssmix": {"a"}, "device_type": {"25053RT47C"},
		"device_brand": {"Redmi"}, "language": {"zh"}, "os_api": {"36"}, "os_version": {"16"},
		"resolution": {"1280*2772"}, "dpi": {"520"}, "ac": {"wifi"}, "device_id": {deviceID}, "iid": {installID},
	}
	for key, values := range extra {
		query[key] = append([]string(nil), values...)
	}
	var body []byte
	var err error
	if payload != nil {
		body, err = json.Marshal(payload)
		if err != nil {
			return nil, err
		}
	}
	var lastErr error
	attempts := c.retries()
	for attempt := 0; attempt < attempts; attempt++ {
		if attempt > 0 {
			select {
			case <-time.After(time.Duration(attempt) * time.Second):
			case <-ctx.Done():
				return nil, ctx.Err()
			}
		}
		request, err := http.NewRequestWithContext(ctx, method, strings.TrimRight(base, "/")+path, bytes.NewReader(body))
		if err != nil {
			return nil, err
		}
		request.Header.Set("User-Agent", AppUserAgent)
		request.Header.Set("Accept", "application/json")
		request.Header.Set("X-XS-From-Web", "0")
		request.Header.Set("Sdk-Version", "2")
		var commentNonce CommentNonce
		if comment {
			commentNonce, err = NewCommentNonce()
			if err != nil {
				return nil, errors.New("无法准备红果文字请求")
			}
			request.Header.Set("Comment-Source", "601")
			request.Header.Set("Server-Channel", "1000")
		}
		if payload != nil {
			request.Header.Set("Content-Type", "application/json; charset=utf-8")
		}
		now := time.Now()
		query.Set("_rticket", strconv.FormatInt(now.UnixMilli(), 10))
		request.URL.RawQuery = query.Encode()
		if comment {
			SignCommentRequest(request, commentNonce, now)
		} else {
			SignRequest(request, body, now)
		}
		response, err := c.HTTP.Do(request)
		if err != nil {
			lastErr = err
			if ctx.Err() != nil {
				return nil, err
			}
			continue
		}
		content, readErr := io.ReadAll(io.LimitReader(response.Body, MaxBodyBytes+1))
		response.Body.Close()
		if readErr != nil {
			lastErr = readErr
			continue
		}
		if response.StatusCode != http.StatusOK {
			lastErr = fmt.Errorf("红果 App 接口 HTTP %d", response.StatusCode)
			if response.StatusCode >= 400 && response.StatusCode < 500 {
				return nil, lastErr
			}
			continue
		}
		if len(content) == 0 || len(content) > MaxBodyBytes {
			return nil, errors.New("红果 App 接口未返回有效数据")
		}
		var result map[string]any
		decoder := json.NewDecoder(bytes.NewReader(content))
		decoder.UseNumber()
		if err := decoder.Decode(&result); err != nil || result == nil {
			return nil, errors.New("红果 App 接口返回格式异常")
		}
		code := firstNonEmpty(mapString(result, "code", "Code", "status_code"), mapString(nestedMap(result, "BaseResp"), "StatusCode"))
		if code != "" && code != "0" {
			return nil, fmt.Errorf("红果 App 接口暂不可用（%s）", truncate(code, 20))
		}
		return result, nil
	}
	return nil, lastErr
}

func (c *Client) FetchText(ctx context.Context, rawURL, referer string) (string, error) {
	if referer == "" {
		referer = rawURL
	}
	var lastErr error
	attempts := c.retries()
	for attempt := 1; attempt <= attempts; attempt++ {
		if attempt > 1 {
			select {
			case <-time.After(time.Duration(attempt) * time.Second):
			case <-ctx.Done():
				return "", ctx.Err()
			}
		}
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
		if err != nil {
			return "", err
		}
		req.Header.Set("User-Agent", WebUserAgent)
		req.Header.Set("Referer", referer)
		req.Header.Set("Accept-Language", "zh-CN,zh;q=0.9")
		resp, err := c.HTTP.Do(req)
		if err != nil {
			lastErr = err
			continue
		}
		body, readErr := io.ReadAll(io.LimitReader(resp.Body, MaxBodyBytes+1))
		resp.Body.Close()
		if readErr != nil {
			lastErr = readErr
			continue
		}
		if len(body) > MaxBodyBytes {
			lastErr = fmt.Errorf("response exceeds %d bytes", MaxBodyBytes)
			continue
		}
		if resp.StatusCode < 200 || resp.StatusCode >= 300 {
			lastErr = fmt.Errorf("%s HTTP %d", req.URL.Hostname(), resp.StatusCode)
			if reason := catalogBlockReason(resp.StatusCode, resp.Header, body); reason != "" {
				lastErr = fmt.Errorf("%s HTTP %d：%s", req.URL.Hostname(), resp.StatusCode, reason)
			}
			if resp.StatusCode >= 400 && resp.StatusCode < 500 && resp.StatusCode != 408 {
				return "", lastErr
			}
			continue
		}
		if reason := catalogBlockReason(resp.StatusCode, resp.Header, body); reason != "" {
			return "", fmt.Errorf("%s HTTP %d：%s", req.URL.Hostname(), resp.StatusCode, reason)
		}
		return string(body), nil
	}
	return "", lastErr
}
