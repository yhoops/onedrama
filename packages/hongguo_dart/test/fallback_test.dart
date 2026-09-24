import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:hongguo_dart/hongguo_dart.dart';
import 'package:test/test.dart';

/// 离线兜底链测试：假 HTTP 服务器，不打真网络。
///
/// **这组测试的存在理由**：上游的 App 详情接口 `/novel/player/video_detail/v1/`
/// 已经失效——HTTP 200 但响应体是空的。当时 `fetchDetail` 只有 App 这一条腿，
/// 于是点开任何一部剧都报「红果 App 接口未返回有效数据」，而**所有测试都是绿的**：
/// `protocol_test.dart` 只比对 Go 生成的纯函数向量，控制流（有几条腿）不在比对范围内。
///
/// 所以这里钉的是**调用顺序**：哪条腿失败之后必须走哪条腿。假服务器让这件事可以
/// 确定性复现，不依赖上游今天的心情。

const String _seriesId = '7000000000000000001';
const List<String> _vids = <String>[
  '7000000000000000011',
  '7000000000000000012',
  '7000000000000000013',
];

/// 合成一份网页详情页：`window._ROUTER_DATA` 里挂 `detail_page.seriesDetail`。
///
/// 结构与真实页面一致（`seriesDetail` 与 `seriesSocialInfo` 是同级字段），只留下
/// 解析真正要用的键。
String _webDetailHtml(String seriesId, List<String> vids) {
  final router = <String, Object?>{
    'loaderData': <String, Object?>{
      'detail_page': <String, Object?>{
        'seriesDetail': <String, Object?>{
          'series_id': seriesId,
          'series_name': '合成剧',
          'series_intro': '合成简介',
          'episode_cnt': '${vids.length}',
          'vid_list': vids,
        },
        'seriesSocialInfo': <String, Object?>{
          'rating': 9.2,
          'rating_count': '1234',
        },
      },
    },
  };
  return '<html><body><script>window._ROUTER_DATA = '
      '${jsonEncode(router)};</script></body></html>';
}

/// 一条假路由：路径 + 状态码 + 响应体。
class _Route {
  const _Route(this.status, this.body);

  final int status;
  final String body;
}

/// 按路径分发的假适配器，顺便记下**每个请求**，好断言「有没有走那条腿」。
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.routes, {this.onRequest});

  final Map<String, _Route> routes;
  final void Function(RequestOptions options)? onRequest;
  final List<String> seen = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    seen.add(options.uri.path);
    onRequest?.call(options);
    final route = routes[options.uri.path];
    if (route == null) {
      throw DioException(
        requestOptions: options,
        message: '假服务器没有配这条路径：${options.uri.path}',
      );
    }
    return ResponseBody.fromString(
      route.body,
      route.status,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>['text/html; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// 造一个与协议包自建口径一致的 dio（`validateStatus` 放行 + `plain`）。
Dio _dio(_FakeAdapter adapter) {
  return Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 5),
      receiveTimeout: const Duration(seconds: 5),
      validateStatus: (_) => true,
      responseType: ResponseType.plain,
    ),
  )..httpClientAdapter = adapter;
}

