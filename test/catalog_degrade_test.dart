import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_dart/hongguo_dart.dart';
import 'package:onedrama/data/catalog_pager.dart';
import 'package:onedrama/data/library_tabs.dart';

/// 首页 / 剧库的分页**降级**规则：App 分类这条腿断了，整个标签改走网页 `?page=N`。
///
/// 为什么必须钉住：上游刚发生过「接口还在、但不再吐数据」——App 详情
/// `/novel/player/video_detail/v1/` 现在就是 HTTP 200 + 空体。当时没有兜底，
/// 表现是「点开任何一部剧都报错」。分类这条腿是同一类风险，而它的降级还多一层约束：
/// 两套坐标系（App 是 `offset + session_id`，网页是页码）**不能混着走**，混了会翻页
/// 重复或跳页。所以这里同时钉「降级发生」和「降级之后不再回 App」。
void main() {
  const realTab = LibraryTab(label: '真人剧', genreKey: 'short_play', scene: 'default');
  const mixedTab = LibraryTab(label: '综合');

  group('分类降级', () {
    test('App 分类失败 → 落网页第 1 页，之后不再回 App', () async {
      final fake = _Fake((options) {
        if (options.uri.path.startsWith('/category/')) {
          final page = int.tryParse(options.uri.queryParameters['page'] ?? '1') ?? 1;
          return _Route.json(_webCategoryJson(_seriesId(page)));
        }
        // App 分类：接口还在，但返回 200 + 空体（这正是上游现在的形状）
        return const _Route(200, '');
      });
      final pager = CatalogPager(client: _client(fake), tab: realTab);

      final first = await pager.next();
      expect(first.map((drama) => drama.sourceId), [_seriesId(1)]);
      expect(pager.degraded, isTrue);

      final second = await pager.next();
      expect(second.map((drama) => drama.sourceId), [_seriesId(2)]);

      // 关键：第 2 页**只**打了网页，没有再去试 App。两套坐标系混着走会让游标失控。
      expect(fake.seen.where((path) => path == '/reading/distribution/category/landpage/v/').length, 1);
      expect(
        fake.webPages,
        <int>[1, 2],
        reason: '网页页码必须递增，否则降级会原地打转',
      );
    });

    test('App 分类正常时不降级，一次网页都不打', () async {
      final fake = _Fake((options) {
        if (options.uri.path.startsWith('/category/')) {
          return _Route.json(_webCategoryJson('unexpected'));
        }
        return _Route.json(_appCategoryJson(const ['7000000000000000001']));
      });
      final pager = CatalogPager(client: _client(fake), tab: realTab);

      final first = await pager.next();

      expect(first.map((drama) => drama.sourceId), ['7000000000000000001']);
      expect(pager.degraded, isFalse);
      expect(fake.webPages, isEmpty, reason: 'App 好的时候不该碰网页');
    });

    test('网页翻到 totalPages 就到头，不会无限翻', () async {
      final fake = _Fake((options) {
        if (options.uri.path.startsWith('/category/')) {
          final page = int.tryParse(options.uri.queryParameters['page'] ?? '1') ?? 1;
          // totalPages = 2
          return _Route.json(_webCategoryJson(_seriesId(page), totalPages: 2));
        }
        return const _Route(200, '');
      });
      final pager = CatalogPager(client: _client(fake), tab: realTab);

      await pager.next(); // page 1
      await pager.next(); // page 2 == totalPages
      expect(pager.exhausted, isTrue);

      final third = await pager.next();
      expect(third, isEmpty, reason: '到底之后不该再发请求');
      expect(fake.webPages, <int>[1, 2]);
    });

    test('网页这一页返回 0 条也当作到底（totalPages 解析不出来时的保险）', () async {
      final fake = _Fake((options) {
        if (options.uri.path.startsWith('/category/')) {
          final page = int.tryParse(options.uri.queryParameters['page'] ?? '1') ?? 1;
          if (page >= 2) return _Route.json(_webCategoryEmptyJson());
          return _Route.json(_webCategoryJson(_seriesId(page), totalPages: 0));
        }
        return const _Route(200, '');
      });
      final pager = CatalogPager(client: _client(fake), tab: realTab);

      await pager.next();
      await pager.next();

      expect(pager.exhausted, isTrue);
    });

    test('综合走推荐接口，且**不**降级——网页没有「推荐」的等价物', () async {
      final fake = _Fake((options) {
        // 综合走的是 App 的 landpage 端点（推荐），网页那一支不该被碰到。
        if (options.uri.path.contains('landpage')) {
          return _Route.json(_recommendJson(const ['7000000000000000002']));
        }
        return _Route.json(_webCategoryJson(_seriesId(9)));
      });
      final pager = CatalogPager(client: _client(fake), tab: mixedTab);

      final first = await pager.next();

      expect(first.map((drama) => drama.sourceId), ['7000000000000000002']);
      expect(pager.degraded, isFalse);
      expect(fake.webPages, isEmpty);
    });
  });
}

