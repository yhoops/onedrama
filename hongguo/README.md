# 红果解析包

从「果果剧库」抽出的独立红果（hongguoduanju.com / 番茄小说 App）解析代码。不依赖剧库 UI、账号、下载、Emby。复制本目录即可接到新项目。

源码对应原项目 `internal/app/provider_hongguo_*.go`、签名、榜单解析、弹幕、CENC 密钥还原。

## 怎么接到新项目

```bash
# 整个文件夹拷到新仓库，例如 third_party/hongguo 或 internal/hongguo
```

`go.mod` 里：

```go
require golang.org/x/text v0.32.0
```

然后：

```go
import "你的模块/hongguo"

client := hongguo.NewClient(nil) // 或传入带代理的 *http.Client
detail, err := client.FetchDetail(ctx, "123456")
media, err := client.ResolveMedia(ctx, "123456", "7890")
```

Go 1.24.1+。也可把 `package hongguo` 改成你仓库里的包名，文件不用改逻辑。

## 目录

| 文件 | 职责 |
| --- | --- |
| `types.go` | Drama / Chapter / Media / 榜单 / 弹幕等结构，以及站点常量 |
| `helpers.go` | ID、JSON 字段读取、封面校验、完结状态 |
| `sign.go` | App 请求签名 `X-Gorgon` / `X-Khronos` |
| `comment_sign.go` | 弹幕签名 `X-Argus` / `X-Ladon` + SM3 |
| `crypto.go` | 备用播放响应解密、`spade_a` → AES-128 CENC 密钥 |
| `parse.go` | 网页 `_ROUTER_DATA`、统一剧集映射 `DramaFromAny` |
| `client.go` | HTTP 客户端：App 签名请求 + 网页 GET |
| `catalog.go` | App 分类目录、网页分类、推荐分页 |
| `detail.go` | 详情 + 分集（App 优先，网页兜底） |
| `media.go` | 取流三级回退 |
| `search.go` | 网页搜索 + 名称联想合并 |
| `rankings.go` | 网页榜单（三种页面结构） |
| `danmaku.go` | 文字弹幕 |
| `hongguo_test.go` | 签名向量、SM3、ID / 剧集映射 |

纯函数（签名、解密、页面解析）可单独调用，不必走 `Client`。

## 数据通路

```
目录 / 详情
  App API  ──失败──▶  网页 https://hongguoduanju.com  (_ROUTER_DATA)

取流
  App /novel/player/video_model/v1/
    ──失败──▶ 网页 /player/{series}/{vid}
      ──失败──▶ 备用 https://djapi.999888456.xyz/api/hongguo/play
```

分集地址是占位符 `hongguo-cenc://{vid}`，真正的 mp4/m3u8 要再调 `ResolveMedia`。

## ID 约定

| 对象 | 格式 | 例子 |
| --- | --- | --- |
| 剧 | `hongguo:{series_id}` | `hongguo:753216` |
| 集 | `hongguo:{series_id}:{vid}` | `hongguo:753216:748001` |
| 媒体占位 | `hongguo-cenc://{vid}` | `hongguo-cenc://748001` |

`series_id` / `vid` 必须是 1–32 位数字。解析用 `SplitDramaID`、`VideoIDFromURL`。

## 站点常量

```
网页    https://hongguoduanju.com
App     https://api5-normal-sinfonlineb.fqnovel.com
aid     8662
app     novelread / 7.3.5.32 (73532)
备用播  https://djapi.999888456.xyz/api/hongguo/play
媒体 Referer  https://novel.snssdk.com/
```

分类：

| App key | scene | 名称 | 网页 path |
| --- | --- | --- | --- |
| `short_play` | `default` | 真人剧 | `real-drama` |
| `comic_series` | `comic_series` | 漫剧 | `comic-drama` |
| `ai_series` | `ai_series` | AI剧 | `ai-drama` |
| （仅网页） | | 动漫 | `comic` |

榜单：`hongguo-hot` / `hongguo-real` / `hongguo-comic` / `hongguo-ai`，见 `RankingBoards`。

## Client API

```go
c := hongguo.NewClient(httpClient)
c.Retries = 3
c.DeviceID / c.InstallID   // 启动时随机 19 位数字，可持久化
c.WebBase / c.AppBase      // 可改镜像
```

| 方法 | 作用 |
| --- | --- |
| `FetchCatalogPage(ctx, genreKey, scene, name, cursor)` | App 分类一页（limit=18） |
| `FetchWebCategoryPage(ctx, route, name)` | 网页分类一页 |
| `FetchRecommendations(ctx, query)` | 分类推荐，带 `filter_ids` 去重 |
| `FetchDetail(ctx, seriesID)` | 详情 + 分集 |
| `ResolveMedia(ctx, seriesID, videoID)` | App → 网页 → 备用 |
| `ResolveAppMedia` / `ResolveWebMedia` / `ResolvePlaybackAPI` | 单路取流 |
| `Search(ctx, keyword)` | 网页搜索 ∪ 剧名联想 |
| `SearchSuggestions(ctx, query)` | 最多 10 条联想 |
| `FetchRanking(ctx, board, page)` | 榜单一页，约 20 条 |
| `FetchDanmaku(ctx, seriesID, videoID, startMS, durationMS)` | 弹幕时间窗 |
| `AppRequest` / `CommentRequest` / `FetchText` | 底层请求 |

返回的 `Media`：

