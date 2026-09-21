# onedrama 实施计划

自用短剧客户端，v1 只接红果。目标是能稳定播、自己天天刷；不公开发 APK，不做红果官方 UI 的像素级仿品。

决策依据见 `docs/adr/`，领域词表见 `CONTEXT.md`。

## 范围

**做**：短剧库（搜索 + 四个一级标签 + 题材 chip 跳搜索 + 双列瀑布流）、榜单（右上角图标）、详情页（竖版沉浸式）、播放页（Flutter 控件 + 手势 + 锁屏 + 选集 + 收藏 + 倍速 + 画质）、我的（收藏 / 历史）、设置页全项、本地观看进度、drift 持久化。

**不做**：账号 / 云同步、弹幕、离线下载（**预取下一集不算**——那是按集淘汰的播放缓存，见 [ADR-0009](adr/0009-prefetch-next-episode-as-a-whole-file.md)；两者差在「用户点名要下的整部剧」与「播放器自己攒的下一集」）、多源（v1 只有红果）、像素级仿红果官方 UI。

## 决策摘要

| 主题 | 选择 | ADR |
| --- | --- | --- |
| 协议 | Dart 重写，`packages/hongguo_dart` 对齐 Go 的 Client API；`hongguo/` 留作协议真相，不进 APK | [0001](adr/0001-dart-rewrite-instead-of-gomobile.md) |
| 播放 | 薄 Android 插件（ExoPlayer + CENC 密钥注入 + Texture），零 Kotlin UI，控件全在 Flutter | [0002](adr/0002-thin-exoplayer-plugin-owns-cenc.md) |
| 防分叉 | 共享 fixtures，Go 与 Dart 各跑一遍解析并断言输出相等 | [0003](adr/0003-go-package-as-protocol-truth-with-fixtures.md) |
| 取流 | 三级全搬：App 签名 → 网页 → 第三方备用 | [0004](adr/0004-all-three-media-resolution-paths.md) |
| 详情页评分 | 只从网页详情取（App 接口没有评分字段） | [0007](adr/0007-detail-rating-from-web-detail.md) |
| 剧库 | 每次启动整批拉一份到本地，首页本地优先 | [0008](adr/0008-library-snapshot-on-every-launch.md) |
| 预取 | 下一集**整集落盘**，不是只预取头部 | [0009](adr/0009-prefetch-next-episode-as-a-whole-file.md) |
| 状态 / 路由 | Riverpod + go_router | |
| 网络 / 图片 | dio / cached_network_image | |
| 存储 | drift（favorites / watch_history / watch_progress）+ prefs（设置、DeviceID） | |
| 礼貌 | in-flight 去重 + 详情 / 搜索 / 榜单 5 分钟 TTL；取流不缓存 | |

## 目录结构

```
onedrama/
├── hongguo/                  # Go 参考实现，不进 APK，只当协议真相
├── packages/hongguo_dart/    # Dart 协议包（签名 / 取流 / 解析），纯 Dart 可单测
├── lib/ android/ ...         # Flutter 应用在仓库根，flutter run 直接跑
├── CONTEXT.md
├── docs/adr/
└── docs/plan.md
```

---

## 阶段 0 — 环境（半天）

- [x] Flutter 装好（Scoop，3.47.5 stable / Dart 3.13.4）
- [x] Android licenses 已接受
- [x] 真机连上：Redmi `23013RK75C`（`mondrian`），`adb devices` 状态 `device`
- [x] Gradle 仓库改阿里云镜像（`maven.google.com` 在本机 15s 超时不可达）
- [x] `flutter create --platforms=android` 脚手架；包名 `com.example.onedrama`，**不伪装**红果 / 番茄
- [x] 建 `packages/hongguo_dart`（纯 Dart 包）
- [x] 基线：`cd hongguo && go test ./...` → `ok hongguo 0.976s`
- [x] debug APK 构建通过（`app-debug.apk`，144 MB，首次 1016 s）

**产出**：能 `flutter run` 到真机的空壳。

### 环境备注

- `flutter` / `dart` 不在**当前** shell 的 PATH（Scoop 已写入持久 PATH，新终端才有）；脚本里用全路径 `E:\Scoop\apps\flutter\current\bin\flutter`。
- 网络实测：`maven.google.com` **不可达**；`services.gradle.org`、`plugins.gradle.org`、`pub.dev`、`repo.maven.apache.org`、`maven.aliyun.com` 均正常。所以 Gradle wrapper 不用换源，只补了 Maven 镜像。**镜像方案已被一次完整构建验证**。
- `GRADLE_USER_HOME=E:\Env\gradle`（不是默认的 `~/.gradle`）。
- 构建时若把命令接到管道里（如 `| tail`），Gradle 输出会被缓冲到进程结束才落盘——想看实时进度就直接重定向到文件，别走管道。
- **真机取日志要用 `flutter run --release`，不要用默认的 `--debug`。** debug 变体走 debug 签名，与
  已装的 release 包签名不同，`flutter run` 于是**先卸载再安装**——本机的收藏 / 历史 / 观看进度
  跟着一起没了（风险 7，已实打实发生过一次）。release 变体读 `android/key.properties` 用同一把
  onedrama 密钥，是原地升级、不卸载。
- **MIUI（HyperOS）会在安装时弹确认框，屏幕锁着就等于「用户取消」**，`adb` 报
  `INSTALL_FAILED_USER_RESTRICTED: Install canceled by user`。装之前先把屏幕解开；或者
  开发者选项里打开「USB 安装」免掉这个框。

## 阶段 1 — 播放穿刺（1–2 天）

目标一句话：**真机上播出一集带 `CENCKey` 的剧**。四小步各自判定成败。

- [x] **1. 纯函数先行**（不需要安卓）：`ContentKey`、`DecodePlaybackResponse`、SM3、`SignRequest`、ID 工具已搬进 `packages/hongguo_dart`，28 个契约测试全绿
- [x] **2. 最小 App 客户端**：`AppRequest`（`X-Gorgon` / `X-Khronos` / `X-SS-STUB`）+ `fetchDetail` + `resolveAppMedia` 已接真接口验证
- [x] **3. CENC 解密算法**：离线验证通过。原计划是「薄插件把密钥注入 ExoPlayer 的 DRM」，**真机证伪**后改为客户端解密，见下
- [x] **4a. 离线：整集解密成可播的明文 MP4**（已验证，见下）
- [x] **4b. 真机播出一集**（预下载解密路径）——**阶段 1 目标达成**，见下
- [x] **4c. 流式解密数据源**（已完成，真机验证过，见下）
- [ ] **4b 的收尾**：切画质仍要重新取一次流（但不再重下整集）；`prepareEpisode` 保留为兜底路径

### 第 4c 步：边下边解（不用再等整集）

Dart 侧只取**头部**（`moov` 在那里，取 1 MB 有余量）解析出样本索引与等长替换补丁，
编成一份二进制「解密计划」交给 Kotlin；Kotlin 的 `CencDecryptDataSource` 在数据源这一层
按字节范围二分查样本、就地 AES-CTR 解密。

**关键收益**：任意字节位置都能从对应的 counter 块起算，所以**拖动进度条也是对的**——
这正是它比「先下载整集再解」强的地方。

**真机证据**（日志）：

```
setMedia mode=stream-decrypt keyLen=16
解 #0 文件 110284..110290｜样本 110284+29142｜样本内偏移 0｜解后 0000001d4001
解 #0 样本内偏移 6｜解后 0c02ffff016000000300...
解 #0 样本内偏移 33｜解后 00000054
STATE_READY after 2257ms
```

