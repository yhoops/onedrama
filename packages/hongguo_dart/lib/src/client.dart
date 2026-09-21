import 'dart:convert';

import 'package:dio/dio.dart';

import 'json.dart';
import 'sign.dart';
import 'web.dart';

/// 站点常量。对照 Go `hongguo/types.go`。
const String webBaseUrl = 'https://hongguoduanju.com';
const String appBaseUrl = 'https://api5-normal-sinfonlineb.fqnovel.com';
const String playbackApiUrl = 'https://djapi.999888456.xyz/api/hongguo/play';

/// 播放地址要带的 Referer。
const String mediaReferer = 'https://novel.snssdk.com/';

/// App 伪装的设备与版本号。服务端按这些做风控，改之前先想清楚。
const String appUserAgent =
    'com.phoenix.read/73532 (Linux; U; Android 16; zh_CN; 25053RT47C; '
    'Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 '
    'QuicVersion:c67e9834 2025-09-08)';
const String webUserAgent =
    'Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) '
    'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.6 Mobile/15E148 '
    'Safari/604.1';
const String appAid = '8662';
const String appName = 'novelread';
const String appVersionCode = '73532';
const String appVersionName = '7.3.5.32';

/// 响应体上限，与 Go 的 `MaxBodyBytes` 一致。
const int maxBodyBytes = 20 * 1024 * 1024;

/// 请求层错误：传输失败、HTTP 状态码异常、业务码非 0。
class HongguoRequestException implements Exception {
  HongguoRequestException(this.message, {this.rawResponse});

  final String message;

  /// 服务端原始响应体。排查签名 / 风控问题时唯一的线索。
  final String? rawResponse;

  @override
  String toString() => message;
}

