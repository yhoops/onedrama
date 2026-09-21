/// JSON 字段读取与领域模型。对照 Go `hongguo/helpers.go`、`hongguo/parse.go`。
library;

import 'dart:convert';

import 'ids.dart';

/// 取第一个非空字符串（去空白后）。对照 Go 的 `firstNonEmpty`。
String firstNonEmpty(List<String> values) {
  for (final value in values) {
    final text = value.trim();
    if (text.isNotEmpty) return text;
  }
  return '';
}

/// 按 key 顺序取第一个可用值。
///
/// 与 Go 的 `mapString` 一致：字符串要非空才算命中；`bool`、数字一旦遇到就返回
/// （即使是 `false`）；其它类型跳过、继续看下一个 key。
String mapString(Map<String, dynamic>? source, List<String> keys) {
  if (source == null) return '';
  for (final key in keys) {
    if (!source.containsKey(key)) continue;
    final value = source[key];
    if (value is String) {
      final text = value.trim();
      if (text.isNotEmpty) return text;
    } else if (value is bool) {
      return value.toString();
    } else if (value is int) {
      return value.toString();
    } else if (value is double) {
      if (value.isFinite && value == value.truncateToDouble()) {
        return value.truncate().toString();
      }
      return value.toString();
    }
  }
  return '';
}

/// 取字符串列表：按 `,` `/` `，` `、` 切分，去重保序。
///
/// 对照 Go 的 `mapStringSlice`。
List<String> mapStringSlice(Map<String, dynamic>? source, List<String> keys) {
  final seen = <String>{};
  final out = <String>[];
  void add(String value) {
    final text = value.trim();
    if (text.isNotEmpty && seen.add(text)) out.add(text);
  }

  if (source == null) return out;
  final separator = RegExp(r'[,/，、]');
  for (final key in keys) {
    if (!source.containsKey(key)) continue;
    final value = source[key];
    if (value is String) {
      for (final part in value.split(separator)) {
        add(part);
      }
    } else if (value is List) {
      for (final item in value) {
        add(item.toString());
      }
    }
  }
  return out;
}

/// 沿 [keys] 取嵌套 map。`keys` 为空时就是把 [value] 当 map 取。
///
/// 对照 Go 的 `nestedMap`。
Map<String, dynamic>? nestedMap(Object? value, List<String> keys) {
  var current = value is Map<String, dynamic> ? value : null;
  for (final key in keys) {
    if (current == null) return null;
    final next = current[key];
    current = next is Map<String, dynamic> ? next : null;
  }
  return current;
}

/// 取列表：本来就是数组就直接用；是 map 就在 `list` / `items` / `data` 里找。
///
/// 对照 Go 的 `anyList`。
List<Object?> anyList(Object? value) {
  if (value is List) return value;
  if (value is Map<String, dynamic>) {
    for (final key in const ['list', 'items', 'data']) {
      final nested = anyList(value[key]);
      if (nested.isNotEmpty) return nested;
    }
  }
  return const [];
}

final RegExp _dateText = RegExp(r'\d{4}-\d{1,2}-\d{1,2}');
final RegExp _finishedEpisodeRemark =
    RegExp(r'(?:全\s*\d+\s*集|\d+\s*集全|已完结|大结局)');

String _formatDate(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

/// 从文本里挑出第一个合法日期。对照 Go 的 `normalizeDate`。
String normalizeDate(String value) {
  final text = value.trim();
  if (text.isEmpty) return '';
  for (final match in _dateText.allMatches(text)) {
    final parts = match.group(0)!.split('-');
    if (parts.length != 3) continue;
    final year = int.tryParse(parts[0]);
    final month = int.tryParse(parts[1]);
    final day = int.tryParse(parts[2]);
    if (year == null || month == null || day == null) continue;
    if (year < 2000 || year > 2100 || month < 1 || month > 12) continue;
    if (day < 1 || day > 31) continue;
    return _formatDate(DateTime(year, month, day));
  }
  return '';
}

/// 把秒或毫秒时间戳转成北京时间的日期。对照 Go 的 `timestampDate`。
String timestampDate(String value) {
  final stamp = int.tryParse(value.trim());
  if (stamp == null || stamp <= 0) return '';
  final seconds = stamp > 100000000000 ? stamp ~/ 1000 : stamp;
  final date = DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true)
      .add(const Duration(hours: 8));
  if (date.year < 2000 || date.year > 2100) return '';
  return _formatDate(date);
}

