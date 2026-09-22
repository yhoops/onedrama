/// 首页的一级标签。
///
/// 放在数据层而不是页面里：**剧库快照按这个列表的下标存**（`library_entries.tab`），
/// 导入器与首页必须共用同一份顺序——各写一份迟早会错位，而错位的症状是「真人剧那个
/// 标签里全是漫剧」，很难一眼归因。
library;

/// 一个一级标签。`genreKey` 为 null 表示「综合」——走推荐接口，而不是分类接口。
class LibraryTab {
  const LibraryTab({required this.label, this.genreKey, this.scene});

  final String label;
  final String? genreKey;
  final String? scene;

  /// 分类标签（真人剧 / 漫剧 / AI剧），相对「综合」而言。
  ///
  /// 综合走推荐接口，实测连拉两次第 1 页只有约六成重叠——它不是一份「剧库内容」，
  /// 是一份会转的推荐。另外三个走分类接口、按 `online_time` 排序，是确定性的。
  ///
  /// **剧库部数与「本次新增」只算分类标签**：把综合算进去，那个数字会常年顶在几十部，
  /// 而上游其实一部都没上。见 `CONTEXT.md` 的 Library Count / Newly Added。
  bool get isCategory => genreKey != null;
}

const List<LibraryTab> libraryTabs = <LibraryTab>[
  LibraryTab(label: '综合'),
  LibraryTab(label: '真人剧', genreKey: 'short_play', scene: 'default'),
  LibraryTab(label: '漫剧', genreKey: 'comic_series', scene: 'comic_series'),
  LibraryTab(label: 'AI剧', genreKey: 'ai_series', scene: 'ai_series'),
];

/// 分类标签的下标。剧库部数与「本次新增」按它取（见 [LibraryTab.isCategory]）。
List<int> get categoryTabIndexes => <int>[
  for (var index = 0; index < libraryTabs.length; index++)
    if (libraryTabs[index].isCategory) index,
];
