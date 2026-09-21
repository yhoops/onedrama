package hongguo

import (
	"encoding/hex"
	"net/http/httptest"
	"testing"
	"time"
)

func TestCommentSignatureVector(t *testing.T) {
	request := httptest.NewRequest("POST", "https://api5-normal-sinfonlineb.fqnovel.com/novel/commentapi/comment/list/700002/v1/?aid=8662&device_id=700003", nil)
	nonce := CommentNonce{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11}
	SignCommentRequest(request, nonce, time.Unix(1773662280, 0))
	expected := map[string]string{
		"X-Argus":   "PMxPj+JImxTKEfQuAsVmWpqWbk6ptNvvFsIJbNFMxOQxhVihWhCZbh3JphV/tvUG7ABmRtDIxS2tVq7M9EF+LUTvnjlIF4oXQZYJsihMmASmjnLwRmXqU6nLasLwya7gsESxF+40XOiFB33K2lzJU0NY2CgrA2G58uGjG0TG0GtLwpE3RXTEMO0GUwaKqaCFx4yb01vcH+N+obpbQAuycKGF",
		"X-Gorgon":  "840440e20000e5534737ff447dece3898d8546b77f54303100d8",
		"X-Khronos": "1773662280",
		"X-Ladon":   "AwQFBllQi0qfAHVP9XxZtrYsmLNnfrwAzFAlv0Cqi9J16ndL",
	}
	for key, want := range expected {
		if got := request.Header.Get(key); got != want {
			t.Errorf("%s: got %q, want %q", key, got, want)
		}
	}
	if request.Header.Get("X-SS-STUB") != "" {
		t.Fatal("comment protocol requires an empty body stub")
	}
}

func TestSM3KnownVector(t *testing.T) {
	hash := SM3([]byte("abc"))
	if got := hex.EncodeToString(hash[:]); got != "66c7f0f462eeedd9d1f2d46bdc10e4e24167c4875cf2f7a2297da02b8f4ba8e0" {
		t.Fatal(got)
	}
}

func TestDramaFromAny(t *testing.T) {
	drama := DramaFromAny(map[string]any{
		"series_id": "12345", "series_title": "测试剧", "series_cover": "https://example.com/a.jpg",
		"episode_cnt": "20", "series_status": "1", "hot_score": "99",
	}, "真人剧")
	if drama.ID != "hongguo:12345" || drama.Title != "测试剧" || drama.ReleaseStatus != "finished" {
		t.Fatalf("%+v", drama)
	}
}

func TestSplitDramaID(t *testing.T) {
	id, ok := SplitDramaID("hongguo:123")
	if !ok || id != "123" {
		t.Fatal(id, ok)
	}
	if _, ok := SplitDramaID("other:123"); ok {
		t.Fatal("should reject other source")
	}
}
