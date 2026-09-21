/// 源标识与 ID 工具。对照 Go `hongguo/helpers.go`、`hongguo/types.go`。
library;

/// 源标识。
const String hongguoSource = 'hongguo';

/// 分集地址占位符前缀。真正的 mp4 / m3u8 要再走一次取流。
const String mediaScheme = 'hongguo-cenc://';

/// `series_id` / `vid` 必须是 1–32 位数字。
final RegExp numericIdPattern = RegExp(r'^[0-9]{1,32}$');

/// 剧 ID：`hongguo:{series_id}`。
String dramaId(String sourceId) => '$hongguoSource:${sourceId.trim()}';

/// 集 ID：`hongguo:{series_id}:{vid}`。
///
/// 对应 Go 的 `ChapterID`——那里的 `Chapter` 就是本项目的 Episode。
String episodeId(String sourceId, String videoId) =>
    '$hongguoSource:${sourceId.trim()}:${videoId.trim()}';

/// 归一化源名；不认识的源返回空串。
String canonicalSource(String value) {
  switch (value.trim().toLowerCase()) {
    case hongguoSource:
    case 'hongguoduanju.com':
    case 'www.hongguoduanju.com':
      return hongguoSource;
    default:
      return '';
  }
}

/// 从剧 ID（或裸 series_id）取出 series_id；不合法返回 null。
String? splitDramaId(String identifier) {
  final text = identifier.trim();
  String sourceId;
  final separator = text.indexOf(':');
  if (separator >= 0) {
    if (canonicalSource(text.substring(0, separator)) != hongguoSource) {
      return null;
    }
    sourceId = text.substring(separator + 1);
  } else {
    sourceId = text;
  }
  // Go 是先 TrimPrefix 再 TrimSpace，顺序影响带前导空格的畸形输入，照抄。
  const legacyPrefix = 'hg-series-v1:';
  if (sourceId.startsWith(legacyPrefix)) {
    sourceId = sourceId.substring(legacyPrefix.length);
  }
  sourceId = sourceId.trim();
  return numericIdPattern.hasMatch(sourceId) ? sourceId : null;
}

/// 从 `hongguo-cenc://{vid}` 占位符取出 vid。
String videoIdFromUrl(String videoUrl) {
  final text = videoUrl.trim();
  return text.startsWith(mediaScheme)
      ? text.substring(mediaScheme.length)
      : text;
}

/// 生成分集占位地址。
String mediaPlaceholder(String videoId) => mediaScheme + videoId.trim();
