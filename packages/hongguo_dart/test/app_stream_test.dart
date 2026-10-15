import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:hongguo_dart/hongguo_dart.dart';
import 'package:test/test.dart';

/// App 取流腿（`multi_video_model/preload`）的离线契约测试。
///
/// **这组测试的存在理由**：上游在 2026-10 把 `/novel/player/video_model/v1/` 与
/// `/novel/player/multi_video_model/v1/` 同时变成「HTTP 200 + 空响应体」，而唯一还
/// 吐数据的入口 `/novel/player/multi_video_model/preload/v1/` 有两条硬要求：
/// `biz_param.video_platform` 必须是 1024（**不是**详情接口给的 3），且必须带
/// `mixed_video_id_map`。这两条写错的表现是「参数错误」或空体——和路径写错、签名
/// 写错长得一模一样，只有打真接口才看得出来。所以这里把**请求形状**钉在假服务器上，
/// 不依赖上游今天的心情（`live_test.dart` 那条才是打真网的硬证据，按需跑）。

const String _vid = '7000000000000000011';
const String _otherVid = '7000000000000000099';
const String _path = '/novel/player/multi_video_model/preload/v1/';
const String _url = 'https://v.example.com/v.mp4';
const String _backupUrl = 'https://c.example.com/v.mp4';

/// 上游响应的形状：`data` 以 vid 为 key，值是 `video_model` 加几个元字段。
String _preloadBody(Map<String, Object?> data, {int code = 0}) =>
    jsonEncode(<String, Object?>{'code': code, 'data': data});

Map<String, Object?> _entry(Object? videoModel) => <String, Object?>{
  'expire_time': 1792096222,
  'video_width': 720,
  'video_height': 1280,
  'video_model': videoModel,
};

/// 一份与真实响应同形的 `video_model`：字段名照抄上游，值简化。
///
/// 两档：1080p 的 `bytevc1`（HEVC，本机能解）与 720p 的 `bytevc2`（VVC，本机解不了，
/// 必须被 `selectAppMedia` 跳过）。
Map<String, Object?> _videoModel(String spade) => <String, Object?>{
  'status': 10,
  'video_duration': '93.554',
  'video_id': 'v02ebeg10000db6699nog65v0tba07n0',
  'video_list': <Object?>[
    <String, Object?>{
      'gear_des_key': '0:MP4|1:encrypt|2:bytevc1|4:1080p|5:normal|10000:105',
      'main_url': _url,
      'backup_url': _backupUrl,
      'encrypt_info': <String, Object?>{
        'encrypt': true,
        'encryption_method': 'cenc-aes-ctr',
        'kid': 'AAAAAAAAAAAAAAAAAAAAAA==',
        'spade_a': spade,
      },
      'video_meta': <String, Object?>{
        'codec_type': 'bytevc1',
        'definition': '1080p',
        'vwidth': '720',
        'vheight': '1280',
      },
    },
    <String, Object?>{
      'gear_des_key': '0:MP4|1:encrypt|2:bytevc2|4:720p|5:normal|10000:105',
      'main_url': 'https://v.example.com/vvc.mp4',
      'video_meta': <String, Object?>{
        'codec_type': 'bytevc2',
        'definition': '720p',
        'vwidth': '720',
        'vheight': '1280',
      },
    },
  ],
};

/// 从共享向量里取一条**可用**的 `spade_a`（Go 生成，见 `protocol_test.dart`）。
///
/// 密钥还原是 `contentKey` 的事、不是本文件的主题，所以不自己造魔数：拿契约向量
/// 里已经和 Go 对齐过的那条，失败原因才不会被「密钥解不出来」抢走。
String _spadeVector() {
  final fixture = File(
    '${Directory.current.parent.parent.path}/hongguo/testdata/vectors.json',
  );
  final vectors = jsonDecode(fixture.readAsStringSync()) as Map<String, dynamic>;
  final rows = (vectors['contentKey'] as List).cast<Map<String, dynamic>>();
  return rows.firstWhere((row) => (row['error'] as String).isEmpty)['spade']
      as String;
}

/// 一条假路由：路径 + 状态码 + 响应体。
class _Route {
  const _Route(this.status, this.body);

  final int status;
  final String body;
}

/// 按路径分发的假适配器，顺便记下**每个请求的路径与请求体**。
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.routes);

  final Map<String, _Route> routes;
  final List<String> seen = <String>[];
  final List<Object?> bodies = <Object?>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    seen.add(options.uri.path);
    // dio 把调用方传的 String 原样留在 options.data 上，不必再解流。
    bodies.add(options.data);
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
        Headers.contentTypeHeader: <String>['application/json; charset=utf-8'],
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