/// 从 `episode_right_text` 之类的话术推断完结状态。
///
/// 对照 Go 的 `releaseStatusFromRemark`。
String releaseStatusFromRemark(String remark) {
  if (remark.contains('未完结') ||
      remark.contains('更新至') ||
      remark.contains('连载')) {
    return 'ongoing';
  }
  if (_finishedEpisodeRemark.hasMatch(remark) || remark.contains('完结')) {
    return 'finished';
  }
  return 'unknown';
}

/// 热度。对照 Go 的 `Heat`。
String dramaHeat(Map<String, dynamic> row) {
  final hot = nestedMap(row['hot_score_data'], const <String>[]);
  final score = firstNonEmpty([
    mapString(hot, const ['score']),
    mapString(row, const ['hot_score']),
  ]);
  if (score.isNotEmpty) {
    final value = double.tryParse(score);
    if (value != null && value >= 0 && value.isFinite) return score;
  }
  return mapString(hot, const ['text']);
}

/// 副标题文案（「今日上新」「红果热度值4203万」这类）。对照 Go 的 `subtitleLabels`。
///
/// **两种形状都认**：App 详情给的是 `series_sub_title_list`（纯字符串数组），网页给的
/// 是 `sub_title_list`（对象数组，文案在 `content` 里）。此前只读后者，于是 App 路径上
/// [dramaOnlineDate] 永远走不到这一段——两边的键名一度都写错了。
List<String> subTitleLabels(Map<String, dynamic> row) {
  final out = <String>[];
  for (final key in const ['series_sub_title_list', 'sub_title_list']) {
    for (final value in anyList(row[key])) {
      final label = mapString(
        nestedMap(value, const <String>[]),
        const ['content'],
      );
      if (label.isNotEmpty) {
        out.add(label);
        continue;
      }
      if (value is String) {
        final text = value.trim();
        if (text.isNotEmpty) out.add(text);
      }
    }
  }
  return out;
}

/// 上线日期。对照 Go 的 `OnlineDate`。
String dramaOnlineDate(Map<String, dynamic> row, DateTime now) {
  final stamp = timestampDate(mapString(row, const ['first_visible_time']));
  if (stamp.isNotEmpty) return stamp;
  final today = now.toUtc().add(const Duration(hours: 8));
  for (final label in subTitleLabels(row)) {
    if (label == '今日上新') return _formatDate(today);
    if (label == '昨日上新') {
      return _formatDate(today.subtract(const Duration(days: 1)));
    }
    if (label.endsWith('上新')) {
      final date = normalizeDate(label);
      if (date.isNotEmpty) return date;
    }
  }
  return '';
}

/// 一部短剧。
class Drama {
  const Drama({
    this.id = '',
    this.source = '',
    this.sourceId = '',
    this.title = '',
    this.name = '',
    this.desc = '',
    this.intro = '',
    this.cover = '',
    this.coverUrl = '',
    this.categoryName = '',
    this.channelName = '',
    this.remark = '',
    this.totalEpisode = '',
    this.episodeCount = '',
    this.tags = const <String>[],
    this.releaseStatus = '',
    this.score = '',
    this.views = '',
    this.heat = '',
    this.onlineDate = '',
  });

  final String id;
  final String source;
  final String sourceId;
  final String title;
  final String name;
  final String desc;
  final String intro;
  final String cover;
  final String coverUrl;
  final String categoryName;
  final String channelName;
  final String remark;
  final String totalEpisode;
  final String episodeCount;
  final List<String> tags;
  final String releaseStatus;
  final String score;
  final String views;
  final String heat;
  final String onlineDate;

  /// 展示用标题。与 Go 的 `DisplayTitle` 一致：Title → Name → 「短剧」。
  String get displayTitle {
    if (title.trim().isNotEmpty) return title;
    if (name.trim().isNotEmpty) return name;
    return '短剧';
  }

