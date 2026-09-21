package hongguo

import (
	"crypto/aes"
	"crypto/cipher"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"math/bits"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"testing"
	"time"
)

// 本文件是 Dart 侧契约测试的向量源。Go 包是协议真相，Dart 侧读同一份 JSON
// 断言输出相等（见 docs/adr/0003）。
//
// 重新生成：
//
//	EMIT_VECTORS=1 go test -run TestEmitVectors .
//
// 生成的文件：hongguo/testdata/vectors.json，由 packages/hongguo_dart 的测试读取。

type sm3Case struct {
	Input string `json:"input"`
	Hex   string `json:"hex"`
}

type splitDramaIDCase struct {
	Identifier string `json:"identifier"`
	SourceID   string `json:"sourceId"`
	OK         bool   `json:"ok"`
}

type signRequestCase struct {
	Name     string            `json:"name"`
	RawQuery string            `json:"rawQuery"`
	Body     string            `json:"body"`
	HasBody  bool              `json:"hasBody"`
	Unix     int64             `json:"unix"`
	Headers  map[string]string `json:"headers"`
}

type contentKeyCase struct {
	Name  string `json:"name"`
	Spade string `json:"spade"`
	Key   string `json:"key"`   // 成功的十六进制密钥
	Error string `json:"error"` // 失败时的错误文本
}

type playbackCase struct {
	Name   string `json:"name"`
	Body   string `json:"body"`
	Plain  string `json:"plain"`  // 期望的明文
	IsV2   bool   `json:"isV2"`
	Error  string `json:"error"`
}

type vectors struct {
	SM3                    []sm3Case          `json:"sm3"`
	SplitDramaID           []splitDramaIDCase `json:"splitDramaId"`
	SignRequest            []signRequestCase  `json:"signRequest"`
	ContentKey             []contentKeyCase   `json:"contentKey"`
	DecodePlaybackResponse []playbackCase     `json:"decodePlaybackResponse"`
}

