import 'json.dart';

/// 网页端解析的基础件。对照 Go `hongguo/parse.go` 与 `hongguo/helpers.go`。

final RegExp _routerDataPattern =
    RegExp(r'(?:window\.)?_ROUTER_DATA\s*=\s*');
final RegExp _scriptTagPattern =
    RegExp(r'<script\b[^>]*>', caseSensitive: false, dotAll: true);
final RegExp _entityPattern = RegExp(r'&(#x?[0-9a-fA-F]+|[a-zA-Z]+);');

/// 从页面 HTML 里取出 `window._ROUTER_DATA`。取不到返回 null。
///
/// 对照 Go 的 `ParseRouterData`：那边用 `json.Decoder.Decode`，**只读第一个 JSON
/// 值**、后面跟什么都无所谓；Dart 的 `jsonDecode` 要求整串合法，所以这里先把
/// 第一个值的边界扫出来再解。
Map<String, dynamic>? parseRouterData(String raw) {
  final match = _routerDataPattern.firstMatch(raw);
  if (match == null) return null;
  final value = _firstJsonValue(raw.substring(match.end));
  if (value == null) return null;
  return decodeJsonObject(value);
}

/// 在 `loaderData` 里按名字找页面数据；名字带 `$` 后缀表示前缀匹配。
///
/// 对照 Go 的 `RouterLoaderMap`。
Map<String, dynamic>? routerLoaderMap(
  Map<String, dynamic>? data,
  List<String> names,
) {
  final loader = nestedMap(data, const ['loaderData']);
  if (loader == null) return null;

  for (final name in names) {
    final page = nestedMap(loader[name], const <String>[]);
    if (page != null && page.isNotEmpty) return page;
  }

  // 退一步做前缀匹配：站点会给 loader key 拼上路由参数的后缀。
  for (final entry in loader.entries) {
    for (final name in names) {
      final prefix =
          name.endsWith(r'$') ? name.substring(0, name.length - 1) : name;
      if (prefix.isEmpty || !entry.key.startsWith(prefix)) continue;
      final page = nestedMap(entry.value, const <String>[]);
      if (page != null && page.isNotEmpty) return page;
    }
  }
  return null;
}

/// 识别 Cloudflare 拦截页。
///
/// 对照 Go 的 `catalogBlockReason`——**刻意不看 HTTP 状态码**，只看响应体前 64 KB
/// 与 `Cf-Mitigated` 头。识别出来总比把拦截页当正常 HTML 去解析、然后报「结构变化」
/// 要好。
String catalogBlockReason(Map<String, String> headers, String body) {
  final head = body.length > 64 * 1024 ? body.substring(0, 64 * 1024) : body;
  final page = head.toLowerCase();
  final mitigated = (headers['cf-mitigated'] ?? '').toLowerCase();

  if (page.contains('cloudflare') &&
      (page.contains('sorry, you have been blocked') ||
          page.contains('you are unable to access'))) {
    return 'Cloudflare 拒绝了当前请求';
  }
  if (mitigated == 'challenge' ||
      page.contains('_cf_chl_opt') ||
      (page.contains('<title>just a moment') && page.contains('cloudflare'))) {
    return '站点要求浏览器验证，当前请求无法通过';
  }
  return '';
}

/// 页面里所有 script **开标签**。对照 Go 的 `rankingScriptTags`。
///
/// 只取开标签——属性都在上面，这正是调用方要的。
List<String> scriptTags(String body) =>
    _scriptTagPattern.allMatches(body).map((m) => m.group(0)!).toList();

/// 取标签里的属性值，先做 HTML 反转义再去空白。对照 Go 的 `extractAttr`。
String extractAttr(String block, List<String> names) {
  for (final name in names) {
    final pattern = RegExp(
      r'\b' + RegExp.escape(name) + r'''\s*=\s*["']([^"']+)["']''',
      caseSensitive: false,
      dotAll: true,
    );
    final match = pattern.firstMatch(block);
    if (match != null) return unescapeHtml(match.group(1)!).trim();
  }
  return '';
}

/// HTML 实体反转义。Go 用 `html.UnescapeString`，这里只覆盖常见实体。
///
/// `data-fn-args` 那种属性值里会塞 JSON，实体必须还原才解得出。
String unescapeHtml(String value) => value.replaceAllMapped(_entityPattern, (
  match,
) {
  final entity = match.group(1)!;
  if (entity.startsWith('#x') || entity.startsWith('#X')) {
    final code = int.tryParse(entity.substring(2), radix: 16);
    return code == null ? match.group(0)! : String.fromCharCode(code);
  }
  if (entity.startsWith('#')) {
    final code = int.tryParse(entity.substring(1));
    return code == null ? match.group(0)! : String.fromCharCode(code);
  }
  switch (entity.toLowerCase()) {
    case 'amp':
      return '&';
    case 'lt':
      return '<';
    case 'gt':
      return '>';
    case 'quot':
      return '"';
    case 'apos':
      return "'";
    case 'nbsp':
      return ' ';
    default:
      return match.group(0)!;
  }
});

/// 从 [text] 开头取出第一个完整的 JSON 值（对象或数组）。
///
/// 只认最外层那一个，字符串与转义都跳过——`_ROUTER_DATA` 后面通常还跟着别的脚本，
/// 整串不是合法 JSON。
String? _firstJsonValue(String text) {
  var start = 0;
  while (start < text.length && text[start].trim().isEmpty) {
    start++;
  }
  if (start >= text.length) return null;

  final open = text[start];
  if (open != '{' && open != '[') return null;
  final close = open == '{' ? '}' : ']';

  var depth = 0;
  var inString = false;
  var escaped = false;
  for (var i = start; i < text.length; i++) {
    final ch = text[i];
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (ch == r'\') {
        escaped = true;
      } else if (ch == '"') {
        inString = false;
      }
      continue;
    }
    if (ch == '"') {
      inString = true;
    } else if (ch == open) {
      depth++;
    } else if (ch == close) {
      depth--;
      if (depth == 0) return text.substring(start, i + 1);
    }
  }
  return null;
}
