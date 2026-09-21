// 开发用探针：确认 Dart 侧的签名能被红果服务端接受，并 dump 真实响应的形状。
// 不是产品代码，也不参与测试。
//
//   dart run tool/probe.dart              # 先用免签名的联想接口挖真实 series_id，再打详情
//   dart run tool/probe.dart 123456 ...   # 直接试指定 series_id
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:hongguo_dart/hongguo_dart.dart';

Future<void> main(List<String> args) async {
  final client = HongguoClient();
  final ids = args.isEmpty ? await _discover(client) : args;

  for (final id in ids) {
    stdout.writeln('=== series_id=$id ===');
    try {
      final detail = await client.fetchDetail(id);
      stdout.writeln(
        '剧：${detail.drama.title}｜${detail.episodes.length} 集｜'
        '${detail.drama.categoryName}｜${detail.drama.releaseStatus}',
      );
      final first = detail.episodes.first;
      final media = await client.resolveAppMedia(first.videoId);
      stdout.writeln(
        '第 1 集：vid=${first.videoId} 画质=${media.quality} '
        '加密=${media.isEncrypted} 备选=${media.variants.length}',
      );
      if (media.isEncrypted) {
        stdout.writeln('CENCKey=${media.cencKey!.length} 字节');
      }
      stdout.writeln('URL=${truncateText(media.url, 100)}');
    } on HongguoRequestException catch (error) {
      stdout.writeln('FAILED: $error');
      if (error.rawResponse != null) {
        stdout.writeln('RAW: ${truncateText(error.rawResponse!, 1000)}');
      }
    } catch (error) {
      stdout.writeln('FAILED: $error');
    }
  }
}

/// 用免签名的联想接口挖几个真实 series_id。
///
/// Go 包里对应 `SearchSuggestions` 回退用的那个端点，这里只取 ID 不做解析。
Future<List<String>> _discover(HongguoClient client) async {
  final found = <String>[];
  for (final keyword in const ['总裁', '复仇']) {
    final url = '$webBaseUrl/incent_resource/suggestion'
        '?app_id=$appAid&query=${Uri.encodeQueryComponent(keyword)}&count=10';
    stdout.writeln('=== suggestion "$keyword" ===');
    try {
      final response = await client.http.get<String>(
        url,
        options: Options(
          headers: {
            'User-Agent': webUserAgent,
            'Accept-Language': 'zh-CN,zh;q=0.9',
            'Referer': webBaseUrl,
          },
        ),
      );
      final body = response.data ?? '';
      stdout.writeln('status=${response.statusCode} len=${body.length}');
      final decoded = decodeJsonObject(body);
      if (decoded == null) {
        stdout.writeln('RAW: ${truncateText(body, 800)}');
        continue;
      }
      for (final item in anyList(decoded['suggest_list'])) {
        final map = item is Map<String, dynamic> ? item : const <String, dynamic>{};
        final video = nestedMap(map, const ['video_data']);
        final drama = dramaFromAny(video ?? map);
        stdout.writeln(
          '  name=${mapString(map, const ['name'])}｜'
          'word_type=${mapString(map, const ['word_type'])}｜'
          'seriesId=${drama.sourceId}｜title=${drama.title}',
        );
        if (drama.sourceId.isNotEmpty && !found.contains(drama.sourceId)) {
          found.add(drama.sourceId);
        }
      }
    } catch (error) {
      stdout.writeln('FAILED: $error');
    }
  }
  stdout.writeln('挖到 ${found.length} 个 ID: $found');
  return found.take(3).toList();
}