```go
type Media struct {
    URL      string        // http(s) 播放地址
    Referer  string
    Duration time.Duration
    CENCKey  []byte        // AES-128，空表示未加密
    Quality  int           // 约等于高度，如 720 / 1080
    Variants []Media       // 其它画质
}
```

App 取流会跳过 `bytevc2`，同分辨率优先 H.264。有 `spade_a` 时填 `CENCKey`。本包只给密钥，不解封装、不转码。

## 纯解析函数（无网络）

页面 HTML / JSON 已拿到时：

- `ParseRouterData(html)` → `window._ROUTER_DATA`
- `RouterLoaderMap(data, names...)` → `loaderData` 里对应页
- `DramaFromAny(row, category)` → 统一剧集字段
- `ParseAppDetail` / `ParseWebDetail`
- `SelectAppMedia` / `ParseWebMedia` / `ParsePlaybackAPI`
- `ParseCatalogPage` / `ParseSearchPage` / `ParseRanking` / `ParseDanmaku`
- `SignRequest` / `SignCommentRequest`
- `ContentKey` / `DecodePlaybackResponse`

网页 loader key：

| 页面 | URL | loader | 字段 |
| --- | --- | --- | --- |
| 分类 | `/category/{path}?page=N` | `category_page` | `recommendList` |
| 详情 | `/detail?series_id=` | `detail_page` | `seriesDetail.vid_list` |
| 播放 | `/player/{series}/{vid}` | `player_` | `video_player_info.main_url` |
| 搜索 | `/search/{keyword}` | `search_` | `searchList` |
| 榜单 | `/rank/{path}?page=N` | `rank_{path}/page` | `content.rankList` |

榜单 `content` 可能内联、在 `mergeLoaderData` 里，或挂在 `data-fn-args` 脚本标签上，`ParseRanking` 三种都认。

搜索联想（无需 App 签名）：

```
GET {WebBase}/incent_resource/suggestion?app_id=8662&query=...&count=10
→ { "suggest_list": [{ name, word_type, keyword, video_data }] }
```

正式搜索 = 网页 `/search/` + 联想里 `word_type=short_play_name` 的剧，按 ID 去重，标题相关度排序。

## 取流与密钥

1. **App** `POST /novel/player/video_model/v1/`  
   body: `{"video_id","content_type":1,"biz_param":{"need_all_video_definition":true,"video_platform":3}}`
2. **网页** `/player/{series}/{vid}`，校验返回的 vid / series_id，避免试看集冒充
3. **备用** `GET .../api/hongguo/play?id={base64(json)}`  
   json: `content_type=1004, series_id, vid, video_platform=3`  
   响应可能是明文，或 `v2.{hex密钥}.{密文}` AES-CBC

`ContentKey(spade_a)` 解出 16 字节 AES-128。`app_v2` / `web_v2` 会报「版本暂不支持」。

播放器侧：未加密可直接播；有 `CENCKey` 需要自己做 CENC/AES-CTR 解密（原项目用 FFmpeg）。

## 弹幕

独立签名，比普通 App 请求多 `X-Argus`、`X-Ladon`。

```
POST /novel/commentapi/comment/list/{vid}/v1/
Header: Comment-Source=601, Server-Channel=1000
body: comment_type=20, group_id=vid,
      business_param.book_id=series_id,
      start_offset_time, playlet_item_duration
```

时间单位毫秒。`ParseDanmaku` 取 `expand.offset_time` 和 `common.content.text`。

## 最小接入示例

```go
package main

import (
	"context"
	"fmt"
	"log"

	"example.com/app/hongguo"
)

func main() {
	ctx := context.Background()
	c := hongguo.NewClient(nil)

	found, err := c.Search(ctx, "总裁")
	if err != nil {
		log.Fatal(err)
	}
	if len(found.Dramas) == 0 {
		log.Fatal("empty")
	}
	seriesID := found.Dramas[0].SourceID

	detail, err := c.FetchDetail(ctx, seriesID)
	if err != nil {
		log.Fatal(err)
	}
	fmt.Println(detail.Drama.Title, len(detail.Chapters), "集")

	vid := hongguo.VideoIDFromURL(detail.Chapters[0].VideoURL)
	media, err := c.ResolveMedia(ctx, seriesID, vid)
	if err != nil {
		log.Fatal(err)
	}
	fmt.Println(media.Quality, media.URL, len(media.CENCKey) > 0)
}
```

## 相对原项目删掉了什么

本包是解析层，没有：

- 剧库缓存、目录游标落盘、5 分钟详情/搜索缓存
- 请求限流、Fake-IP / 封面代理、Cloudflare 退避（只识别拦截页）
- 播放器、FFmpeg 解封装、下载合并
- 账号、追剧、观看记录、Emby

原项目的 in-flight 去重和分页游标可按新项目自己加。`CatalogCursor` 已导出，便于你持久化后续页。

## 注意

- App 签名依赖设备参数和版本号，服务端可能随时改协议。
- 网页 `_ROUTER_DATA` 结构变化时，分类 / 搜索 / 榜单会一起挂。
- 备用播放域名是第三方，不稳定；密钥版本升级会直接失败。
- 请控制请求频率，本包默认最多重试 3 次。
- 仅用于你有权访问的内容；不要把签名密钥或设备号写进前端。

## 自检

```bash
cd hongguo
go test .
```

当前覆盖：弹幕签名固定向量、SM3(`abc`)、剧集 JSON 映射、ID 拆分。联网接口需要真实站点，未做成单测。