/// 造一个合法的 series_id。`numericIdPattern` 要求 1–32 位数字。
String _seriesId(int seed) => '70000000000${seed.toString().padLeft(7, '0')}';

/// App 分类一页的正常响应。
String _appCategoryJson(List<String> ids) => jsonEncode(<String, Object?>{
  'code': 0,
  'data': <String, Object?>{
    'video_data': <Object?>[
      for (final id in ids)
        <String, Object?>{'series_id_str': id, 'series_title': '剧 $id'},
    ],
    'has_more': false,
    'next_offset': '0',
    'session_id': '',
  },
});

/// 推荐（综合标签）一页的响应。
String _recommendJson(List<String> ids) => jsonEncode(<String, Object?>{
  'code': 0,
  'data': <String, Object?>{
    'video_data': <Object?>[
      for (final id in ids)
        <String, Object?>{'series_id_str': id, 'series_title': '剧 $id'},
    ],
    'has_more': false,
    'next_offset': '0',
    'session_id': '',
  },
});

/// 把一份 `_ROUTER_DATA` 包成页面——`parseRouterData` 找的就是 `_ROUTER_DATA =`
/// 这个标记，光给裸 JSON 它会当页面结构变了。
String _routerHtml(String json) =>
    '<html><body><script>window._ROUTER_DATA = $json;</script></body></html>';

/// 网页分类页：`loaderData.category_$`，结构与真实页面一致。
String _webCategoryJson(String id, {int totalPages = 34}) => _routerHtml(
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

/// 网页分类的一页，一条都没有——用来测「返回空即到底」这条保险。
String _webCategoryEmptyJson() => _routerHtml(
  jsonEncode(<String, Object?>{
  'loaderData': <String, Object?>{
    r'category_$': <String, Object?>{
      'isSuccess': true,
      'recommendList': <Object?>[],
      'pagination': <String, Object?>{'totalPages': '0'},
    },
  },
  }),
);

class _Route {
  const _Route(this.status, this.body);

  _Route.json(this.body) : status = 200;

  final int status;
  final String body;
}

/// 按请求分发的假适配器。记下**每个**路径，好断言「有没有走那条腿」。
class _Fake implements HttpClientAdapter {
  _Fake(this.respond);

  final _Route Function(RequestOptions options) respond;
  final List<String> seen = <String>[];

  /// 打过的网页分类页码，按顺序。空表示一次都没走网页。
  final List<int> webPages = <int>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    seen.add(options.uri.path);
    if (options.uri.path.startsWith('/category/')) {
      webPages.add(int.tryParse(options.uri.queryParameters['page'] ?? '1') ?? 1);
    }
    final route = respond(options);
    return ResponseBody.fromString(
      route.body,
      route.status,
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
  // 重试设 1：这组测试验的是**分支**，重试只会让「打了几次」这类断言变脆。
  return HongguoClient(http: dio, retries: 1);
}