`0000001d4001` 是「29 字节 NAL + HEVC 头」。注意同一个样本被切成**四段不连续的读**
（样本内偏移 0 / 6 / 33 / 37）都解对了。提取器读完 `moov`（约 110 KB）直接跳到样本区，
说明它真的在流式读。

**这一步踩的坑值得记下来**：真机上表现为 `Invalid NAL length`——和编解码毫无关系的
一个报错。定位顺序是：① 用 JDK 单独验 Java 的 `AES/CTR/NoPadding` 语义（证明密码学
没错）→ ② 在数据源里打日志，看到「样本偏移读出 0、长度读出十亿」→ ③ 离线往返测试
（`test/decrypt_plan_test.dart`）一眼看出编码器把样本记录里的 IV 漏写了、又在记录后面
单独补了一次，每个样本多出 8 字节、后面全部顶歪。

**教训**：跨语言传二进制格式，往返测试（编码后按对端的布局自己解一遍、游标必须走到
末尾）比在真机上猜快一个数量级。这条测试已经留下来当回归。

### 第 4b 步：真机上播出来了（阶段 1 达成）

路径：下载整集 → 用 `hongguo_dart` 里已验证的那套解密 → 落盘 → 把 `file://` 路径当媒体地址
传给 ExoPlayer。**Kotlin 侧零改动**——ExoPlayer 原生认本地文件。

```
[spike] 画质=1080 加密=true
[spike] KEY=f7229a19a008899bfdf5863457a837ee
[spike] 目标 /data/user/0/com.example.onedrama/cache/cenc_7679650754780482584.mp4
[spike] 播放本地文件 file:///data/user/0/com.example.onedrama/cache/cenc_....mp4
CencPlayer: setMedia drm=off keyLen=0
CencPlayer: STATE_READY after 458ms
[spike] final: off ready=458ms state=ready err=无

MediaCodec: [video-debug-dec] ComponentName: c2.qti.hevc.decoder
            Qinput: 149, Render: 150, Drop: 0, Avg Render Interval: 33ms
```

`STATE_READY` 458–613 ms，`err=无`，HEVC 硬解 30fps 稳定、零丢帧，纹理里是真实画面。
注意 `drmMode=off`、`keyLen=0`——播放阶段完全不碰密钥，解密已经在 Dart 侧做完了。

**音频正常**（真人听过确认）。设备侧的 `audio-debug-dec` 报 `Render: 0, Drop: 217` 是**误导**：
小米这套计数器只对视频有意义——音频帧永远不"渲染到画面"，于是全被记成 drop。
以后看到音频 drop 全满别慌，用 FFmpeg 量音量（`volumedetect`）才是可信判据，实测
`mean_volume: -14.2 dB`、`max_volume: 0.0 dB`。

### 第 4a 步：抹平加密痕迹这一步已验证

`moov` 里的加密盒子换成**等大** `free`（`senc`/`saiz`/`saio`/`sinf`/`pssh`），样本条目的
`encv`/`enca` 还原成 `sinf`/`frma` 里记录的原始格式（这条流是 `hvc1`，不是写死 `avc1`）。
等长是刻意的：`mdat` 不移动，`stco` 的绝对偏移一个都不用重算。

**证据**（`dart run tool/decrypt_to_file.dart`，再交给 FFmpeg）：

```
下载 15286780 字节｜轨道=[vide, soun]｜样本=9043
等长替换补丁 10 处
已写入 clear.mp4（15286780 字节，与输入等长 true）

ffmpeg -i clear.mp4 -frames:v 60 -f null -   →  exit=0，零告警
ffmpeg -i head.mp4  -frames:v 3  -f null -   →  Invalid NAL unit size（对照）
clear.mp4 的 mdat 开头：0000 001c 4001 0c02 ffff 0160 0000 0300
```

**不带任何密钥就能解出 60 帧**，音轨也全程无告警——等于同时验证了视频与音频解密、以及
`moov` 改写的正确性。音频此前验不了：裸 AAC 没有 NAL 结构，`walkAvcc` 对它没意义。

**落下的实现**：`lib/src/cenc.dart` 的 `BytePatch` / `freeBoxOfSize` /
`buildNeutralizingPatches` / `decryptToClearFile`。样本条目的子盒子起点随 handler 与
version 变（视觉 78、音频 28 起），与其把算术写对，不如**按「size 字段自洽且不越界」
找一个 `sinf`**——代码短，也不怕别的封装格式。

### 第 3 步：为什么原计划作废，以及改成了什么

原计划「薄插件把 16 字节密钥喂进 ExoPlayer 的 DRM」。**真机证伪，而且不是实现问题：**

1. 红果的流**没有 `pssh`**，ExoPlayer 因此不建 DRM 会话。补一个等大的 `pssh` 进去
   （`udta` 360 字节 → `pssh` + `free`，总长不变、`stco` 偏移不用重算）——**已实现并跑过，无效**。
2. 读 media3 源码找到真正的原因：`Mp4Extractor` 在 `nalUnitLengthFieldLength != 0` 时
   **无条件**把 length-prefixed NAL 转成 Annex-B，代码里没有任何加密分支。
3. 验尸确认：视频第一个样本的 NAL 长度前缀**本身就是密文**（`e416e75b…`，按 4 字节读出来是负数）。

结论：**提取器必须能在明文里看到 NAL 结构**。补 `pssh`、走 ClearKey、用设备上确实存在的
`libdrmclearkeyplugin.so` 都改变不了。而 App 源正片全是加密的，ADR-0002 的「失败则只播明文」
回退等于片库为空。

**改为客户端按 CENC 规则解密**（[ADR-0005](adr/0005-client-side-cenc-decryption.md)）。实测形态：

| 项 | 值 |
| --- | --- |
| 方案 | `schm=cenc`，AES-128-CTR |
| 粒度 | **整个样本**，无 subsample（`senc` flags=0） |
| IV | `senc` 逐样本 8 字节，逐样本 +1；`saiz` 每样本恰好 8 |
| 语义 | counter 块 = `IV ‖ 00000000_00000000`，低 8 字节按大端递增 |

**验证结果**（离线，`dart run tool/verify_decrypt.dart`）：

```
几何自检：mdat=[209064, 15286780) 铺到 15286780｜洞=0 重叠=0 越界=0
vide #0 解密后头 16 字节：0000001c 40010c02 ffff0160 00000300 → avcc=true nal=5
trak vide：检查 40，AVCC 走通 40 走不通 0
```

`00 00 00 1c` 是 28 字节 NAL 长度、`40 01` 是 HEVC 的 VPS NAL 头，与 FFmpeg 认出的 `hevc (Main)` 一致。

**两个方法论上值钱的点：**

- **用 FFmpeg 当裁判**。本机装了 FFmpeg，而原项目本来就用它解 CENC。`-decryption_key`
  一带就能解出帧（不带则报 `Invalid NAL unit size`）——这一步把「是不是密钥错了」这条歧路
  直接排除，指向实现 bug。它还抓到了真正的 bug：**CTR 的 keystream 必须用 AES 的加密方向
  生成**，我写成了解密方向，得到逆密码流、静默全错。
- **几何自检先于密码学**。所有样本的 `[offset, end)` 必须严丝合缝铺满 `mdat`；它不过时的症状
  和「解密错了」一模一样，必须先修它。这次它一次就过了，等于证明了 `stsc`/`stsz`/`stco` 的
  解析是对的，把搜索空间砍掉一半。

