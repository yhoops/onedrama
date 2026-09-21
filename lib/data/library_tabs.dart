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
}

const List<LibraryTab> libraryTabs = <LibraryTab>[
  LibraryTab(label: '综合'),
  LibraryTab(label: '真人剧', genreKey: 'short_play', scene: 'default'),
  LibraryTab(label: '漫剧', genreKey: 'comic_series', scene: 'comic_series'),
  LibraryTab(label: 'AI剧', genreKey: 'ai_series', scene: 'ai_series'),
];