void main() {
  group('详情兜底链', () {
    test('App 详情返回 200 空体时，落到网页详情并拿到完整分集', () async {
      final adapter = _FakeAdapter(<String, _Route>{
        // 上游现状：200，但响应体是空的。
        '/novel/player/video_detail/v1/': const _Route(200, ''),
        '/detail': _Route(200, _webDetailHtml(_seriesId, _vids)),
      });
      final client = HongguoClient(http: _dio(adapter));

      final detail = await client.fetchDetail(_seriesId);

      expect(adapter.seen, <String>['/novel/player/video_detail/v1/', '/detail']);
      expect(detail.drama.sourceId, _seriesId);
      expect(detail.drama.title, '合成剧');
      expect(detail.episodes.map((episode) => episode.videoId), _vids);
      expect(detail.episodes.map((episode) => episode.number), <int>[1, 2, 3]);
      expect(detail.episodes.first.mediaUrl, mediaPlaceholder(_vids.first));
      // 网页里没有播放量——调用方要自己去 merge，这里钉住这个事实。
      expect(detail.drama.views, isEmpty);
    });

    test('App 详情正常时不去打网页（不能把兜底变成常态）', () async {
      final adapter = _FakeAdapter(<String, _Route>{
        '/novel/player/video_detail/v1/': _Route(200, _appDetailJson(_vids)),
        '/detail': _Route(200, _webDetailHtml(_seriesId, _vids)),
      });
      final client = HongguoClient(http: _dio(adapter));

      final detail = await client.fetchDetail(_seriesId);

      expect(adapter.seen, <String>['/novel/player/video_detail/v1/']);
      expect(detail.episodes.length, _vids.length);
    });

    test('App 详情返回 4xx 时也落网页', () async {
      final adapter = _FakeAdapter(<String, _Route>{
        '/novel/player/video_detail/v1/': const _Route(403, 'forbidden'),
        '/detail': _Route(200, _webDetailHtml(_seriesId, _vids)),
      });
      final client = HongguoClient(http: _dio(adapter));

      final detail = await client.fetchDetail(_seriesId);
      expect(detail.episodes.length, _vids.length);
    });

    test('两条腿都失败时，错误里带**两条腿各自**的原因', () async {
      final adapter = _FakeAdapter(<String, _Route>{
        '/novel/player/video_detail/v1/': const _Route(200, ''),
        '/detail': const _Route(500, 'boom'),
      });
      final client = HongguoClient(http: _dio(adapter));

      await expectLater(
        client.fetchDetail(_seriesId),
        throwsA(
          isA<HongguoRequestException>().having(
            (error) => error.message,
            'message',
            allOf(contains('App 详情失败'), contains('网页详情失败')),
          ),
        ),
      );
    });

    test('网页详情如果返回了别的剧集，直接判失败而不是张冠李戴', () async {
      final adapter = _FakeAdapter(<String, _Route>{
        '/novel/player/video_detail/v1/': const _Route(200, ''),
        '/detail': _Route(200, _webDetailHtml('9999999999999999999', _vids)),
      });
      final client = HongguoClient(http: _dio(adapter));

      await expectLater(
        client.fetchDetail(_seriesId),
        throwsA(
          isA<HongguoRequestException>().having(
            (error) => error.message,
            'message',
            contains('返回了其他剧集'),
          ),
        ),
      );
    });

    test('空响应体在请求层就被判死，且不重试空响应', () async {
      var calls = 0;
      final adapter = _FakeAdapter(
        <String, _Route>{
          '/novel/player/video_detail/v1/': const _Route(200, ''),
        },
        onRequest: (_) => calls++,
      );
      final client = HongguoClient(http: _dio(adapter));

      await expectLater(
        client.appRequest(
          method: 'POST',
          path: '/novel/player/video_detail/v1/',
          payload: const <String, Object?>{'series_id': _seriesId},
        ),
        throwsA(
          isA<HongguoRequestException>().having(
            (error) => error.message,
            'message',
            contains('未返回有效数据'),
          ),
        ),
      );
      // 空体是**确定性的**（不是抖动），重试三次只是白等一秒又一秒。
      expect(calls, 1);
    });
  });

  group('备选地址', () {
    test('backup_url 收进 backupUrls，且不让主地址重复', () {
      final model = <String, dynamic>{
        'video_duration': '12',
        'video_list': <dynamic>[
          <String, dynamic>{
            'main_url': 'https://a.example.com/v.mp4',
            'backup_url': 'https://b.example.com/v.mp4',
            'backup_urls': <dynamic>[
              'https://c.example.com/v.mp4',
              'https://a.example.com/v.mp4', // 与主地址重复，应被去掉
            ],
            'video_meta': <String, dynamic>{
              'vheight': '1280',
              'vwidth': '720',
              'definition': '720p',
              'codec_type': 'h264',
            },
          },
        ],
      };

      final media = selectAppMedia(model);

      expect(media.url, 'https://a.example.com/v.mp4');
      expect(media.backupUrls, <String>[
        'https://b.example.com/v.mp4',
        'https://c.example.com/v.mp4',
      ]);
      expect(media.allUrls.length, 3);
      // 三个地址**不能**变成三个 variants。参考实现就是这么干的（把 `main_url` /
      // `backup_url` 当同画质并列档位收进去），结果是画质面板每个档位冒出一堆
      // 同片源不同 CDN 的重复项。这里每档只占一项：`variants` 的长度等于**画质数**
      // （选中那一档也在里面，面板要能显示当前档）。
      expect(media.variants.length, 1);
    });

    test('withUrl 把胜出的地址写回主地址，并把它从备选里摘掉', () {
      const media = Media(
        url: 'https://a.example.com/v.mp4',
        referer: mediaReferer,
        backupUrls: <String>['https://b.example.com/v.mp4'],
      );

      final moved = media.withUrl('https://b.example.com/v.mp4');

      expect(moved.url, 'https://b.example.com/v.mp4');
      expect(moved.backupUrls, <String>['https://a.example.com/v.mp4']);
      expect(moved.referer, media.referer);
    });

    test('base64 编码的地址会被解出来', () {
      final encoded = base64.encode(utf8.encode('https://d.example.com/v.mp4'));
      final model = <String, dynamic>{
        'video_list': <dynamic>[
          <String, dynamic>{
            'main_url': 'https://a.example.com/v.mp4',
            'backup_url': encoded,
            'video_meta': <String, dynamic>{'vheight': '640', 'codec_type': 'h264'},
          },
        ],
      };

      expect(selectAppMedia(model).backupUrls, <String>[
        'https://d.example.com/v.mp4',
      ]);
    });
  });
}

/// 合成一份 App 详情响应，用来验证「App 那条腿正常时不碰网页」。
String _appDetailJson(List<String> vids) {
  return jsonEncode(<String, Object?>{
    'data': <String, Object?>{
      'video_data': <String, Object?>{
        'series_id_str': _seriesId,
        'series_name': '合成剧',
        'episode_cnt': '${vids.length}',
        'video_list': <Object?>[
          for (var index = 0; index < vids.length; index++)
            <String, Object?>{
              'vid': vids[index],
              'vid_index': '${index + 1}',
            },
        ],
      },
    },
  });
}
