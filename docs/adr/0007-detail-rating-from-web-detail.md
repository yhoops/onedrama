# 评分只能从网页详情拿，代价是详情页多发一次网页请求

App 详情接口（`/novel/player/video_detail/v1/`）**根本没有评分**：返回的 39 个字段里，键名含 `score` / `rating` / `heat` / `hot` 的只有一个 `hot_score`，深挖两层也没有别的，实测 11 部剧全部如此。评分只存在于网页详情的 `loaderData.detail_page.seriesSocialInfo.rating`（注意它与 `seriesDetail` 是**同级**字段，不在它里面）。为了一个 `9.2分`，详情页因此要额外发一次网页请求（约 290 KB，免签名；`/detail` 已在 `lib/data/network.dart` 的 TTL 缓存白名单里，同一部剧 5 分钟内只拉一次）。

呈现上是**渐进**的：主体（封面 / 标题 / 选集）先渲染，评分到了再补一个 chip；约 40% 的剧**本来就没有评分**（实测 5 部里 2 部），那些剧该 chip 不出现——缺失是正常的，不是失败。

## Considered Options

- **不做评分**（现状）：改动最小，但用户提的「缺少评分」这条不算解决。
- **用榜单的 `scoreText` 补**（`评分9.0`）：不用新请求，但只对上了榜的剧有效（4 榜 × 20 条），而且详情页的数字会来自另一个接口——同一个数字两个来源迟早打架。
- **移植 Go 的整套网页详情兜底**（`hongguo/detail.go` 的 `FetchDetail`，还带分集列表）：能拿到更多字段，但详情页已经有更好的 App 分集数据，为评分搬一整套不值得。

## Consequences

- 详情页多一条网络依赖，但它**不在关键路径上**：`fetchWebSocialInfo` 把异常吞掉返回零值，失败就当没有，不会让页面出错。
- **网页那一份优先，`drama.score` 只作兜底。**顺序不能反：从榜单点进来时，`preview.score` 是榜单的 `scoreText`（`9.0`），而网页给的是这部剧自己的 `9.2`——两者都叫「评分」却不保证相等。先显示前者、等后者到了再换掉，就是同一个数字两个来源打架，用户会看到数字跳一下。只认网页那一份，它给不出（约 40% 的剧没有评分）才退回已有的 `score`。
- **热度不需要走这条路**：App 响应里的 `hot_score` 与网页的 `hot_score_data.text` 口径一致（`42033495` 两边都是 `4203万`），本地按同一口径格式化即可（`lib/ui/format.dart`）。所以只有评分值得那次请求。
- 只搬一个**窄函数**而不是整套详情解析：`hongguo/detail.go` 的 `ParseWebSocialInfo` 与 Dart 的 `parseWebSocialInfo` 同步实现（[ADR-0003](0003-go-package-as-protocol-truth-with-fixtures.md) 要求两边一致）。
- 换来一条领域知识，已写进 `CONTEXT.md`：**Rating 只有网页接口有，View Count 只有 App 接口有**。以后想「合并成一个详情请求」的人会先撞上这条。