  /// 从 [toJson] 的输出还原。用于持久化快照（收藏、历史）后读回。
  factory Drama.fromJson(Map<String, dynamic> json) => Drama(
        id: json['id'] as String? ?? '',
        source: json['source'] as String? ?? '',
        sourceId: json['sourceId'] as String? ?? '',
        title: json['title'] as String? ?? '',
        name: json['name'] as String? ?? '',
        desc: json['desc'] as String? ?? '',
        intro: json['intro'] as String? ?? '',
        cover: json['cover'] as String? ?? '',
        coverUrl: json['coverUrl'] as String? ?? '',
        categoryName: json['categoryName'] as String? ?? '',
        channelName: json['channelName'] as String? ?? '',
        remark: json['remark'] as String? ?? '',
        totalEpisode: json['totalEpisode'] as String? ?? '',
        episodeCount: json['episodeCount'] as String? ?? '',
        tags: (json['tags'] as List?)?.map((tag) => '$tag').toList() ??
            const <String>[],
        releaseStatus: json['releaseStatus'] as String? ?? '',
        score: json['score'] as String? ?? '',
        views: json['views'] as String? ?? '',
        heat: json['heat'] as String? ?? '',
        onlineDate: json['onlineDate'] as String? ?? '',
      );

  /// 供 fixtures 比对用，字段名与 Go 的 `Drama` JSON tag 对齐。
  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'source': source,
        'sourceId': sourceId,
        'title': title,
        'name': name,
        'desc': desc,
        'intro': intro,
        'cover': cover,
        'coverUrl': coverUrl,
        'categoryName': categoryName,
        'channelName': channelName,
        'remark': remark,
        'totalEpisode': totalEpisode,
        'episodeCount': episodeCount,
        'tags': tags,
        'releaseStatus': releaseStatus,
        'score': score,
        'views': views,
        'heat': heat,
        'onlineDate': onlineDate,
      };
}

/// 一集。Go 那边叫 `Chapter`——那是番茄小说留下的词，本项目统一叫 Episode。
class Episode {
  const Episode({
    required this.id,
    required this.number,
    required this.title,
    required this.videoId,
    required this.mediaUrl,
  });

  /// `hongguo:{seriesId}:{vid}`
  final String id;

  /// 第几集，从 1 开始。
  final int number;

  final String title;

  /// 视频 ID（`vid`）。
  final String videoId;

  /// 占位地址 `hongguo-cenc://{vid}`；真正的播放地址要再走一次取流。
  final String mediaUrl;
}

/// 详情：一部剧 + 它的全部分集。
class DramaDetail {
  const DramaDetail({required this.drama, required this.episodes});

  final Drama drama;
  final List<Episode> episodes;
}

/// 把文本解析成 JSON 对象；不是对象或是坏 JSON 就返回 null。
///
/// 与 Go 的差别：那边用 `UseNumber()` 保留数字原样，Dart 的 `jsonDecode` 直接给
/// `int` / `double`。对红果的字段（ID 都是字符串）没有实际影响。
Map<String, dynamic>? decodeJsonObject(String text) {
  try {
    final decoded = jsonDecode(text);
    return decoded is Map<String, dynamic> ? decoded : null;
  } on FormatException {
    return null;
  }
}

/// 合并两部剧：以 [base] 为主，缺的字段用 [extra] 补。对照 Go 的 `mergeDrama`。
///
/// 两处特判值得注意：`categoryName == '首页'` 与 `remark == '在线观看'` 也算「缺」——
/// 那是列表页的占位文案，不该盖住详情页给出的真值。
Drama mergeDrama(Drama base, Drama extra) {
  String pick(String current, String fallback) =>
      current.trim().isEmpty ? fallback : current;

  return Drama(
    id: pick(base.id, extra.id),
    source: pick(base.source, extra.source),
    sourceId: pick(base.sourceId, extra.sourceId),
    title: pick(base.title, extra.title),
    name: pick(base.name, extra.name),
    desc: pick(base.desc, extra.desc),
    intro: pick(base.intro, extra.intro),
    cover: pick(base.cover, extra.cover),
    coverUrl: pick(base.coverUrl, extra.coverUrl),
    totalEpisode: pick(base.totalEpisode, extra.totalEpisode),
    episodeCount: pick(base.episodeCount, extra.episodeCount),
    channelName: pick(base.channelName, extra.channelName),
    categoryName: base.categoryName.trim().isEmpty ||
            (base.categoryName == '首页' && extra.categoryName.isNotEmpty)
        ? extra.categoryName
        : base.categoryName,
    remark: base.remark.trim().isEmpty || base.remark == '在线观看'
        ? extra.remark
        : base.remark,
    score: pick(base.score, extra.score),
    views: pick(base.views, extra.views),
    heat: pick(base.heat, extra.heat),
    onlineDate: pick(base.onlineDate, extra.onlineDate),
    tags: base.tags.isEmpty ? extra.tags : base.tags,
    releaseStatus: base.releaseStatus.isEmpty || base.releaseStatus == 'unknown'
        ? extra.releaseStatus
        : base.releaseStatus,
  );
}