### 第 2 步产出与发现

**签名已被服务端接受**——这是本步最重要的结论，而且证据是双向的：

1. **Go 与 Dart 打同一个接口得到同一个答复**。用陈旧的 `series_id=753216` 同时跑两侧，两边都返回 `101000`，`debug_info` 是 `pack" ret empty`。差异为零。
2. **真数据跑通了**。免签名的联想接口挖出真实 ID 后：

```
series_id=7679647645622619198
剧：总裁夫人来自东北｜55 集｜短剧｜finished
第 1 集：vid=7679650754780482584 画质=1080 加密=true 备选=1
CENCKey=16 字节
```

**发现**：

- 真实 `series_id` 是 **19 位**（`7679647645622619198`），README 里的 `753216` 是陈旧示例，不是活的。`NumericID` 的 1–32 位限制足够。
- App 源的正片**默认加密**（试过的都有 `CENCKey`），明文只可能出现在网页 / 备用源。这加重了阶段 1 第 3–4 步的分量：CENC 走不通，v1 的片库会大面积空掉。

**已知分歧（低风险，暂不处理）**：Go 用 `json.UseNumber()` 精确保留数字，Dart 的 `jsonDecode` 把超出 int64 的数字降级成 `double`。当前 ID（约 7.7e18）距 int64 上限（9.22e18）还有余量，且关键字段有 `series_id_str` 字符串版本。真撞上了再上流式解析。

**验证入口**：

```bash
cd packages/hongguo_dart
dart test                      # 离线契约测试，live 自动跳过
LIVE=1 dart test test/live_test.dart   # 真接口冒烟
dart run tool/probe.dart       # 手动探针，dump 响应形状
```

### 契约向量（阶段 1 第 1 步产出）

Go 包是向量源，Dart 侧读同一份 JSON 断言输出相等（[ADR-0003](adr/0003-go-package-as-protocol-truth-with-fixtures.md)）：

```
hongguo/vectors_test.go        向量生成器 + 合成输入自检
hongguo/testdata/vectors.json  生成物
packages/hongguo_dart/test/protocol_test.dart   Dart 侧断言
```

重新生成：`cd hongguo && EMIT_VECTORS=1 go test -run TestEmitVectors .`

已锁住的：SM3 ×3、`splitDramaId` ×9、`signRequest` ×2（含 `X-SS-STUB` 有无）、`contentKey` ×3（含拒绝 `app_v2`）、`decodePlaybackResponse` ×2。

`contentKey` 与 `decodePlaybackResponse` 的真输入要联网才有，向量里的输入是**反解合成**的（`synthSpade` / `synthBackupResponse` 把算法倒着做）。`TestSynthVectorsRoundTrip` 保证合成输入真的能被本包解开——没有它，Dart 侧红了会分不清是移植错还是向量坏。

**验收**：有密钥的集出声出画、能拖进度、能暂停续播。

**已知的未知**：`LocalMediaDrmCallback` 需要一份格式正确的密钥响应，得手工构造；media3 若不接受，换自定义 `DrmSessionManager`。

**失败回退**：按 [ADR-0002](adr/0002-thin-exoplayer-plugin-owns-cenc.md) 只播明文，加密集在详情页与选集上标注禁用并给原因。

## 阶段 2 — 协议包补全（3–5 天）

- [x] 三级取流全搬，含备用接口的 AES-CBC 响应解密（`resolveMedia` / `resolveWebMedia` / `resolvePlaybackApi`）
- [x] 网页解析：`parseRouterData`、`routerLoaderMap`、`dramaFromAny`、`extractAttr`、`unescapeHtml`
- [x] 分类 / 推荐分页，照搬 Go 的守卫：offset + session_id（30 分钟过期）、`pageSignature` 反重复页、`has_more` 是唯一终止信号、`limit=18`
- [x] 搜索：联想（≤10 条）+ 网页搜索 ∪ 剧名联想，按 ID 去重、标题相关度排序
- [x] 榜单：20 / 页，`hasMore = page < totalPages`（**受上游渲染摇摆影响，见下**）
- [x] 封面轻校验（仅 https、拒内网 / localhost、拒私网 IP 字面量），非法用占位图
- [x] 拦截页识别（`catalogBlockReason`，只看响应体与 `Cf-Mitigated` 头，不看状态码）
- [ ] in-flight 去重与 TTL 缓存（详情 / 搜索 / 榜单）——留到阶段 3 的网络层
- [ ] fixtures 双向比对全部接上——目前只有纯函数的向量（阶段 1 第 1 步）

**要补的洞已补**：Go 的 `FetchCatalogPage` 不校验 `genreKey`，拼错只会静默返回空页；Dart 侧先对着 `appGenres` 验一遍。

### 阶段 2 的真接口验证

`LIVE=1 dart test test/live_test.dart` 全绿（7 条）：

| 测试 | 结果 |
| --- | --- |
| 联想接口挖真实 series_id | ✅ |
| 签名被接受：详情 + 取流拿到 16 字节密钥 | ✅ |
| 分类分页：一页有结果，游标推进、第二页不重 | ✅ |
| 榜单：20 条一页、名次严格递增 | ✅（带重试，见下） |
| 搜索：网页 ∪ 联想，联想单独可用，排序按相关度 | ✅ |
| 网页分类（免签名） | ✅ |
| 三级取流 `resolveMedia` | ✅ |

### 榜单的上游摇摆（重要，别误判成改版）

**站点在两种渲染之间随机摇摆**，同一板块连续请求会交替命中：

- **旧渲染**：榜单数据在 HTML 里——`loaderData[rank_…/page].content` 内联，或挂在
  `mergeLoaderData` / `router-data-fn` 脚本上。**能解**。
- **新渲染**：HTML 里**完全没有榜单数据**（`rankList` 零次出现），页面交给 React 客户端
  另行请求。此时**无论 Go 还是 Dart 都解不出来**。

判据是拿 Go 当对照跑出来的：连跑三轮，每轮都有不同的榜失败（第 1 轮 hot 挂、第 2 轮
comic 挂、第 3 轮三个挂）；随后 Dart 连跑六次，三次成功两次失败——**两边行为一致，
说明移植没错，抖动在站点**。实测失败率约一半。

所以：调用方要**重试**，别把一次失败当成站点改版。测试也按这个来写（六轮内至少成功一次）。
真要彻底解决，得去 `rank.*.js` 里找出新渲染调的那个接口——那是另一个活儿。

**再加一层兜底**（阶段 4 补的）：全失败时退回**上一次成功的结果**——`lib/data/ranking_cache.dart`
把它落进 prefs，进榜单页 0 等待先显示旧榜、再后台刷新；刷新失败就保留旧数据，只在顶部写清
「刷新失败，显示 9月19日 的榜单」。站点摇摆时给一个错误页，比给一份旧榜没用得多。不设过期：
一周前的榜也比错误页强，日期已经把「旧」说清楚了。「清除缓存」连它一起清。

## 阶段 3 — 数据层与 UI（1–2 周）

### 3a 数据层（已完成，真机验证过）

- [x] 本地库三张表：`drama_snapshots` / `favorites` / `watch_progress`。**用 sqflite 而不是 drift**——原因见 [ADR-0006](adr/0006-sqflite-instead-of-drift.md)（drift 走的 sqlite3 native assets 要从 github 下载，本机不通）
- [x] prefs 存设置与 `DeviceID` / `InstallID`（**启动生成一次后持久化**，别每次重启换）
- [x] Riverpod providers（设置、客户端、数据库、收藏、历史、续播点、详情、榜单、联想）
- [x] go_router 依赖就位（路由在 3b 接页面时搭）
- [x] dio 拦截器：in-flight 去重 + TTL 缓存。**取流一律不缓存**（`main_url` 带时效签名）
- [x] 主题与大字模式已接线（`main.dart` 跟着设置走）

