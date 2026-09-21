/// 封面地址校验。对照 Go `hongguo/helpers.go` 的 `CoverAddress` / `validImageURL`。
///
/// 为什么需要：红果把封面地址**裸返回**——没有 Referer、没有代理，原项目的封面代理
/// 被明确删掉了。这份校验是客户端自己加的一道最低限度把关，拦住明显不该请求的地址。
///
/// 与 Go 的差别（有意偷懒，不影响用途）：Go 会用 netip 逐个比对一长串 IPv4/IPv6
/// 保留段、还校验每个域名标签的 LDH 合法性；这里只挡 https 之外、带 userinfo、
/// 非 443 端口、localhost/内网域名、以及私网/环回/链路本地的 IP 字面量。
library;

/// 从候选里挑第一个合法封面地址；都不合法返回空串。对照 Go 的 `CoverAddress`。
String coverAddress(List<String> candidates) {
  for (final value in candidates) {
    final text = value.trim();
    if (text.isEmpty || text.length > 8192) continue;
    final parsed = Uri.tryParse(text);
    if (parsed != null && isValidImageUrl(parsed)) return text;
  }
  return '';
}

/// 是不是可用的封面地址。
bool isValidImageUrl(Uri remote) {
  if (remote.scheme != 'https') return false;
  if (remote.userInfo.isNotEmpty) return false;
  if (remote.hasPort && remote.port != 443) return false;

  final host = remote.host.toLowerCase().replaceAll(RegExp(r'\.$'), '');
  if (host.isEmpty) return false;

  if (_parseIpv4(host) != null) return _isPublicIpv4(host);
  if (host.contains(':')) return _isPublicIpv6(host);

  if (host.length > 253 || !host.contains('.')) return false;
  for (final suffix in const [
    'localhost',
    'local',
    'internal',
    'lan',
    'home',
    'invalid',
    'test',
    'example',
  ]) {
    if (host == suffix || host.endsWith('.$suffix')) return false;
  }
  return true;
}

/// 从任意形状的值里抠出封面地址。对照 Go 的 `coverPathFromAny`。
///
/// 兼容三种：绝对 URL 字符串、以 `/` 开头的相对路径、以及一个装着 url/src/path
/// 之类字段的对象。
String coverPathFromAny(Object? value) {
  if (value == null) return '';
  if (value is String) {
    final text = value.trim();
    if (text.isEmpty) return '';
    final parsed = Uri.tryParse(text);
    if (parsed != null && parsed.isAbsolute) return parsed.toString();
    return text.replaceFirst(RegExp(r'^/+'), '');
  }
  if (value is Map<String, dynamic>) {
    for (final key in const [
      'url',
      'src',
      'path',
      'cover',
      'coverUrl',
      'cover_url',
      'image',
      'pic',
      'poster',
    ]) {
      final found = coverPathFromAny(value[key]);
      if (found.isNotEmpty) return found;
    }
  }
  return '';
}

int? _parseIpv4(String host) {
  final parts = host.split('.');
  if (parts.length != 4) return null;
  var value = 0;
  for (final part in parts) {
    if (part.isEmpty || part.length > 3) return null;
    final octet = int.tryParse(part);
    if (octet == null || octet < 0 || octet > 255) return null;
    value = (value << 8) | octet;
  }
  return value;
}

/// 私网、环回、链路本地、CGNAT、保留段一律不算公网。对照 Go 的 `publicImageAddress`。
bool _isPublicIpv4(String host) {
  final value = _parseIpv4(host)!;
  final a = (value >> 24) & 0xff;
  final b = (value >> 16) & 0xff;

  if (a == 0 || a == 10 || a == 127) return false;
  if (a == 100 && b >= 64 && b <= 127) return false; // CGNAT
  if (a == 169 && b == 254) return false;
  if (a == 172 && b >= 16 && b <= 31) return false;
  if (a == 192 && b == 168) return false;
  if (a == 192 && (b == 0 || b == 2)) return false;
  if (a == 198 && (b == 18 || b == 19 || b == 51)) return false;
  if (a == 203 && b == 0) return false;
  if (a >= 224) return false;
  return true;
}

bool _isPublicIpv6(String host) {
  final value = host.toLowerCase();
  if (value == '::' || value == '::1') return false;
  if (value.startsWith('fe80:') ||
      value.startsWith('fc') ||
      value.startsWith('fd')) {
    return false;
  }
  if (value.startsWith('::ffff:')) {
    final mapped = value.substring(7);
    return _parseIpv4(mapped) != null && _isPublicIpv4(mapped);
  }
  return true;
}
