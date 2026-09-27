# 题材筛选：跨层契约

> 首页「短剧库」按题材筛选短剧的完整契约。跨协议层 → 数据层 → UI 三层，改任一处都要照这里核。

---

## 1. 触发场景

在真人剧 / 漫剧 / AI剧 一级标签下按**官方题材**（古装 / 悬疑 / 爱情 …）筛选短剧。题材数据**只在网页接口里有**，App 接口没有——这是本契约最反直觉的一点。

---

## 2. Signatures

```dart
// packages/hongguo_dart/lib/src/catalog.dart
class CategoryTheme { const CategoryTheme(this.id, this.name); final String id; final String name; }

const Map<String, List<CategoryTheme>> categoryThemes;   // key = 网页路由（real-drama / comic-drama / ai-drama）
List<CategoryTheme> themesForWebRoute(String webRoute);  // 未知路由（含综合的空串）→ 空列表
String themedCategoryRoute(String webRoute, String themeId); // 校验后拼 '<webRoute>/<themeId>'

// 取数直接复用既有那条（route 传带斜杠的串即可，解析零改动）
Future<({List<Drama> dramas, int page, int totalPages})> fetchWebCategoryPage({
  required String route, required String category, int page = 1,
});

// lib/data/library_filter.dart —— 本地筛/排（与服务端题材无关）
List<Drama> applyLibraryFilters(List<Drama> src, {
  LibraryStatus status, bool withinSixty, LibrarySort sort,
});
```

---

## 3. Contracts

**服务端题材筛选 = 路径段，不是 query。**

| 项 | 值 |
| --- | --- |
| URL | `GET {webBase}/category/<内容类型>/<selector_item_id>`（第 1 页不带 `?page`，其后 `?page=N`） |
| 内容类型 | `real-drama` / `comic-drama` / `ai-drama`（映射表 `appGenreWebRoutes`） |
| 题材词表 | 网页分类页 loader 的 `selectorList[].items[]`：`show_name`（显示名）/ `selector_item_id`（路径值）/ `category_json_ids` |
| 真人剧题材 | 24 项；**漫剧与 AI剧共用同一套 8 项** |
| 免签名 | 是（走 `fetchText`，与其它网页分类一致） |
| 分页 | `?page=N`，`pagination.totalPages ≈ 34`，24 条/页 |

**题材只走网页**：App 分类接口 `/reading/distribution/category/landpage/v/` 的列表行 **`tags` 为空**，且 `need_selector_panel:true`（配多种 `req_type`）**不返回词表**。它的 `select_items.category_dim_theme` 维度是活的（传值结果变 0 条），但 App 侧题材 ID 词表不外露——所以**不能**用它做筛选。

**综合标签不能筛**：走 App 推荐流，网页无等价物。

**本地筛/排**（状态 / 篇幅 / 排序）是**展示层变换**，叠在已加载的 `dramas` 上，不落盘、不影响服务端分页。

---

## 4. Validation & Error Matrix

| 条件 | 行为 |
| --- | --- |
| `themeId` 不在该内容类型词表内 | `themedCategoryRoute` 抛 `HongguoRequestException`（**不**静默拼一个不存在的路径） |
| 题材属于另一内容类型（如漫剧传 `costume`） | 同上抛错 |
| `webRoute` 为空（综合） | `themesForWebRoute` 返回空列表 → UI 不渲染题材段；调用方不该拼路径 |
| 网页返回空 `recommendList` | `exhausted = true`（到底），不无限翻 |
| 排序键缺失（网页源无 heat/views/onlineDate） | 该项**排在最后**，不当 0 混入 |
| 本地条件筛空 | UI 给「没有符合筛选条件的短剧」占位，不是网络错误态 |

---

## 5. Good / Base / Bad

- **Good**：真人剧选「古装」→ 服务端返回该题材全量、可翻页；再叠「已完结 + 集数少优先」→ 本地过滤排序，缺集数的沉底。
- **Base**：不选题材 → App 源 + 本地快照优先，行为与改动前逐字一致。
- **Bad**：拿 App 分类接口的 `tags` 去本地筛题材——列表行根本没有 tags，结果恒为空；或在综合标签拼 `/category//xxx`。

---

## 6. Tests Required

| 测试 | 断言点 |
| --- | --- |
| `packages/hongguo_dart/test/category_theme_test.dart` | 三类词表齐、id 唯一非空、真人剧 24 项、漫剧=AI剧；`themedCategoryRoute` 校验并抛错；**(LIVE=1)** 硬编码词表与 live `selectorList` 逐 id 一致（防上游增删题材后 stale） |
| `test/catalog_filter_test.dart` | 带 `filterRoute` 的 pager **只**打 `/category/<type>/<theme>`、页码递增、绝不落到 App `landpage`；翻到 totalPages 停 |
| `test/library_filter_test.dart` | 状态/篇幅过滤；各排序键；**缺数据排最后**；键相等时稳定；过滤+排序组合 |

---

## 7. Wrong vs Correct

#### Wrong —— 把题材当 App 接口能力 / 用 query 传题材

```dart
// App 列表行没有 tags，恒筛空
dramas.where((d) => d.tags.contains('古装'));

// 网页 query 一律不生效（实测 404 或与基线完全重叠）
'$webBase/category/real-drama?category_json_ids=5000';
'$webBase/category/real-drama?topic=costume';
'$webBase/category/costume';           // 题材当聚合路由 → 404
```

#### Correct —— 题材是网页的**路径段**

```dart
final route = themedCategoryRoute(tab.webRoute, 'costume'); // 'real-drama/costume'
await client.fetchWebCategoryPage(route: route, category: tab.label, page: 1);
```

---

## 附：两个踩过的坑

### 坑 1：`Container(alignment:)` 放进 `Wrap` 会被撑满整行

浮层里的题材 chip 最初写成 `Container(alignment: Alignment.center, ...)`，在 `Wrap`（宽度有界）里 `alignment` 会让 Container **尽可能大**，于是每个 chip 占满一整行、竖着排，而不是换行的小药丸。

**Fix**：去掉 `alignment`，让 Container 依内容定宽（内层 `Text` 自己撑高）。同样的写法在 `Row` 里也危险——`Row` 的 `Expanded` 撑开的是外框、装饰盒不跟着走（见 `plan.md` 3c 里那条）。

### 坑 2：信息流在飞的请求会跨筛选状态污染

`LibraryFeed` 的 `ensureLoaded`（await 数据库）与 `_pull`（await 网络）都可能跨过一次题材切换：前者会把**未筛选的整份快照**并进筛选结果，后者会把**旧 pager 拉回的一页**并进来。症状是「偶发的错内容 / 看起来空白」。

**Fix**：两处都记下调用时的 `_pager`，`await` 回来后用 `identical(_pager, pagerAtStart)` 判断，变了就整批丢弃。**改 `LibraryFeed` 的异步流程时保持这个守卫。**

> **与 ADR-0013 的关系**：题材筛选态是「网页源」，但它**不是** `_webMode` 那套「App 断腿才降级」。带 `filterRoute` 的 pager 一开始就走网页，不做降级判断——别把两条机制混起来。
