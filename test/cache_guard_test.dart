import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onedrama/data/network.dart';

/// TTL 缓存的**入场条件**：什么样的 200 才算「成功」。
///
/// 为什么必须钉住：红果的签名接口会返回 **HTTP 200 + 空响应体**——App 详情
/// `/novel/player/video_detail/v1/` 现在就是这样。原来的 `_settle` 只看
/// `statusCode == 200` 就入缓存，于是那份空体被钉住五分钟；而重试只在**非 200** 上
/// 才有效，这五分钟里每次重试都命中同一份空体，必然失败。症状是「详情页怎么点都是
/// 未返回有效数据」，重启才好（或等五分钟），极难归因。
///
/// 业务码非 0 同理：那是「上游说这次不行」，缓存它等于把一次抖动拉长成五分钟。
void main() {
  const path = '/novel/player/video_detail/v1/';
  const url = 'https://api5-normal-sinfonlineb.fqnovel.com$path';

  Future<({Dio dio, _CountingAdapter fake, CoalescingCacheInterceptor cache})>
      build(_Answer Function(RequestOptions) answer) async {
    final cache = CoalescingCacheInterceptor();
    final dio = buildAppDio(cache)
      ..httpClientAdapter = _CountingAdapter(answer);
    return (
      dio: dio,
      fake: dio.httpClientAdapter as _CountingAdapter,
      cache: cache,
    );
  }

  Future<Response<dynamic>> once(Dio dio) =>
      dio.request<String>(url, data: '{"series_id":"7000000000000000001"}');

  group('空体不入缓存', () {
    test('200 + 空体：每次请求都真的打出去，且不占缓存', () async {
      final built = await build((_) => const _Answer(200, ''));

      await once(built.dio);
      await once(built.dio);

      expect(built.fake.calls, 2, reason: '空体被缓存了，第二次没打出去');
      expect(built.cache.cachedEntries, 0);
      expect(built.cache.cacheHits, 0);
    });

    test('200 + 业务码非 0：同样不入缓存', () async {
      final built = await build(
        (_) => const _Answer(200, '{"code":100001,"message":"参数错误","data":{}}'),
      );

      await once(built.dio);
      await once(built.dio);

      expect(built.fake.calls, 2);
      expect(built.cache.cachedEntries, 0);
    });

    test('200 + 正常响应：第二次走缓存，不再打网络', () async {
      final built = await build(
        (_) => const _Answer(200, '{"code":0,"data":{"video_data":{}}}'),
      );

      await once(built.dio);
      await once(built.dio);

      expect(built.fake.calls, 1, reason: '正常响应应当能命中缓存');
      expect(built.cache.cachedEntries, 1);
      expect(built.cache.cacheHits, 1);
    });

    test('网页 HTML 只要非空就缓存（那一路没有业务码）', () async {
      const webUrl = 'https://hongguoduanju.com/detail?series_id=7000000000000000001';
      final built = await build((_) => const _Answer(200, '<html>ok</html>'));

      await built.dio.request<String>(webUrl);
      await built.dio.request<String>(webUrl);

      expect(built.fake.calls, 1);
      expect(built.cache.cachedEntries, 1);
    });
  });
}

class _Answer {
  const _Answer(this.status, this.body);

  final int status;
  final String body;
}

class _CountingAdapter implements HttpClientAdapter {
  _CountingAdapter(this.answer);

  final _Answer Function(RequestOptions options) answer;
  int calls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    final result = answer(options);
    return ResponseBody.fromString(
      result.body,
      result.status,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>['text/plain; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
