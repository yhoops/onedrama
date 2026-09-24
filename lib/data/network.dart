import 'dart:async';

import 'package:dio/dio.dart';
import 'package:hongguo_dart/hongguo_dart.dart';

/// 哪些请求可以进 TTL 缓存。
///
/// **取流一律不缓存**：`main_url` 大概率带时效签名，缓存下来会播到过期地址；网页的
/// `/player/` 同理。这几条是刻意写死的，改之前先想清楚——踩了会表现为「播到一半
/// 403」，很难查。
bool isCacheableRequest(RequestOptions options) {
  final host = options.uri.host;
  final path = options.uri.path;
  if (host.endsWith('fqnovel.com')) {
    return path.startsWith('/reading/distribution/category/') ||
        path.startsWith('/novel/player/video_detail/');
  }
  if (host.endsWith('hongguoduanju.com')) {
    // `/rank/` **刻意不在**这里：红果榜单约一半请求返回「新渲染」那版页面——HTTP 200
    // 但内容里压根没有榜单数据（见 `parseRanking`）。而下面 `_settle` 只看
    // `statusCode == 200` 就入缓存，于是那份坏 HTML 被钉住五分钟，
    // `BoardFeed._fetchWithRetry` 的后五次重试全部命中它、必然失败——重试只在非 200
    // 上才有效。不缓存之后重试才是真的在重试（六次后约 98%）。
    return path.startsWith('/search/') ||
        path.startsWith('/category/') ||
        path.startsWith('/detail') ||
        path.startsWith('/incent_resource/suggestion');
  }
  return false;
}

/// 缓存键：方法 + 主机 + 路径 + 去掉易变参数的查询串 + 请求体。
///
/// `_rticket` 每次都不同（客户端签名时随手取的时间戳），必须剔掉；不剔的话签名
/// 请求永远命中不了缓存，去重也永远生效不了。
String cacheKeyFor(RequestOptions options) {
  final uri = options.uri;
  final params = Map<String, String>.from(uri.queryParameters)
    ..remove('_rticket');
  final keys = params.keys.toList()..sort();
  final query = keys.map((key) => '$key=${params[key]}').join('&');
  final body = options.data;
  final bodyPart = body == null ? '' : '\u0001$body';
  return '${options.method} ${uri.scheme}://${uri.host}${uri.path}?$query$bodyPart';
}

/// 同一请求并发时共享一个 Future，再加一层 TTL 缓存。
///
/// 为什么需要：红果的接口不便宜（每次都要签名），而「库首页 → 详情 → 播放」这条路
/// 会反复打同一批接口；滑列表、来回切页时重复请求尤其明显。
class CoalescingCacheInterceptor extends Interceptor {
  CoalescingCacheInterceptor({this.ttl = const Duration(minutes: 5)});

  final Duration ttl;

  final Map<String, _CachedResponse> _cache = {};
  final Map<String, Completer<Response<dynamic>>> _inFlight = {};

  /// 诊断用：命中缓存的次数。
  int cacheHits = 0;

  /// 诊断用：被合并掉的并发请求数。
  int coalesced = 0;

  /// 清空缓存。设置页的「清除缓存」用它。
  void clear() => _cache.clear();

  int get cachedEntries => _cache.length;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (!isCacheableRequest(options)) {
      handler.next(options);
      return;
    }
    final key = cacheKeyFor(options);

    final cached = _cache[key];
    if (cached != null && DateTime.now().difference(cached.at) < ttl) {
      cacheHits++;
      handler.resolve(cached.response);
      return;
    }

    // 同样的请求正在飞？等它，不再发一个。
    final pending = _inFlight[key];
    if (pending != null) {
      coalesced++;
      pending.future.then(
        (response) => handler.resolve(response),
        onError: (Object error) => handler.reject(
          error is DioException
              ? error
              : DioException(requestOptions: options, error: error),
        ),
      );
      return;
    }

    _inFlight[key] = Completer<Response<dynamic>>();
    handler.next(options);
  }

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    _settle(response.requestOptions, response: response);
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    _settle(err.requestOptions, error: err);
    handler.next(err);
  }

  void _settle(
    RequestOptions options, {
    Response<dynamic>? response,
    DioException? error,
  }) {
    if (!isCacheableRequest(options)) return;
    final key = cacheKeyFor(options);

    final completer = _inFlight.remove(key);
    if (completer != null && !completer.isCompleted) {
      if (error != null) {
        completer.completeError(error);
      } else if (response != null) {
        completer.complete(response);
      }
    }

    // 只缓存**真的有内容**的成功响应。
    //
    // 「看状态码就行」是不够的：红果的签名接口会返回 **HTTP 200 + 空响应体**——App
    // 详情 `/novel/player/video_detail/v1/` 现在就是这样。空体进了缓存就会被钉住
    // 五分钟，而重试只在非 200 上才有效 → 这五分钟里每次重试都命中同一份空体，必然失败。
    // 业务码非 0 的响应同理：那是「上游说这次不行」，缓存它等于把一次抖动变成五分钟。
    if (response != null && response.statusCode == 200 && _usable(response)) {
      _cache[key] = _CachedResponse(response, DateTime.now());
    }
  }

  /// 响应值不值得进缓存。
  ///
  /// 走 `fqnovel.com` 的那几个签名接口响应体是 JSON（`responseType: plain` 给的是
  /// 字符串），空体与业务码非 0 都不该缓存。网页那几个（HTML）只要有内容就行。
  bool _usable(Response<dynamic> response) {
    final body = response.data;
    if (body is! String || body.trim().isEmpty) return false;
    final decoded = decodeJsonObject(body);
    if (decoded == null) return true; // 不是 JSON：HTML 之类，有内容就够
    final code = firstNonEmpty(<String>[
      mapString(decoded, const <String>['code', 'Code', 'status_code']),
      mapString(
        nestedMap(decoded, const <String>['BaseResp']),
        const <String>['StatusCode'],
      ),
    ]);
    return code.isEmpty || code == '0';
  }
}

/// 造一个带去重与 TTL 缓存的 dio。
///
/// 选项必须与协议包 `HongguoClient` 自建的那个一致：`validateStatus` 一律放行、
/// `responseType: plain`。不一致的话 4xx/5xx 会被 dio 抛成异常、响应体丢掉，而
/// 协议包正是靠响应体里的业务码来判断的。
Dio buildAppDio(CoalescingCacheInterceptor cache) => Dio(
  BaseOptions(
    connectTimeout: const Duration(seconds: 25),
    receiveTimeout: const Duration(seconds: 25),
    validateStatus: (_) => true,
    responseType: ResponseType.plain,
  ),
)..interceptors.add(cache);

class _CachedResponse {
  _CachedResponse(this.response, this.at);

  final Response<dynamic> response;
  final DateTime at;
}