/// 把 App / 网页 / 搜索 / 推荐返回的任意一行映射成 [Drama]。
///
/// 对照 Go 的 `DramaFromAny`。
Drama dramaFromAny(Object? value, {String category = '', DateTime? now}) {
  if (value is! Map<String, dynamic>) return const Drama();

  Object? detail = value['video_data'];
  if (detail is! Map<String, dynamic> || detail.isEmpty) detail = value;
  final vd = detail;

  final sourceId = firstNonEmpty([
    mapString(vd, const ['series_id_str', 'series_id']),
    mapString(value, const ['series_id_str', 'series_id']),
    mapString(vd, const ['keyword']),
    mapString(value, const ['keyword']),
  ]);
  if (!numericIdPattern.hasMatch(sourceId)) return const Drama();

  final title = firstNonEmpty([
    mapString(vd, const ['series_title', 'series_name', 'title']),
    mapString(value, const ['series_name', 'name']),
    sourceId,
  ]);
  final cover = firstNonEmpty([
    mapString(vd, const ['series_cover', 'cover']),
    mapString(value, const ['series_cover']),
  ]);
  final intro = firstNonEmpty([
    mapString(vd, const ['series_intro', 'video_desc']),
    mapString(value, const ['series_intro']),
  ]);
  final count = firstNonEmpty([
    mapString(vd, const ['episode_cnt']),
    mapString(value, const ['episode_cnt']),
  ]);
  var remark = firstNonEmpty([
    mapString(vd, const ['episode_right_text']),
    mapString(value, const ['episode_right_text']),
  ]);

  var status = releaseStatusFromRemark(remark);
  final seriesStatus = mapString(vd, const ['series_status']);
  if (seriesStatus == '1') {
    status = 'finished';
  } else if (seriesStatus == '0') {
    status = 'ongoing';
  }
  if (remark.isEmpty && count.isNotEmpty) remark = '共$count集';

  final tags = mapStringSlice(vd, const ['tags']);
  for (final entry in anyList(vd['category_list'])) {
    final name = mapString(nestedMap(entry, const <String>[]), const ['name']);
    if (name.isNotEmpty && !tags.contains(name)) tags.add(name);
  }
  final schema = decodeJsonObject(mapString(vd, const ['category_schema']));
  for (final item in anyList(schema)) {
    final name = mapString(nestedMap(item, const <String>[]), const ['name']);
    if (name.isNotEmpty && !tags.contains(name)) tags.add(name);
  }

  var genre = mapString(vd, const ['category_name', 'categoryName', 'category']);
  if (genre.isEmpty && tags.isNotEmpty) genre = tags.first;

  return Drama(
    id: dramaId(sourceId),
    source: hongguoSource,
    sourceId: sourceId,
    title: title,
    name: title,
    desc: intro,
    intro: intro,
    cover: cover,
    coverUrl: cover,
    categoryName: firstNonEmpty([genre, category]),
    channelName: '红果',
    remark: remark,
    totalEpisode: count,
    episodeCount: count,
    tags: tags,
    releaseStatus: status,
    score: mapString(vd, const ['score']),
    views: mapString(vd, const ['series_play_cnt', 'play_cnt']),
    heat: dramaHeat(vd),
    onlineDate: dramaOnlineDate(vd, now ?? DateTime.now()),
  );
}