**表结构的一处设计调整**：计划原本写「favorites / watch_history / watch_progress」，实际是
`drama_snapshots` / `favorites` / `watch_progress`。理由：`CONTEXT.md` 已写明 *Watch History
derived from Watch Progress*，历史不该单独存（同一件事两份真相迟早不一致）；而收藏与历史都要
显示标题封面，不该为此重拉详情、离线也要能列出来——所以需要一张快照表。

**真机验证**（穿刺页顺手跑一遍数据层）：

```
[spike] 数据层：进度写入 1 条（历史 []→1 条，首条「总裁夫人来自东北」第 1 集）
[spike] 数据层：收藏 1 条（首条「总裁夫人来自东北」）
[spike] 缓存：命中 0，合并并发 0，在存 1 条
```

### 3b 页面（已完成，逐页真机截图核对过）

- [x] 短剧库页：搜索框（点击跳搜索）、综合 / 真人剧 / 漫剧 / AI剧 四个一级标签、题材 chip、**「上次观看」快速入口**（直接开播续播）、双列海报流（「全 N 集」角标）、右上角榜单入口、搜索框右侧的历史快捷方钮
- [x] 榜单页：四个榜 Tab + 名次列表（前三名强调色）+ 下拉刷新 + 分页
- [x] 详情页：模糊封面铺底 + 渐变 + 海报 + 标题、评分 / 热度 / 标签、简介可展开、选集网格（超 30 集分页）、底部固定「继续观看 / 开始播放」、海报 Hero 连贯动画
- [x] 播放页：右竖控制栏（收起 / 上一下一 / 播放键 / 集数 / 进度 / 竖向进度条 / 总时长 / 全屏 / 锁）、点屏显隐、双击播放暂停、左半屏调亮度、右半屏调音量、左右滑拖进度、播放设置面板（选集 / 收藏 / 倍速 / 画质 + 亮度音量 + 简介 + 手势说明 + 退出播放）
- [x] 播放进度落库（暂停、退出各落一次）+ 自动连播
- [x] 我的页：收藏 / 历史分段控件 + 空态 + 真实列表（历史带进度条与相对时间）
- [x] 设置页：主题 / 播放 / 手势与控制 / 剧库与存储，**全部设置项真的生效**

**五个设置项真的接线了**（不是摆设）：默认倍速 → 进播放页就应用；优先画质 → 从同一次取流
的 `variants` 里挑最接近的一路；自动播放下一集 → 演完切下一集；记忆播放进度 → 关掉就不写库；
控制栏位置 → 竖栏在左还是在右。

### 3c 深色模式与首页「上次观看」（已完成，真机逐页核对过）

**深色模式此前是全站坏的**，而且不是漏接线：`main.dart` 一直是对的（`themeMode` 跟设置走、
`buildAppTheme(dark)` 也建了深色 scheme），坏在页面**根本不读它**——`OneDramaColors` 是一份
写死的浅色板，各页直接引用 128 处，绕过了 ThemeData。实测后果：正文色 `#1A1A1A` 压在
`#0E0E11` 上对比度约 **1.1:1**（WCAG 正文下限 4.5:1），标题与行标签全部看不见；搜索框、chip、
选集宫格仍是浅色块。当时唯一写了深色分支的只有底栏（`home_shell.dart`）。

色值取自用户补的两张参考图（`参考的前端页面/深色1.jpg`、`深色2.jpg`），按像素采样得到：

| 槽位 | 深色 | 浅色 |
| --- | --- | --- |
| 页面底 | `#0C0D12` | `#F6F6F8` |
| 卡片面 | `#12151C` | `#FFFFFF` |
| 输入框 / chip | `#17181D` | `#F1F1F4` |
| 主文字 | `#F4F5FA` | `#1A1A1A` |
| 次文字 | `#8790A1` | `#9A9AA0` |
| 分隔线 | `#20242D` | `#EFEFF2` |
| 强调色 | `#FF4C75` | `#F0416C` |

**改法**：`OneDramaColors` 拆成 `light` / `dark` 两个常量实例 + `OneDramaColors.of(context)`，
`buildAppTheme` 与它同源（ColorScheme、`scaffoldBackgroundColor`、`dividerColor` 都从这里取），
页面里 128 处静态引用全部改成 `palette.x`。两处**刻意不取反**、照参考图分开处理：首页搜索框
右侧那个方块在深色下仍是深底、图标换成强调色（拿 `primaryText` 取反会变成一整块白）；题材
chip 的文字在深色下用次文字色。

**播放页不跟主题走**：它整页暗色是设计的一部分，所以强调色固定用 `playerAccent`（深色那一档），
不走 `of(context)`——否则浅色模式下播放页会拿到浅色板的强调色。

**首页「上次观看」**：夹在题材 chip 与海报流之间，取历史里最近的一条（`historyProvider` 已按
最后观看时间倒序），显示封面缩略 + 剧名 + 「上次看到第 N 集 · 00:07」+ 粉色圆形播放键。点一下
**直接开播**（先取一次详情拿分集列表，期间圆钮转圈），不绕详情页；没有历史时整块不出现、不占位。

**播放设置面板对齐参考页**：剧名那一行右侧加「X」关闭键；选集 / 收藏 / 倍速 / 画质改成近方形
的块、图标与文案都在块内；「手势操作说明」「退出播放」各自一张圆角卡。

⚠️ 面板那四个块的宽度**必须自己 `width: double.infinity` 撑满**：只给高度约束时 `Container`
在另一轴上会缩到跟 child 一样宽，child 是图标/一行小字，于是变成四根 22×52 的竖条——这一版
之前就是这个 bug（`Row` 的 `Expanded` 撑开的是外框，装饰盒不跟着走）。同款写法全仓只剩这一处，
`lint` 抓不到，改 UI 时留意。

**与参考页的有意偏差：**

- **海报用统一 3:4 网格，不是参差瀑布流**。参考页那种参差来自封面原始比例不定，但尺寸未知时
  瀑布流会在图片加载完的瞬间跳版；固定比例不跳、观感更稳。想换 `MasonryGridView` 随时可以。
- **播放页是「预下载解密」路径**（[ADR-0005](adr/0005-client-side-cenc-decryption.md)），
  所以进页要先等整集下完（有百分比进度与说明文案），**切画质要重新下一次**。流式解密数据源
  是 4c。
- **榜单页必须重试**：站点在两种渲染间摇摆（见 `parseRanking` 注释）。所以每个榜自动重试
  6 次、间隔 0.5–2 秒；全失败时给的是**说清原因的**错误文案，而不是「加载失败」。
  （实测 4 次 × 300ms 间隔曾全挂——重试太密会落到同一个边缘节点、拿到同一版页面。）

## 阶段 4 — 收尾

- [x] 深色模式（色板亮度感知化 + 全站 128 处迁移 + 真机逐页核对，见 3c）
- [ ] 设置页全项生效（含大字模式、控制栏位置左右侧）
- [ ] 「剧库与存储」：清空历史、清空收藏、清缓存、重新生成设备号
- [ ] 空态 / 错误态 / 断网态
- [ ] 拦截页、签名失效等错误的用户可读提示

### 4a 榜单兜底 / 播放页画幅 / 详情页数字与评分 / 轻动效（已完成，真机逐条核对过）