/// 红果 App 签名接口客户端。对照 Go `hongguo/client.go` 的 `Client`。
///
/// 只管把请求发出去并返回解析好的 JSON。去重、TTL 缓存、拦截页识别是上层网络
/// 层的事（见 `docs/plan.md` 阶段 2）。
class HongguoClient {
  HongguoClient({Dio? http, this.retries = 3})
      : http = http ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 25),
                receiveTimeout: const Duration(seconds: 25),
                // 状态码自己判，免得 dio 把 4xx/5xx 抛成异常后丢掉响应体。
                validateStatus: (_) => true,
                responseType: ResponseType.plain,
              ),
            );

  final Dio http;

  /// 重试次数，与 Go 的 `Client.Retries` 一样夹在 1–3。
  final int retries;

  String appBase = appBaseUrl;
  String webBase = webBaseUrl;

  /// 启动时生成一次后要持久化——每次重启都换会让服务端风控更脏。
  String deviceId = newDeviceId();
  String installId = newDeviceId();

  int get _attempts => retries < 1 ? 1 : (retries > 3 ? 3 : retries);

  /// 发一个 App 签名请求。对照 Go 的 `Client.AppRequest`。
  ///
  /// 重试策略与 Go 一致：传输错误与 5xx 退避重试（第 n 次前等 n 秒），
  /// 4xx 直接放弃。
  Future<Map<String, dynamic>> appRequest({
    required String method,
    required String path,
    Map<String, String> extraQuery = const <String, String>{},
    Object? payload,
  }) async {
    final query = <String, String>{
      'aid': appAid,
      'app_name': appName,
      'version_code': appVersionCode,
      'version_name': appVersionName,
      'manifest_version_code': appVersionCode,
      'update_version_code': appVersionCode,
      'channel': 'update_64',
      'device_platform': 'android',
      'os': 'android',
      'ssmix': 'a',
      'device_type': '25053RT47C',
      'device_brand': 'Redmi',
      'language': 'zh',
      'os_api': '36',
      'os_version': '16',
      'resolution': '1280*2772',
      'dpi': '520',
      'ac': 'wifi',
      'device_id': deviceId,
      'iid': installId,
      ...extraQuery,
    };

    final bodyText = payload == null ? null : jsonEncode(payload);
    final bodyBytes = bodyText == null ? null : utf8.encode(bodyText);

    Object? lastError;
    for (var attempt = 0; attempt < _attempts; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(Duration(seconds: attempt));
      }

      // _rticket 必须在签名前落定：签名算的就是最终要发的查询串。
      final now = DateTime.now();
      query['_rticket'] = now.millisecondsSinceEpoch.toString();
      final rawQuery = encodeQuery(query);

      final headers = <String, String>{
        'User-Agent': appUserAgent,
        'Accept': 'application/json',
        'X-XS-From-Web': '0',
        'Sdk-Version': '2',
        ...signRequest(rawQuery: rawQuery, body: bodyBytes, now: now),
      };
      if (bodyText != null) {
        headers['Content-Type'] = 'application/json; charset=utf-8';
      }

      try {
        final response = await http.request<String>(
          '${trimTrailingSlash(appBase)}$path?$rawQuery',
          data: bodyText,
          options: Options(method: method, headers: headers),
        );
        final status = response.statusCode ?? 0;
        if (status != 200) {
          final error = HongguoRequestException('红果 App 接口 HTTP $status');
          if (status >= 400 && status < 500) throw error;
          lastError = error;
          continue;
        }
        final content = response.data ?? '';
        if (content.isEmpty || utf8.encode(content).length > maxBodyBytes) {
          throw HongguoRequestException('红果 App 接口未返回有效数据');
        }
        final result = decodeJsonObject(content);
        if (result == null) {
          throw HongguoRequestException(
            '红果 App 接口返回格式异常',
            rawResponse: content,
          );
        }
        final code = firstNonEmpty([
          mapString(result, const ['code', 'Code', 'status_code']),
          mapString(
            nestedMap(result, const ['BaseResp']),
            const ['StatusCode'],
          ),
        ]);
        if (code.isNotEmpty && code != '0') {
          throw HongguoRequestException(
            '红果 App 接口暂不可用（${truncateText(code, 20)}）',
            rawResponse: content,
          );
        }
        return result;
      } on DioException catch (error) {
        lastError = HongguoRequestException(
          '红果 App 接口请求失败：${error.message ?? error.type.name}',
        );
      }
    }
    throw lastError is HongguoRequestException
        ? lastError
        : HongguoRequestException('红果 App 接口请求失败');
  }

  /// 网页 GET（免签名）。对照 Go 的 `Client.FetchText`。
  ///
  /// 重试策略与 Go 一致：传输错误、5xx 与 408 退避重试；4xx（408 除外）直接放弃。
  /// 拦截页识别在返回前做——宁可报「站点要求浏览器验证」，也别让上层把拦截页当正常
  /// HTML 去解析、然后报「页面结构变化」。
  Future<String> fetchText(String url, {String? referer}) async {
    Object? lastError;
    for (var attempt = 1; attempt <= _attempts; attempt++) {
      if (attempt > 1) {
        await Future<void>.delayed(Duration(seconds: attempt));
      }
      final host = Uri.tryParse(url)?.host ?? url;
      try {
        final response = await http.get<String>(
          url,
          options: Options(
            headers: {
              'User-Agent': webUserAgent,
              'Referer': referer ?? url,
              'Accept-Language': 'zh-CN,zh;q=0.9',
            },
          ),
        );
        final body = response.data ?? '';
        final status = response.statusCode ?? 0;
        if (utf8.encode(body).length > maxBodyBytes) {
          lastError = HongguoRequestException('响应超过 $maxBodyBytes 字节');
          continue;
        }
        final reason =
            catalogBlockReason(flattenHeaders(response.headers), body);
        if (status < 200 || status >= 300) {
          final error = HongguoRequestException(
            reason.isEmpty ? '$host HTTP $status' : '$host HTTP $status：$reason',
            rawResponse: body,
          );
          if (status >= 400 && status < 500 && status != 408) throw error;
          lastError = error;
          continue;
        }
        if (reason.isNotEmpty) {
          throw HongguoRequestException(
            '$host HTTP $status：$reason',
            rawResponse: body,
          );
        }
        return body;
      } on DioException catch (error) {
        lastError = HongguoRequestException(
          '$host 请求失败：${error.message ?? error.type.name}',
        );
      }
    }
    throw lastError is HongguoRequestException
        ? lastError
        : HongguoRequestException('$url 请求失败');
  }
}

/// dio 的响应头转成「键小写、取第一个值」。
///
/// 对齐 Go 的 `http.Header` 取值方式（键规范化后取 `values[0]`）。
Map<String, String> flattenHeaders(Headers headers) {
  final out = <String, String>{};
  headers.map.forEach((key, values) {
    if (values.isNotEmpty) out[key.toLowerCase()] = values.first;
  });
  return out;
}

/// 去掉结尾的斜杠。
String trimTrailingSlash(String value) =>
    value.replaceFirst(RegExp(r'/+$'), '');

/// 按 `key=value&...` 拼查询串，与 Go 的 `url.Values.Encode` 编码方式一致。
String encodeQuery(Map<String, String> params) => params.entries
    .map(
      (entry) =>
          '${Uri.encodeQueryComponent(entry.key)}='
          '${Uri.encodeQueryComponent(entry.value)}',
    )
    .join('&');

/// 截断，用于错误信息。对照 Go 的 `truncate`。
String truncateText(String value, int max) =>
    value.length <= max ? value : value.substring(0, max);
