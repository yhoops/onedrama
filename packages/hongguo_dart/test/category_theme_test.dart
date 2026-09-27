import 'dart:io';

import 'package:hongguo_dart/hongguo_dart.dart';
import 'package:test/test.dart';

/// 题材词表（[categoryThemes]）的守卫。
///
/// 纯断言恒跑；drift 那条打真接口、`LIVE=1` 才跑——词表是硬编码的，上游增删题材时
/// 只有对着 live `selectorList` 比一遍才发现（见任务 09-27-tag-filter 的取舍）。
void main() {
  group('题材词表（纯断言）', () {
    test('三个网页内容类型都有词表', () {
      expect(
        categoryThemes.keys,
        containsAll(<String>['real-drama', 'comic-drama', 'ai-drama']),
      );
    });

    test('每条词表非空、id 与 name 都非空且 id 唯一', () {
      for (final entry in categoryThemes.entries) {
        expect(entry.value, isNotEmpty, reason: entry.key);
        final ids = <String>{};
        for (final theme in entry.value) {
          expect(theme.id.trim(), isNotEmpty, reason: entry.key);
          expect(
            theme.name.trim(),
            isNotEmpty,
            reason: '${entry.key}/${theme.id}',
          );
          expect(
            ids.add(theme.id),
            isTrue,
            reason: '重复 id ${entry.key}/${theme.id}',
          );
        }
      }
    });

    test('真人剧 24 项；漫剧与 AI剧共用同一套', () {
      expect(categoryThemes['real-drama']!.length, 24);
      expect(
        categoryThemes['comic-drama']!.map((t) => t.id),
        categoryThemes['ai-drama']!.map((t) => t.id),
      );
    });

    test('themesForWebRoute 对综合（空串/未知）返回空', () {
      expect(themesForWebRoute(''), isEmpty);
      expect(themesForWebRoute('nope'), isEmpty);
    });

    test('themedCategoryRoute 拼路径并校验 themeId', () {
      expect(
        themedCategoryRoute('real-drama', 'costume'),
        'real-drama/costume',
      );
      expect(
        () => themedCategoryRoute('real-drama', 'no-such'),
        throwsA(isA<HongguoRequestException>()),
      );
      // 题材属于对应类型：真人剧的 costume 不在漫剧词表里。
      expect(
        () => themedCategoryRoute('comic-drama', 'costume'),
        throwsA(isA<HongguoRequestException>()),
      );
    });
  });

  group('题材词表 drift（LIVE）', () {
    final skip = Platform.environment['LIVE'] == '1' ? null : '设置 LIVE=1 才打真接口';

    for (final route in const ['real-drama', 'comic-drama', 'ai-drama']) {
      test(
        '$route 硬编码词表与 live selectorList 一致',
        () async {
          final client = HongguoClient();
          final body = await client.fetchText(
            '$webBaseUrl/category/$route',
            referer: '$webBaseUrl/',
          );
          final page = routerLoaderMap(parseRouterData(body), const [
            'category_page',
            r'category_$',
          ]);
          final liveIds = <String>{};
          for (final row in (page?['selectorList'] as List? ?? const [])) {
            if (row is! Map) continue;
            for (final item in (row['items'] as List? ?? const [])) {
              if (item is Map && item['selector_item_id'] != null) {
                liveIds.add('${item['selector_item_id']}');
              }
            }
          }
          expect(liveIds, isNotEmpty, reason: '$route 没解出 selectorList');
          final localIds = categoryThemes[route]!.map((t) => t.id).toSet();
          expect(
            localIds,
            liveIds,
            reason: '$route 词表漂移：硬编码与上游不一致，更新 categoryThemes',
          );
        },
        skip: skip,
        timeout: const Timeout(Duration(minutes: 2)),
      );
    }
  });
}
