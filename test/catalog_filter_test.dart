import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_dart/hongguo_dart.dart';
import 'package:onedrama/data/catalog_pager.dart';
import 'package:onedrama/data/library_tabs.dart';

/// 题材筛选的分页规则：带 `filterRoute` 的 pager **只走网页服务端筛选**
/// （`/category/<类型>/<题材>?page=N`），一次都不碰 App 源、也不走降级那套。
///
/// 为什么钉：筛选态与未筛选态共用同一个 `CatalogPager`，最怕 filterRoute 分支泄进
/// App 那条腿——那会让「未筛选行为逐字不变」这条被悄悄破坏。
void main() {
  const realTab = LibraryTab(
    label: '真人剧',
    genreKey: 'short_play',
    scene: 'default',
  );

  test('filterRoute 恒走网页题材路由、页码递增，不碰 App landpage', () async {
    final fake = _Fake((options) {
      final page =
          int.tryParse(options.uri.queryParameters['page'] ?? '1') ?? 1;
      return _webJson(_seriesId(page), totalPages: 34);
    });
    final pager = CatalogPager(
      client: _client(fake),
      tab: realTab,
      filterRoute: 'real-drama/costume',
    );

    final p1 = await pager.next();
    final p2 = await pager.next();

    expect(p1.map((d) => d.sourceId), [_seriesId(1)]);
    expect(p2.map((d) => d.sourceId), [_seriesId(2)]);
    // 路径必须是题材路由，页码 1、2 递增。
    expect(fake.paths, <String>[
      '/category/real-drama/costume',
      '/category/real-drama/costume',
    ]);
    expect(fake.pages, <int>[1, 2]);
    // 一次都没打 App 分类端点。
    expect(
      fake.paths.any((p) => p.contains('landpage')),
      isFalse,
      reason: '筛选态绝不能落到 App 源那条腿',
    );
  });

  test('筛选态翻到 totalPages 到头', () async {
    final fake = _Fake((options) {
      final page =
          int.tryParse(options.uri.queryParameters['page'] ?? '1') ?? 1;
      return _webJson(_seriesId(page), totalPages: 2);
    });
    final pager = CatalogPager(
      client: _client(fake),
      tab: realTab,
      filterRoute: 'real-drama/costume',
    );

    await pager.next(); // page 1
    await pager.next(); // page 2 == totalPages
    expect(pager.exhausted, isTrue);
    final third = await pager.next();
    expect(third, isEmpty);
    expect(fake.pages, <int>[1, 2]);
  });
}

String _seriesId(int seed) => '70000000000${seed.toString().padLeft(7, '0')}';

String _routerHtml(String json) =>
    '<html><body><script>window._ROUTER_DATA = $json;</script></body></html>';

String _webJson(String id, {int totalPages = 34}) => _routerHtml(
  jsonEncode(<String, Object?>{
    'loaderData': <String, Object?>{
      r'category_$': <String, Object?>{
        'isSuccess': true,
        'recommendList': <Object?>[
          <String, Object?>{'series_id_str': id, 'series_title': '网页剧 $id'},
        ],
        'pagination': <String, Object?>{'totalPages': '$totalPages'},
      },
    },
  }),
);

class _Fake implements HttpClientAdapter {
  _Fake(this.respond);

  final String Function(RequestOptions options) respond;
  final List<String> paths = <String>[];
  final List<int> pages = <int>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    paths.add(options.uri.path);
    if (options.uri.path.startsWith('/category/')) {
      pages.add(int.tryParse(options.uri.queryParameters['page'] ?? '1') ?? 1);
    }
    return ResponseBody.fromString(
      respond(options),
      200,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>['text/plain; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

HongguoClient _client(_Fake fake) {
  final dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 5),
      receiveTimeout: const Duration(seconds: 5),
      validateStatus: (_) => true,
      responseType: ResponseType.plain,
    ),
  )..httpClientAdapter = fake;
  return HongguoClient(http: dio, retries: 1);
}
