# 组件规范

> 参考 `lib/ui/widgets/` 与各页里的私有子件。

---

## 结构

- 默认 `StatelessWidget`；需要动画/生命周期才升 `StatefulWidget`，需要读 provider 才用 `ConsumerWidget`/`ConsumerStatefulWidget`。
- 构造一律 `const` + `super.key`。
- 参数：**必填数据 + 可选回调**。回调 `VoidCallback?`，`null` 表示「此处不可点」——`Pressable` 据此不做任何反馈（`onTap == null`）。
- 大 `build()` 拆成一组私有 `StatelessWidget`（`_Header`/`_MetaRow`…），**不是**返回 `Widget` 的 helper 方法。这是 `detail_page`/`player_page` 的主导做法，拆出来的件各自 `const`、职责单一。

---

## 可点面：用 `Pressable`，不用 `InkWell`

`widgets/pressable.dart` 是统一的可点面（按下缩放 + 可选震动），因为水波纹要 `Material` 祖先、常被不透明底色盖住。缩放幅度/时长取 `OneDramaSizes.pressScale`/`pressDuration`。震动**必须**再过一遍设置里的「触感反馈」开关（`Pressable` 内部已 `ref.read(settingsProvider).hapticFeedback`），别开绕过它的路径。

---

## 不写死颜色 / 尺寸

`build()` 第一行取 `final palette = OneDramaColors.of(context)`，之后只用它的字段；圆角/间距/时长取 `OneDramaSizes`。**深色色值照红果参考截图取样**（`theme.dart`），直接写死 `Color(0x...)` 会让深色模式失效。播放页是唯一例外：整页固定深色，用 `playerAccent`。

---

## 封面与 Hero

- 封面统一走 `DramaCover`（带磁盘缓存、限解码宽度：网格/详情 `gridCoverWidth=480`、列表行 `rowCoverWidth=240`）。
- 列表进详情统一 `openDrama(context, drama, heroTag: ...)`——它顺手预热详情页那档封面。
- Hero 标签用 `coverHeroTag(scope, id)`，`scope` 含「页面+标签页」：`PageView`/`TabBarView` 滑动时相邻两页同时在树里，同标签会撞「multiple heroes share the same tag」（回归测试 `test/cover_prefetch_test.dart`）。

## 装饰盒在 `Wrap` / `Row` 里会被撑满

chip 那类「依内容定宽的小药丸」**不要**写 `Container(alignment: ...)`：`alignment` 会让 Container 尽可能大，在 `Wrap`（宽度有界）里就变成每个占一整行、竖着排。`Row` 里配 `Expanded` 同理——撑开的是外框，装饰盒不跟着走（`plan.md` 3c 记过这个 bug）。

```dart
// 好：依内容定宽，Wrap 里正常换行
Container(padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11), decoration: ..., child: Text(label))

// 坏：在 Wrap 里被撑满整行
Container(alignment: Alignment.center, padding: ..., child: Text(label))
```

---

## 可达性

`Pressable` 支持 `semanticLabel`（包 `Semantics(button: true)`）。大字模式在 `main.dart` 用 `MediaQuery.withClampedTextScaling` 统一处理，页面无需各自适配。