**1. 榜单兜底**（见上「榜单的上游摇摆」的补充）。`RankingCache` 落 prefs，**只存第 1 页**——
榜单 20 条一页、`totalPages` 上限 500，全存会把 prefs 撑大。顺手删掉 `providers.dart` 里
那个**全仓无引用**的 `rankingProvider` 死代码。

**2. 播放页画幅：之前是纯拉伸。**`Stack(StackFit.expand)` 把**整屏**尺寸同时喂给
`setSurfaceSize` 和 `Texture` 的布局盒，中间没有任何比例校正——本插件是零 UI 的（没有
`PlayerView` / `AspectRatioFrameLayout`，[ADR-0002](adr/0002-thin-exoplayer-plugin-owns-cenc.md)），
Kotlin 侧连 `onVideoSizeChanged` 都没重写。代码里那句「画幅由 ExoPlayer 自己保持，它会
letterbox」是**错的**：真机截图上下左右都没有黑边，就是被拉满的表现。

改法：比例用**现成的 `vwidth` / `vheight`**——`media.dart` 早就把它读出来了，随即又扔掉
（只留 `vheight` 当 `quality` 标签）。现在 `Media` 保留真实宽高，`_videoSurface()` 用
`AspectRatio` 包住 `Texture`，并把出画缓冲设成视频**原生像素尺寸**。**Kotlin 一行未改。**

**contain 是照参考图复刻的**，不是我们自选的口径：量过 `参考的前端页面/ac22ee7…jpg` 与
`dedeee9…jpg`，视频区是 **0–239 与 2160–2399 纯黑（rmax=0）、240–2159 有画面**，即
1080×1920 = 正好 9:16 居中 letterbox。

**但比例不统一**：26 部剧里 **12 部竖屏 9:16、13 部横屏 16:9、1 部 1.74:1**，且全部无旋转
标记。在 1080×2400 上，横屏剧 contain 会剩 **74.7% 是黑的**、cover 会裁掉 **159%**。所以
「一律 contain + 保留全屏键转横屏」是**刻意的取舍**——横屏剧的舒适出口就是那个全屏键。

**3. 详情页数字与评分。**
- 热度原来显示 `42033495`，因为 `dramaHeat` 把整数 `hot_score` 直接 `toString()` 了。上游
  口径是**整数万、截断**：榜单 `heatText` 实测 `94677019 → 9467万热度`；App 的
  `series_sub_title_list[1]` 原文是「红果热度值4203万」，与网页 `hot_score_data.text`
  `4203万热度` 一致。**两处独立来源指向同一口径。**
- 观看人数 `2977018 → 297.7万人看过`：上游**没有任何格式化好的播放量**，这个后缀与小数位
  是本地按上游**计数类**口径合成的（`33371 → 3.3万人评分`，同为截断不是四舍五入）。
- 断言在 `test/format_test.dart`，期望值全部来自真接口采样，不是照着重算的。
- 评分：**App 详情接口根本没有**（39 个字段里键名含 score/rating/heat/hot 的只有 `hot_score`，
  11 部剧全部如此），只能走网页详情 → [ADR-0007](adr/0007-detail-rating-from-web-detail.md)。
- 顺手修掉一个真 bug：`dramaOnlineDate` 读 `sub_title_list`，而 App 响应里是
  `series_sub_title_list`——**Go 侧 `parse.go:61` 也一样写错**，两边同时修（ADR-0003）。
  诚实地说：15 部剧的副标题都是 `[全N集, 红果热度值X万]`、**没有一部带「上新」**，所以这条
  修复目前**不改变任何输出**，只是让机制真的能用。

**4. 轻动效。**僵硬的原因不是没有动画——`theme.dart` 早就有 `FadeForwardsPageTransitionsBuilder`
与 `InkSparkle`，海报卡也有按压缩放。是**31 个可点面里约 20 个**为裸 `GestureDetector` 套
不透明 `Container`/`Row`，零按压反馈。抽了 `lib/ui/widgets/pressable.dart`（缩放 + 触感），
铺到 **22 处**，手感统一在 `OneDramaSizes.pressScale` / `pressDuration`（110ms）。

另外两处：
- `settings_page.dart` 的 `_Section` 是 `Container` 不是 `Material`，里面 `InkWell` 的水波纹
  被不透明底色**整个盖住**——十行设置项点了没反应。换成 `Material` 即可。
- 底栏切页是 `StatefulShellRoute.indexedStack`，**瞬切无过渡**。在 `home_shell.dart` 的 body
  外补一层 130ms 淡入 + 上移 10px（在 `didUpdateWidget` 里认 index 变化，深链也覆盖）。

触感走 `HapticFeedback.selectionClick()`，**严格跟随设置里的「触感反馈」开关**——那个开关
既然摆在设置页，就不能有绕过它的路径。不做弹性 / 回弹 / 列表错位入场那类重动效。

**没做，另开一轮**：「优先画质」按真实宽高选档。它现在拿 `Media.quality` 排档，而那是
**档位标签不是像素高**（有剧把 1280×720 标成「1080p」）；且横屏剧的 360–720 档是 `bytevc2`、
被 `selectAppMedia` 滤掉，那些剧**只有 1080 一档**可挑，设置形同虚设。

---

### 4b 页面转场换成轻的、封面预加载（已实现，见「怎么验的」）

**1. 转场：系统那套其实一直在跑，只是「重」且注释写错了。**`theme.dart` 早就配了
`FadeForwardsPageTransitionsBuilder`，所以「跳转没动画」这个前提不成立。但它的实际参数与
当时的注释对不上——SDK 源码（`material/page_transitions_theme.dart` 的
`kTransitionMilliseconds` 与三个 `Animatable`）是 **450ms**、旧页横滑 **-25%** 并在前 25%
淡出、新页横滑 **+25%** 并淡入；而注释写的是「淡入淡出 + 轻微上移」。横向大位移 450ms 是
M3 里最重的一档，跟底栏那套 130ms 淡入上移不是一套语汇。

改成自定义 `FadeUpPageTransitionsBuilder`（`lib/ui/widgets/page_transition.dart`）：
新页 `opacity 0→1` + 上移 12px / 180ms，**旧页一动不动**，返回天生镜像。

两处非显然的地方，都写在代码注释里了：

- **旧页静止靠的是「不重写 `delegatedTransition`」**——基类默认返回 null
  （`widgets/page_transitions_builder.dart`）。一旦有人顺手补上，旧页就会开始跟着动。
- **Hero 飞行没有独立时长**：`widgets/heroes.dart` 里 `_proxyAnimation.parent =
  manifest.animation`，飞行由路由动画驱动。所以把路由压到 180ms，封面飞行自动跟着变，
  两端不会各跑各的。

顺带纠正一个我原先也以为是的误解：**转场期间下面那页是被绘制的**。
`widgets/routes.dart` 的 `_handleStatusChanged` 在 `forward`/`reverse` 时把
`overlayEntries.first.opaque` 置为 **false**，转场结束才置回 `opaque`——所以淡入的新页底下
确实是那页静止的旧页面，不需要铺背景色（系统的 FadeForwards 铺 `backgroundColor` 是因为
它两页都在动、中间会透出底）。

**2. 共享元素铺到所有封面入口。**此前只有首页网格 → 详情一处，现在首页网格 / 榜单行 /
搜索结果 / 我的列表都套上了。两处硬约束：