func TestEmitVectors(t *testing.T) {
	if os.Getenv("EMIT_VECTORS") == "" {
		t.Skip("set EMIT_VECTORS=1 to regenerate testdata/vectors.json")
	}

	out := vectors{
		SM3: []sm3Case{
			{Input: "abc", Hex: hex.EncodeToString(func() []byte { h := SM3([]byte("abc")); return h[:] }())},
			{Input: "", Hex: hex.EncodeToString(func() []byte { h := SM3(nil); return h[:] }())},
			{Input: "abcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcd", Hex: hex.EncodeToString(func() []byte {
				h := SM3([]byte("abcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcd"))
				return h[:]
			}())},
		},
		SplitDramaID: []splitDramaIDCase{
			{Identifier: "hongguo:123", SourceID: "123", OK: true},
			{Identifier: "other:123", OK: false},
			{Identifier: "  hongguo:456  ", SourceID: "456", OK: true},
			{Identifier: "789", SourceID: "789", OK: true},
			{Identifier: "hongguoduanju.com:321", SourceID: "321", OK: true},
			{Identifier: "hongguo:abc", OK: false},
			{Identifier: "hongguo:", OK: false},
			{Identifier: "hongguo:123456789012345678901234567890123", OK: false},
			{Identifier: "hongguo:hg-series-v1:555", SourceID: "555", OK: true},
		},
	}

	// SignRequest：带 body 与不带 body 各一组，覆盖 X-SS-STUB 的有无。
	for _, c := range []struct {
		name     string
		method   string
		url      string
		body     string
		hasBody  bool
		unix     int64
	}{
		{
			name: "with-body", method: "POST",
			url:  "https://api5-normal-sinfonlineb.fqnovel.com/novel/player/video_model/v1/?aid=8662&device_id=700003&_rticket=1773662280000",
			body: `{"video_id":"700002","content_type":1}`, hasBody: true, unix: 1773662280,
		},
		{
			name: "without-body", method: "GET",
			url:  "https://hongguoduanju.com/incent_resource/suggestion?app_id=8662&query=%E6%80%BB%E8%A3%81&count=10",
			hasBody: false, unix: 1773662280,
		},
	} {
		request := httptest.NewRequest(c.method, c.url, nil)
		var body []byte
		if c.hasBody {
			body = []byte(c.body)
		}
		SignRequest(request, body, time.Unix(c.unix, 0))
		headers := map[string]string{
			"X-Khronos":        request.Header.Get("X-Khronos"),
			"X-Gorgon":         request.Header.Get("X-Gorgon"),
			"X-SS-Req-Ticket":  request.Header.Get("X-SS-Req-Ticket"),
		}
		if stub := request.Header.Get("X-SS-STUB"); stub != "" {
			headers["X-SS-STUB"] = stub
		}
		out.SignRequest = append(out.SignRequest, signRequestCase{
			Name: c.name, RawQuery: request.URL.RawQuery, Body: c.body,
			HasBody: c.hasBody, Unix: c.unix, Headers: headers,
		})
	}

	// ContentKey：真 spade_a 要联网才有，这里用反解合成一份等价输入。
	key, _ := hex.DecodeString("00112233445566778899aabbccddeeff")
	out.ContentKey = append(out.ContentKey, contentKeyCase{
		Name: "padding-4", Spade: synthSpade(key, 4, "okok"), Key: hex.EncodeToString(key),
	})
	key2, _ := hex.DecodeString("ffeeddccbbaa99887766554433221100")
	out.ContentKey = append(out.ContentKey, contentKeyCase{
		Name: "padding-20", Spade: synthSpade(key2, 20, "zz"), Key: hex.EncodeToString(key2),
	})
	out.ContentKey = append(out.ContentKey, contentKeyCase{
		Name: "reject-app-v2", Spade: synthSpade(key, 4, "app_v2"), Error: "红果媒体密钥版本暂不支持",
	})

	// DecodePlaybackResponse：同样反解合成。
	plain := `{"code":0,"data":{"url":"https://example.com/a.mp4"}}`
	out.DecodePlaybackResponse = append(out.DecodePlaybackResponse, playbackCase{
		Name: "plain-json", Body: "   " + plain + "  ", Plain: plain, IsV2: false,
	})
	out.DecodePlaybackResponse = append(out.DecodePlaybackResponse, playbackCase{
		Name: "v2-cbc", Body: synthBackupResponse([]byte(plain)), Plain: plain, IsV2: true,
	})

	target := filepath.Join("testdata", "vectors.json")
	if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
		t.Fatal(err)
	}
	encoded, err := json.MarshalIndent(out, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(target, append(encoded, '\n'), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Logf("wrote %s", target)
}

// synthSpade 构造一份 ContentKey 能解码的 spade_a，等价于把 ContentKey 反着做。
// key 必须是 16 字节；padding 是明文的填充长度；tag 决定版本标签。
//
// 注意 ContentKey 在读出 decoded 之前还有一层
// decoded[i] = (previous ^ current) - 21 - popCount(i) 的变换，这里必须一并反解，
// 否则合成出来的输入根本解不开。
func synthSpade(key []byte, padding int, tag string) string {
	decoded := make([]byte, 33+padding)
	decoded[0] = []byte(strconv.FormatInt(int64(padding), 36))[0]
	copy(decoded[1:33], []byte(hex.EncodeToString(key)))
	// 尾部填充字节本身不被读取，但最后两个会被当成 seed，给点确定性内容。
	for i := 33; i < len(decoded); i++ {
		decoded[i] = byte(i * 7)
	}

	raw := make([]byte, 1+len(decoded)+len(tag))
	previousEven, previousOdd := byte(250), byte(85)
	for index := 0; index < len(decoded); index++ {
		previous := previousEven
		if index%2 != 0 {
			previous = previousOdd
		}
		current := byte(int(decoded[index])+21+bits.OnesCount(uint(index))) ^ previous
		raw[1+index] = current
		if index%2 == 0 {
			previousEven = current
		} else {
			previousOdd = current
		}
	}

	seed := raw[len(raw)-len(tag)-2] ^ raw[len(raw)-len(tag)-1]
	for i := 0; i < len(tag); i++ {
		raw[len(raw)-len(tag)+i] = tag[i] ^ seed
	}
	// tagLength = raw[0]^raw[1]^raw[2] - 48；必须等 raw[1]、raw[2] 落定后再算。
	raw[0] = byte(len(tag)+48) ^ raw[1] ^ raw[2]
	return base64.StdEncoding.EncodeToString(raw)
}

// synthBackupResponse 构造一份 DecodePlaybackResponse 能解开的 v2 响应，
// 等价于把密钥材料推导反着做。
func synthBackupResponse(plaintext []byte) string {
	material := make([]byte, 32)
	for i := range material {
		material[i] = byte(i*11 + 3)
	}

	encoded := make([]byte, 32)
	for index := range encoded {
		previous := byte(109)
		if index > 0 {
			previous = encoded[index-1]
		}
		slot := index % len(materialMask)
		salt := materialMask[slot] ^ byte(90+13*slot) ^ 85
		target := material[index] ^ previous ^ salt
		shifted := bits.RotateLeft8(target, -3)
		encoded[index] = byte(int(shifted) - 215 + 11*index)
	}

	padded := commentPad(plaintext)
	block, _ := aes.NewCipher(material[:16])
	ciphertext := make([]byte, len(padded))
	cipher.NewCBCEncrypter(block, material[16:32]).CryptBlocks(ciphertext, padded)

	return "v2." + "AAAA" + hex.EncodeToString(encoded) + "." +
		base64.StdEncoding.EncodeToString(ciphertext)
}

// materialMask 与 crypto.go 里的混淆表相同，这里复制一份避免改 crypto.go。
var materialMask = [...]byte{
	104, 64, 70, 166, 190, 168, 143, 130, 225, 254,
	251, 217, 196, 34, 45, 60, 29, 20, 103, 105,
}

// TestSynthVectorsRoundTrip 保证合成的输入真的能被本包解开。没有这层，
// Dart 侧测试红了会分不清是 Dart 移植错了，还是向量本身就是坏的。
func TestSynthVectorsRoundTrip(t *testing.T) {
	key, _ := hex.DecodeString("00112233445566778899aabbccddeeff")
	got, err := ContentKey(synthSpade(key, 4, "okok"))
	if err != nil {
		t.Fatalf("ContentKey(synthSpade): %v", err)
	}
	if hex.EncodeToString(got) != hex.EncodeToString(key) {
		t.Fatalf("ContentKey round trip: got %s", hex.EncodeToString(got))
	}
	if _, err := ContentKey(synthSpade(key, 4, "app_v2")); err == nil {
		t.Fatal("expected app_v2 to be rejected")
	}

	plain := `{"code":0,"data":{"url":"https://example.com/a.mp4"}}`
	decoded, err := DecodePlaybackResponse(synthBackupResponse([]byte(plain)))
	if err != nil {
		t.Fatalf("DecodePlaybackResponse(synthBackupResponse): %v", err)
	}
	if string(decoded) != plain {
		t.Fatalf("playback round trip: got %q", decoded)
	}
}
