import 'package:flutter_test/flutter_test.dart';
import 'package:onedrama/data/search_history.dart';

/// 搜索历史的记词规则（`docs/plan.md` 阶段 5a）。
///
/// 顺序或截断写反都不会报错，只会表现成「历史怪怪的」——所以钉住。
void main() {
  group('记一个词', () {
    test('新词插到最前', () {
      expect(pushSearchKeyword(['b', 'a'], 'c'), ['c', 'b', 'a']);
    });

    test('已有的词提到最前，不重复留两份', () {
      expect(pushSearchKeyword(['a', 'b', 'c'], 'c'), ['c', 'a', 'b']);
      // 已经在最前时保持原样（不是重排）。
      expect(pushSearchKeyword(['c', 'a', 'b'], 'c'), ['c', 'a', 'b']);
    });

    test('两头的空白抹掉；全是空白就当没搜', () {
      expect(pushSearchKeyword(['a'], '  b  '), ['b', 'a']);
      expect(pushSearchKeyword(['a'], '   '), ['a']);
      expect(pushSearchKeyword(['a'], ''), ['a']);
    });

    test('超过上限从最老那头挤掉，不是从新的一头', () {
      final full = [for (var i = 0; i < searchHistoryLimit; i++) 'w$i'];
      final next = pushSearchKeyword(full, 'brand-new');

      expect(next.length, searchHistoryLimit);
      expect(next.first, 'brand-new');
      // 最老的那条走了，剩下 19 条原样跟在后面。
      expect(next.contains('w${searchHistoryLimit - 1}'), isFalse);
      expect(next.sublist(1), full.sublist(0, searchHistoryLimit - 1));
    });

    test('重复提最前之后也不会超上限', () {
      final full = [for (var i = 0; i < searchHistoryLimit; i++) 'w$i'];
      final next = pushSearchKeyword(full, 'w${searchHistoryLimit - 1}');
      expect(next.length, searchHistoryLimit);
      expect(next.first, 'w${searchHistoryLimit - 1}');
    });
  });
}