- **标签必须带作用域**（`coverHeroTag(scope, id)`）。不能只用 `cover:{id}`：首页是
  `PageView`、榜单是 `TabBarView`，滑动时相邻两页**同时在树里**，而综合与真人剧、总热播与
  真人榜的内容高度重叠——同标签出现两个 Hero，Flutter 会抛「multiple heroes that share the
  same tag within a subtree」（`widgets/heroes.dart` 的 `_allHeroesFor`，在 assert 里，
  所以只在 debug 下炸）。详情页因此改成从 `extra` 拿标签（`DramaPreview`）。
- **首页「上次观看」卡刻意不给 Hero**：实测它显示的往往就是下面网格的第一张（真机截图上
  上次看的是「破晓」、网格首卡也是「破晓」），给了就会跟网格那张撞标签。网格是主路径。

**3. 列表行解码宽度 480 → 240。**`DramaCover` 原本对所有用法写死 `memCacheWidth: 480`，
而榜单行只显示 58dp（×3 = 174px）。按一遍正常使用算（首页四标签 72 张 + 榜单四榜 80 行），
解码内存约 **171 MB**，而 Flutter `ImageCache` 默认上限 **100 MB**——也就是说 LRU 一直在
挤图，往回滑时上面那几张可能早被挤掉、得重新解码。降到 240 后约 **92 MB**，落回上限以内。

代价与对法：列表行 240 而详情海报仍是 480，两端不是同一个缓存键，Hero 默认外壳取的是
**目的地**那一端（`heroes.dart` 的 `_defaultHeroFlightShuttleBuilder` 用 `toHero.child`），
那张 480 没被预热过，飞行一开始会先出灰块。所以加了 `coverFlightShuttle`：**用来源那一端
的图飞**（push 时是列表行、pop 时是详情页，都是「刚刚在看的那个」）。另外 `openDrama` 里
顺手把详情页要用的 480 也热一下——缓存键与 context 无关，所以在列表的 context 里热 480
一样能命中详情页那一次。

**4. 封面预加载（`lib/ui/cover_prefetch.dart`）。**要点全在「热到哪一层」：

- **必须热到内存，不能只热磁盘。**`CachedNetworkImage` 底下的 `octo_image` 在图片「同步
  可得」时走 `wasSynchronouslyLoaded` 分支，直接出图、**连占位与淡入都不放**
  （`octo_image` 的 `_placeholderBuilder`）。磁盘命中仍然是异步读盘 + 解码，仍然会看到灰底
  + `DramaCover` 那 220ms 淡入——所以 `downloadFile` 那类只落盘的预热解决不了这件事。
- **缓存键必须与组件完全一致**，否则白热。组件实际交出去的是
  `ResizeImage.resizeIfNeeded(memCacheWidth, null, CachedNetworkImageProvider(url))`，等价于
  `ResizeImage(provider, width: w)`；键 = provider + policy + width + height +
  allowUpscaling，而 `CachedNetworkImageProvider.obtainKey` 直接返回自己、
  `ImageConfiguration` 不参与——所以自己 resolve（用 `ImageConfiguration.empty`）就能命中，
  顺带把 `BuildContext` 从这条链路上拿掉了。
- **窗口跟着「已构建到的最大下标」走**，不去算滚动偏移：`SliverChildBuilderDelegate` 只构建
  可见区那几条，所以前缘天然就是它。2 列网格与单列列表因此共用一份实现。一屏半 ≈ 12 张、
  并发 3、页面 dispose 即停（在飞的不取消）。只铺在**首页四个标签 + 榜单**：搜索最多一屏、
  我的页是本地库且封面多半已在内存里，收益接近零。
- **不分网络、不加设置开关**。首页封面 24 KB/张、榜单 87 KB/张，一次会话滑十几屏也就几 MB。

**5. 「清除缓存」补上封面。**此前那行只清剧集缓存 + dio TTL + 榜单缓存，**完全没碰封面**
——而 `plan.md` 4a 已经立过「可重建的本地副本，清缓存就该一起清」这条口径（榜单缓存正是按
它加进去的）。现在两层都清：磁盘（`DefaultCacheManager`）与内存（`ImageCache`）。只清磁盘
的话，已经在内存里的封面照样显示，用户会以为没清掉。右侧那个数字也跟着改成
「剧集 N 个 · 合计字节」——它得能回答「按下去会腾出多少」。

**怎么验的**（写清哪些有证据、哪些没有）：

- `flutter analyze` 干净；`flutter test` **19 条全绿**，其中新增的
  `test/page_transition_test.dart` 走的是**真路由**：断言 `route.transitionDuration == 180ms`
  （这条同时证明主题里的 builder 真的被用上——查不到就会静默退回 Material 的 300ms）、
  90ms 时新页半透明且还低着、旧页位置一动不动、返回方向对称。
  `test/cover_prefetch_test.dart` 钉住预取窗口语义（只取前缘之后、越界跳过、不重排）。
- **真机**（Redmi `23013RK75C`，Android 15）：debug 跑起来，首页→详情 / 返回 / 首页→榜单
  三类跳转都发生，**日志里零异常**（尤其没有 multiple-heroes 那条断言）。
- **没验到的**：转场的**观感**在真机上没拍到——`adb shell screenrecord` 是变帧率的，那 180ms
  整个落在两个已发出帧之间（前后抽出来都是已落定的详情页）。所以「180ms 淡入上移」的结论
  来自 widget test + 源码，不是来自录像。预加载「灰底消失」的观感也还没眼过一遍。

**已发现、没做的一件**：Android 15（本机 API 35）上 `PredictiveBackPageTransitionsBuilder`
是**可选**的（`PageTransitionsTheme` 会把它当 Android 默认，但本仓库显式只映射了
`TargetPlatform.android` 那一格，且此前那格是 FadeForwards，所以预测式返回一直没启用）。
它能做到「侧滑返回时旧页跟着手指走」，是另一种「轻」，但要走它得改 manifest 的
`enableOnBackInvokedCallback`，而且与这一轮「旧页静止」的选择是两套手感——留给下一轮决定。

---

### 4c 第一版 release：图标与签名（已完成，真机装机核对过）

**产物**：`build/app/outputs/flutter-apk/app-release.apk`，**55.0 MB**，通用包
（arm64-v8a / armeabi-v7a / x86_64），`versionName=1.0.0 / versionCode=1`，
minSdk 24 / targetSdk 36，签名 `CN=onedrama`，**不是 debuggable**。
`INTERNET` 权限在 release 里也在（阶段 0 记过这个坑：Flutter 只往 debug 清单加它）。

**签名**：`android/key.properties` + `android/app/onedrama-release.p12`
（RSA 4096 / SHA384withRSA / 10000 天），两者都在 `.gitignore` 里。
`app/build.gradle.kts` 读 key.properties，**文件缺失就退回 debug 签名**——这样没拿到密钥的
人也跑得动 `flutter run --release`，不会因为缺文件而构建失败。

> ⚠️ **这两个文件必须另外备份一份**。丢了就签不出同一个包，届时装新版本只能先卸载——
> 而卸载会清掉 sqflite 里的收藏 / 历史 / 观看进度（`CONTEXT.md` 里这三样都是本地、
> 不同步的）。设备没 root，导不回来。

**图标：一张「已经画好的图标」撞上自适应掩膜。** `logo.png`（1254²，无 alpha）本身是一张
完整图标：烘死的圆角方 + 播放图形 + 下方的 `onedrama` 字标。踩的坑值得记：