Map<String, dynamic> _sentBody(_FakeAdapter adapter) =>
    jsonDecode(adapter.bodies.single! as String) as Map<String, dynamic>;

void main() {
  final spade = _spadeVector();

  group('App 取流腿（multi_video_model/preload）', () {
    test('请求落在 preload 路径，且带 video_platform=1024 与 mixed_video_id_map', () async {
      final adapter = _FakeAdapter(<String, _Route>{
        _path: _Route(200, _preloadBody(<String, Object?>{
          _vid: _entry(_videoModel(spade)),
        })),
      });
      final client = HongguoClient(http: _dio(adapter));

      await client.resolveAppMedia(_vid);

      expect(adapter.seen, <String>[_path]);
      final body = _sentBody(adapter);
      final biz = body['biz_param'] as Map<String, dynamic>;
      // 上游只从 biz_param 读 video_platform，且只认 1024——详情接口给的是 3，
      // 照抄 3 会被判 video platform invalid。
      expect(biz['video_platform'], 1024);
      expect(biz['need_all_video_definition'], isTrue);
      expect(biz['detail_page_version'], 0);
      expect(biz['device_level'], 3);
      expect(body['mixed_video_id_map'], <String, dynamic>{'1004': <String>[_vid]});
      // 新入口靠 mixed_video_id_map 定位：再带顶层 video_id / content_type 会让
      // 「这是批量接口」这件事变得含糊。
      expect(body.containsKey('video_id'), isFalse);
      expect(body.containsKey('content_type'), isFalse);
    });

    test('video_model 是 JSON 字符串时解出媒体与 CENC 密钥', () async {
      final adapter = _FakeAdapter(<String, _Route>{
        _path: _Route(200, _preloadBody(<String, Object?>{
          _vid: _entry(jsonEncode(_videoModel(spade))),
        })),
      });
      final client = HongguoClient(http: _dio(adapter));

      final media = await client.resolveAppMedia(_vid);

      expect(media.url, _url);
      expect(media.referer, mediaReferer);
      expect(media.backupUrls, <String>[_backupUrl]);
      expect(media.quality, 1080);
      expect(media.width, 720);
      expect(media.height, 1280);
      expect(media.duration.inMilliseconds, 93554);
      expect(media.cencKey?.length, 16);
      // bytevc2 那一档必须被跳掉：本机 MediaCodec 解不了 VVC，留在面板里就是
      // 一个点了放不出来的选项。
      expect(media.variants.length, 1);
    });

    test('video_model 已经是 map 时同样能解（上游两种都出现过）', () async {
      final adapter = _FakeAdapter(<String, _Route>{
        _path: _Route(200, _preloadBody(<String, Object?>{
          _vid: _entry(_videoModel(spade)),
        })),
      });
      final client = HongguoClient(http: _dio(adapter));

      final media = await client.resolveAppMedia(_vid);

      expect(media.url, _url);
      expect(media.cencKey?.length, 16);
    });

    test('data 里只有别的 vid 时判失败，不拿别人的地址顶上', () async {
      final adapter = _FakeAdapter(<String, _Route>{
        _path: _Route(200, _preloadBody(<String, Object?>{
          _otherVid: _entry(_videoModel(spade)),
        })),
      });
      final client = HongguoClient(http: _dio(adapter));

      await expectLater(
        client.resolveAppMedia(_vid),
        throwsA(
          isA<HongguoRequestException>().having(
            (error) => error.message,
            'message',
            isNot(contains(_url)),
          ),
        ),
      );
    });

    test('200 空体在请求层就被判死（本层不许把它当成功）', () async {
      final adapter = _FakeAdapter(<String, _Route>{
        _path: const _Route(200, ''),
      });
      final client = HongguoClient(http: _dio(adapter));

      await expectLater(
        client.resolveAppMedia(_vid),
        throwsA(
          isA<HongguoRequestException>().having(
            (error) => error.message,
            'message',
            contains('未返回有效数据'),
          ),
        ),
      );
    });

    test('业务码非 0 时把码带进错误里（issue #17 的 110001 就是这个形状）', () async {
      final adapter = _FakeAdapter(<String, _Route>{
        _path: _Route(200, _preloadBody(const <String, Object?>{}, code: 110001)),
      });
      final client = HongguoClient(http: _dio(adapter));

      await expectLater(
        client.resolveAppMedia(_vid),
        throwsA(
          isA<HongguoRequestException>().having(
            (error) => error.message,
            'message',
            contains('110001'),
          ),
        ),
      );
    });
  });
}
