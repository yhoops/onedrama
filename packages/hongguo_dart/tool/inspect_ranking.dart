// 诊断榜单解析：把网页结构与各级查找结果逐条打出来。
//
//   dart run tool/inspect_ranking.dart [board_id]
import 'dart:convert';
import 'dart:io';

import 'package:hongguo_dart/hongguo_dart.dart';

Future<void> main(List<String> args) async {
  final client = HongguoClient();
  final board = args.isNotEmpty
      ? (findRankingBoard(args[0]) ?? rankingBoards.first)
      : rankingBoards.first;

  final base = trimTrailingSlash(client.webBase);
  final url = '$base/rank/${board.path}?page=1';
  stdout.writeln('GET $url');
  final body = await client.fetchText(url, referer: '$base/');
  stdout.writeln('HTML ${body.length} 字节');
  final dump = Platform.environment['DUMP'];
  if (dump != null && dump.isNotEmpty) {
    await File(dump).writeAsString(body);
    stdout.writeln('已写入 $dump');
  }

  final data = parseRouterData(body);
  stdout.writeln('_ROUTER_DATA：${data == null ? '没找到' : '有'}');
  if (data == null) {
    stdout.writeln('前 300 字节：${body.substring(0, body.length < 300 ? body.length : 300)}');
    return;
  }
  stdout.writeln('顶层键=${data.keys.take(12).toList()}');

  final loader = nestedMap(data, const ['loaderData']);
  stdout.writeln('loaderData 键=${loader?.keys.take(20).toList()}');

  final key = 'rank_${board.path}/page';
  final page = nestedMap(data, ['loaderData', key]);
  stdout.writeln('$key：${page == null ? '没有' : '有'}');
  if (page != null) {
    stdout.writeln('  rankKey=${mapString(page, const ['rankKey'])}'
        '（期望 ${board.upstreamKey}）');
    stdout.writeln('  pageNum=${mapString(page, const ['pageNum'])}（期望 1）');
    stdout.writeln('  updatedText=${mapString(page, const ['updatedText'])}');
    final inline = nestedMap(page['content'], const <String>[]);
    stdout.writeln('  内联 content：${inline == null ? '没有' : '${inline.length} 个键'}');
    if (inline != null) {
      stdout.writeln('  content 键=${inline.keys.take(12).toList()}');
      final rows = inline['rankList'];
      stdout.writeln('  rankList：${rows is List ? '${rows.length} 条' : '不是数组（${rows.runtimeType}）'}');
    }
  }

  stdout.writeln('带 data-fn-name 的 script：');
  var shown = 0;
  for (final tag in scriptTags(body)) {
    final name = extractAttr(tag, const ['data-fn-name']);
    final src = extractAttr(tag, const ['data-script-src']);
    if (name.isEmpty && src.isEmpty) continue;
    stdout.writeln('  data-fn-name=$name｜data-script-src=$src'
        '｜标签长 ${tag.length}');
    if (name == 'mergeLoaderData') {
      final rawArgs = extractAttr(tag, const ['data-fn-args']);
      stdout.writeln('    data-fn-args 长度=${rawArgs.length}');
      stdout.writeln('    前 200 字符：${rawArgs.substring(0, rawArgs.length < 200 ? rawArgs.length : 200)}');
      stdout.writeln('    含 &quot;：${rawArgs.contains('&quot;')}'
          '｜含 "：${rawArgs.contains('"')}'
          '｜含 >：${rawArgs.contains('>')}');
      try {
        final decoded = jsonDecode(rawArgs);
        if (decoded is List) {
          stdout.writeln('    解析出 ${decoded.length} 段；args[0]=${decoded.isEmpty ? '—' : decoded[0]}');
          if (decoded.length > 1) {
            stdout.writeln('    args[1] 类型=${decoded[1].runtimeType}');
          }
        } else {
          stdout.writeln('    JSON 不是数组：${decoded.runtimeType}');
        }
      } catch (error) {
        stdout.writeln('    JSON 解析失败：$error');
      }
    }
    if (++shown >= 12) {
      stdout.writeln('  …（截断）');
      break;
    }
  }

  try {
    final parsed = parseRanking(body, board, 1);
    stdout.writeln('解析成功：${parsed.items.length} 条，共 ${parsed.totalPages} 页');
  } catch (error) {
    stdout.writeln('解析失败：$error');
  }
}

// 便于用 grep 核对原始 HTML。
Future<void> dumpBody(String body, String path) async {
  await File(path).writeAsString(body);
}