第一版把它**整张铺满**自适应图标的背景层，真机上字标被切成「**nedram**」——左右各切一个
字母、底部也切。从截图反推：字标横跨画布 13.6%..87%，而**启动器只显示画布中间一部分**；
用字标在图标像素里的实际占比解出可见比例 ≈ **80%**（HyperOS / Android 15）。Android 定义的
**安全区是 72/108 = 66.7%**，是各家掩膜的公共子集。

**关键那条**：这张 logo 的**有效内容本身就横跨 13.6%..87%**——比安全区还宽——所以「铺满」
对它必然裁字标，不存在靠调参绕过的余地。改成**前景层 = 整张 logo 缩到 72/108 居中（四周
透明），背景层 = `@color/ic_launcher_background` `#FCFCFC`**。底色不是随手取的：`logo.png`
四个角实测就是 `#FCFCFC`（`ffmpeg crop=24:24,scale=1:1` 取样），与 logo 自带的圆角同色，
所以缩进留出来的那圈底**看不出接缝**——观感是留白，不是相框。

legacy 五张（`mipmap-*/ic_launcher.png`）**刻意保持整张铺满**：Android 8 以下没有自适应
掩膜、不会被裁，铺满反而更好看。两条路各自最优，而且没有设备会同时看到两者。

**怎么验的**：`aapt2 dump resources` 确认 `mipmap/ic_launcher` 有五档 PNG + `anydpi-v26`
XML、`mipmap/ic_launcher_foreground` 五档 PNG、`color/ic_launcher_background` = `#fffcfcfc`；
`apksigner verify --print-certs` 确认签名是我们那把；真机上卸掉 debug 包、装 release、
启动后日志零异常；启动器图标放大逐像素看过——修前 `build/shots/verify-05-icon-zoom.png`、
修后 `verify-07-icon-zoom-fixed.png`。

### 4c 之后的第二次打包：**1.1.0+2**（阶段 5 的三个功能）

`flutter build apk --release` → `build/app/outputs/flutter-apk/app-release.apk`，**55.2 MB**，
同样挪一份到仓库根 `onedrama-1.1.0-release.apk`。签名与清单逐项核对过：

| 项 | 值 |
| --- | --- |
| 签名 | `CN=onedrama, O=onedrama, C=CN`（同一把密钥，SHA-256 `77dda365…`） |
| 版本 | `versionName=1.1.0` / `versionCode=2` |
| SDK | minSdk 24 / targetSdk 36 / compileSdk 36 |
| 架构 | 通用包 `arm64-v8a` `armeabi-v7a` `x86_64` |
| 权限 | `INTERNET` / `ACCESS_NETWORK_STATE` / `WAKE_LOCK` / `DYNAMIC_RECEIVER_NOT_EXPORTED` |
| 可调试 | **否**（清单里没有 `application-debuggable`） |

**与 1.0.0 的差异只有版本号两处**——权限、SDK 级别、原生架构逐项 `aapt dump badging` 比过，
一模一样。

> ⚠️ **装之前先想一下**：手机上现在装的是 `flutter run --debug` 那个**调试包**，与 release 包
> 签名不同，装 release 必须**先卸载**——本机的收藏 / 历史 / 观看进度、剧库快照、搜索历史会
> 一起没（风险 6 / 7 那两条说的是同一件事）。要避免下次再发生，见「环境备注」里那条：
> 让 debug 变体也用 release 密钥签（改 `android/app/build.gradle.kts` 四行）。

---

## 阶段 5 — 搜索记忆 / 剧库导入 / 下一集预取（设计已定，未开工）

三件事各自独立，口径见下；两处有 ADR 的地方在表中标了。

### 5a 搜索记忆

只记**搜过的词**。手打回车与点联想项入历史；首页题材 chip 跳转不入——那是浏览，代码注释里就写了 chip 是快捷搜索词而不是筛选器。

- [x] 存 prefs（与设置、榜单缓存同一套「小、整块、可重建」口径，不建表）：上限 **20** 条，重复的词**提到最前**
- [x] 空输入时「最近搜索」在上（标题右侧「清空」，**长按单条删**），「热门搜索」10 个 chip 在下——现在那一屏只有后者（`search_page.dart:315`）
- [x] 设置「剧库与存储」加一行**清空搜索历史**
- [x] **不做**「重进搜索页恢复上次结果」：搜索页仍是 `push` 的整页，退出即销毁

**实现时才定下的两处细节：**

- **哪些搜索算「搜过」是按入口分的**：手打回车、点联想项、点历史词与热门词都记；**唯一不记的是从首页题材 chip 跳进来的那一次**（`initialKeyword` 那条路）。判断依据是入口而不是词——同一个词从首页 chip 点进来是「浏览」，在搜索页里点它是「搜」。
- **长按删单条给了「撤销」**。长按是误触重灾区，而删掉的那条找不回来；撤销用 SnackBar 的 action，八行代码。

**没验到的**：这一屏在 `参考的前端页面/` 六张里**没有参考图**（那六张是设置 / 我的 / 播放 ×2 / 首页 / 详情），所以「最近搜索在上、热门在下」以及长按删的交互都是自由设计，没有可核对的依据。

**真机验证**：
- `flutter.search_history` 落盘为 `["甜宠"]`（点热门词触发）——记词与持久化都对。
- 重新进搜索页：「最近搜索：甜宠」在上、右侧带「清空」，热门搜索在下，与口径一致。
- **「首页题材 chip 跳转不入历史」这条我没验成**：adb 驱动的点击序列错了（第一条 BACK 只收了键盘，后续点击落在搜索页上），所以那一步没真正执行。以使用者手测为准。

### 5b 更新剧库（[ADR-0008](adr/0008-library-snapshot-on-every-launch.md)）

- [x] 启动后**异步**拉四个一级标签各 5 页（`limit=18`，共 360 部、20 次签名请求）写进新表 `library_entries`，按 `(标签, 名次)` 存；**不阻塞首帧**（推到第一帧之后，不 await）
- [x] 建库版本 **1 → 2**：只加表，`onUpgrade` 不动老数据——收藏 / 历史 / 进度是用户数据，不该为一张可重建的表重建库
- [x] 首页改**本地优先**：本地有就立刻渲染（**一个请求都不等**）；本地为空（首装 / 刚清缓存）照旧走网络
- [x] 封面一起落盘（并发 4，约 8.6 MB）——否则断网时首页是一排灰块，只有剧名
- [x] 每次**整批覆盖**，不累积；替换在**一个事务**里，不留半新半旧
- [x] 某个标签失败只保留该标签旧数据，其余照常替换；四个标签全挂就不推「上次更新」时间戳
- [x] **「更新剧库」是快照的唯一写入者**。滑到底翻页只进内存；下拉刷新**也只进内存**（理由见下）
- [x] 设置「剧库与存储」加「更新剧库」行：右侧显示进度或「3 分钟前更新」，空闲时可手动再跑；启动时那一轮与手动那一轮会**合成一轮**
- [x] 「清除缓存」连快照一起清，并忘掉时间戳（快照都没了还显示「刚刚更新」就是骗人）；**不清**搜索历史
- [x] 断网边界：只保首页看得见，详情页给说清原因的错误态，**不做**分集列表缓存
- [x] 顺带把 `LibraryTab` / `libraryTabs` 从 `ui/library_page.dart` 挪到 `data/library_tabs.dart`，分页游标抽成 `data/catalog_pager.dart`

**两处与原设计的偏离，都是实现时才看清的：**

