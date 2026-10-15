# App 取流入口改用 `multi_video_model/preload`

2026-10 起播放页三腿全灭：「红果 App 取流失败：红果 App 接口未返回有效数据；网页取流失败：
红果该集未提供公开播放地址，可能需要登录或 App 授权；备用取流失败：红果备用播放接口未返回
该集可用的媒体和密钥」。

## 诊断

- App 取流腿原本打 `/novel/player/video_model/v1/`（单集）。它现在返回 **HTTP 200 + 空
  响应体**，而空体在 `client.dart:151`（Go 侧 `hongguo/client.go` 的同名位置）就被判死，
  所以这条腿报的是「App 接口未返回有效数据」——错误信息没说错，只是没说是哪个入口。
- 上游 issue（N3urda/hongguoTV#17）指出改打
  `/novel/player/multi_video_model/preload/v1/`。**批量接口的 v1 也已经是空体**
  （`/novel/player/multi_video_model/v1/` → 200 空体），所以换的是「preload 这个入口」，
  不是「换用批量接口」。
- `/novel/player/video_model/light/v1/` 与 `/novel/player/video_model/preload/v1/` 都是 404。

## 新入口的硬要求（三条，写错的表现都是空体或「参数错误」，和路径写错长得一样）

1. **路径** `/novel/player/multi_video_model/preload/v1/`，POST。
2. **`biz_param.video_platform` 必须是 1024**。详情接口给的是 3，而**照抄 3 会被判
   `{"code":100001,"message":"参数错误","debug_info":"video platform invalid, param:3"}`**。
   实测 0–12 / 20 / 50 / 100 / 1000 / 1001 / 1004 / 2000 / 3000 / 8662 全部被拒，只有 1024
   收；这个取值只从 `biz_param` 里读（放顶层或 query 会被读成 0）。
3. **必须带 `mixed_video_id_map`**，键是 content_type，**1004 = 短剧**（与
   `resolvePlaybackApi` 拼给第三方接口的 reference 同口径）：`{"1004": ["<vid>"]}`。
   另外 `need_all_video_definition: true` 要带（不带只有默认档）。

响应是批量的：`data[<vid>].video_model`，是一条 **JSON 字符串**（也出现过对象），结构和旧的
单集响应**完全一致**（`status` / `video_duration` / `video_list[{main_url, backup_url,
encrypt_info.spade_a, video_meta{codec_type, definition, vwidth, vheight}}]`），所以
`selectAppMedia`（编解码过滤、备选地址、CENC 密钥还原、画质档位）**一行都不用改**——
本次只换入口与请求体。解析侧**只认请求的那个 vid**，不退回「`data` 里唯一的那一项」：批量
接口里那一项可能是别的集，张冠李戴比报错糟得多（同 `media_web.dart` 核对 `series_id` 的口径）。

## 取证与验证

- 取证用一次性 Go 探针直接发签名请求（在仓库外的临时目录跑，**用后即删、不入库**）；参数取值
  参照过第三方仓库 N3urda/hongguoTV 的 `server/vendor/hongguo.cjs`（GPL-3.0，已删除、不进
  仓库），只从中读到「参数取哪些值」这一个事实，代码没有搬进本项目。
- 改动后 6 部剧各取首集：6/6 拿到可播地址与 16 字节 CENC 密钥；对选中地址发
  `GET` + `Range: bytes=0-1023` 返回 **206**、`Content-Range: bytes 0-1023/7201143`。
- 现行签名（Dart `signRequest` / Go `SignRequest`）已足够，**不需要** x-ladon/x-argus
  那一套；加字段只会扩大与上游的接触面。
- 上游现在**没有 h264/avc1 档**了（编解码普查：bytevc1 22 档 / bytevc2 8 档），
  「跳过 bytevc2」的策略保持不变（本机 MediaCodec 解不了 VVC），代价是不少剧只剩 1080 一
  档——画质面板出现「该剧最低 1080P」是**预期**，不是回归。

## Considered Options

- **新入口失败再链式回退旧接口**：旧接口是确定性地死（200 空体），多一次注定无用的请求，
  还会让「到底哪条腿成功了」在日志里变模糊。不链。
- **只靠网页腿**：这部剧的网页页没有公开 `main_url`（`parseWebMedia` 报「该集未提供公开
  播放地址」），当时是死路。
- **顺手用 `mixed_video_id_map` 一次问多集做预取**：机制上是免费的（一条响应能装多集），
  但预取在本项目是「整文件下载」（`docs/adr/0009`），走的是另一条路；本次范围只修单集取流。
- **把 `video_platform` 做成可配置或启动时扫描**：只有 1024 收，扫描等于每次播放先打十几
  个注定被拒的请求。

## Consequences

- `1024` 与 `1004` 的语义上游没有公开，注释里如实写成「入口要求的取值 + 实测范围」，不当
  画质/清晰度理解。
- 上游哪天把 preload 也停掉，症状还是「200 空体」——三腿结构（App → 网页 → 备用，
  `docs/adr/0004`）因此保持不变，届时换的是这一个常量与请求体。
- **App 详情腿又活了**（`/novel/player/video_detail/v1/` 现在返回 40.5KB、`code:0`、
  30 集分集表），与 `docs/adr/0013` 记的「全是空体」相反。上游会来回放接口，这正好说明
  「App 优先、保留兜底腿」的判断是对的。
- Dart 与 Go 两侧同步改（`packages/hongguo_dart/lib/src/media.dart`、
  `hongguo/media.go`），共享向量（`hongguo/testdata/vectors.json`）不涉及。回归网：
  离线 `test/app_stream_test.dart` 钉请求形状与解析分支，`LIVE=1 test/live_test.dart`
  钉真上游仍然认这套请求。