1. **后台那一趟不整页替换**，改成「只把没见过的插到最前，已有的一律不动」。原写的是「拉到就替换」，但「综合」走的是推荐流——每页都不一样——整页换会让用户眼前的列表自己跳一次。本地为空时这一页才当首屏用。
2. **下拉刷新不落盘**。原写的是「导入与下拉刷新写本地」，可下拉刷新只拉得回 18 条，落盘会把另外 72 部离线可看的剧删掉，那不是用户按这个手势想要的结果。

**为什么要挪 `LibraryTab`**：快照按标签在 `libraryTabs` 里的**下标**存（`library_entries.tab`），导入器与首页各持一份顺序迟早会错位，而错位的症状是「真人剧那个标签里全是漫剧」，很难一眼归因。

既有的两处不动：综合标签传的是 `genre: 'short_play'`（现在在 `data/catalog_pager.dart`）；推荐接口的 `seen` 去重上限 540（`catalog.dart:309`），所以「拉到底」本来就不成立。

**真机验证**：

| 验的什么 | 证据 |
| --- | --- |
| 导入跑通 | `[library] 导入完成 · 296 部 · 逐标签 0:90 1:85 2:85 3:36 · 封面 277 张 · 19s` |
| 建库 **1 → 2** 迁移 | 同签名覆盖安装后正常启动，收藏 / 历史 / 进度未受影响（`onUpgrade` 只建表） |
| **断网冷启动** | `svc wifi/data disable` 真断网（`ping: Network is unreachable`）→ 冷启 → 首页**完整出图**、封面一张不少、连「上次看到第 7 集」卡都在 |
| 离线导入优雅失败 | `0 部 · 逐标签 0:-1 1:-1 2:-1 3:-1 · 12s`，**旧快照保留**，首页照常可刷 |
| 设置行 | 「剧库与存储」组内第一行「更新剧库 · 刚刚更新」，跑的时候显示 `导入剧库 n/20` / `缓存封面 n/360` |

**一处真机踩到的坑（记在环境备注里了）**：`adb shell cmd connectivity airplane-mode enable` 在 HyperOS 上**只改状态、不断网**（`ping` 照样通），所以第一版「断网测试」是假证据。真能断的是 `svc wifi disable` / `svc data disable`。

**没验到的**：
- 「下拉刷新只改内存、不落盘」只有代码与注释层的一致，没在真机上专门核对过。
- 单标签失败保留旧数据（`-1` 分支）在真机上只验到「四个标签全失败」这一种；只挂一个标签的情形没造出来。
- 首页滑到底继续走网络分页也没单独取证（改动的是同一条 `_pull`，但方向不同）。

### 5c 下一集预取（[ADR-0009](adr/0009-prefetch-next-episode-as-a-whole-file.md)）

- [x] 当前集开始播放后**立刻**开始，后台把**下一集整集下完并解密落盘**（复用 `prepareEpisode`）
- [x] `_prepare` 主路径改为「本地有 `cenc_<vid>.mp4` 就播文件，没有才流式」
- [x] 设置「播放」组加一行**预缓存下一集**，与「自动播放下一集」**解耦**（关掉连播仍预取，因为可能手动点下一集）
- [x] 只留**最近 10 集**（约 146 MB），更早的按文件时间删
- [x] 预取中切集：该集走流式，预取继续跑完；退出播放页取消预取
- [x] 不限网络（不加 `connectivity_plus`），用流量这件事交给那个开关

**收益实测（同一台真机、同一次会话）**：

| 集 | `setMedia` 模式 | `STATE_READY` |
| --- | --- | --- |
| 未预取（流式） | `mode=stream-decrypt keyLen=16` | 828 / 1812 ms |
| 预取过（本地文件） | `mode=off keyLen=0` `file://…cenc_<vid>.mp4` | **205 / 206 / 179 ms** |

预取本身：`[prefetch] 第 N 集就绪 · 1080P · 8215858 字节 · 4794ms`（一集 6.6–18.8 MB，实测 2.5–4.8 秒）。
旁挂落盘正确（`version 1 / picked 1080 / 1080×1920 / 带密钥`，一集一份 `.json`，无 `.part` 残留）。
关掉开关后 `prefetch` 日志 **0 条**，说明它真的接线了。

**过程中改过一版口径，值得记**：原设计是「开播后等 10 秒再预取」（怕点进去看一眼就退的人白下 14.6 MB）。**真机反馈否掉了它**——人往往看十来秒就往下切，等 10 秒才开始等于 13–14 秒才就绪，切集照样等加载。改成开播即开始（见 ADR-0009 的 Consequences）。

**顺带抓出的两个既有 bug**（都在这次要改的那段代码里，没另开一轮）：

1. **设了「优先画质」具体档位后，「画质」面板打不开**。`_pickVariant` 返回的是 `media.variants` 里的元素，而那个元素**自己的 `variants` 是空的**（`selectAppMedia` 就是这么构造的）；`_showQualities` 见空即返回，于是按钮点了没反应。改为把完整档位列表挂回去。
2. **面板里当前档的那个勾永远不出现**（自动时）。`Media` 没有值相等语义，而当前项与列表项是两次构造出来的，`_pick` 的身份比对恒为 false。改为**按档位比**。

**没验到的**：淘汰「留最近 10 集」在真机上没走到（要连看 11 集）——它由 4 条单测覆盖（临时目录），真机这条只到「文件按预期落盘」为止。退出播放页取消在飞的预取也没单独取证。

### 怎么验

- `flutter analyze` 干净；`flutter test` 现有 19 条全绿。
- 新增单测：搜索历史的去重 / 上限 / 顺序（纯函数）；预取淘汰「留最近 10 集」（临时目录）。
- **sqflite 在单测里跑不了**，所以剧库快照的读写与覆盖事务只能真机验——这条会诚实标注。
- 真机：导入 20 个请求的实际耗时；冷启动首页是否本地渲染；飞行模式下刷首页；切集日志里的 `STATE_READY` 前后对比。
- **没参考可核的**：`参考的前端页面/` 六张里没有搜索页，5a 的空态是自由设计。

---

## 风险

| # | 风险 | 何时暴露 | 应对 |
| --- | --- | --- | --- |
| 1 | CENC 密钥注入做不成 | 阶段 1 第 4 步 | 有明文兜底；UI 明确标注禁用 |
| 2 | Dart 签名对不上 Go 向量 | 阶段 1 第 1 步（最早） | golden vectors + fixtures |
| 3 | 网页 `_ROUTER_DATA` 结构变化 | 分类 / 搜索 / 榜单一起挂 | fixtures 能让它测红 |
| 4 | App 签名协议变更 | 随时 | 无法预防，只能跟 |
| 5 | 第三方备用域名不稳定 | 随时 | 只是兜底，挂了不影响主路 |
| 6 | 签名密钥（`android/app/onedrama-release.p12` + `android/key.properties`）丢失 | 下次装新版本时 | 已 gitignore，**必须另外备份一份**；真丢了只能卸载重装，本地收藏 / 历史 / 观看进度一起没（设备没 root，导不回来） |
| 7 | **`flutter run`（默认 debug）会先卸载已装的 release 包** | 每次想在真机上取日志时 | 已发生一次：本机收藏 / 历史 / 观看进度全丢。原因见下，对策是改用 `flutter run --release` |

## 不在本计划内

- 账号 / 云同步（协议包里已明确删除，要重做得再逆向一套）
- 弹幕（另一套 `X-Argus` / `X-Ladon` 签名，v1 不做）
- 离线下载（原项目靠 FFmpeg 解 CENC）
- 公开发 APK（见 [ADR-0004](adr/0004-all-three-media-resolution-paths.md)）
