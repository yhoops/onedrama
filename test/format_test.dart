import 'package:flutter_test/flutter_test.dart';
import 'package:onedrama/ui/format.dart';

/// 期望值来自真接口采样（`E:/Env/tmp/raw_detail.json`、榜单 `heatText`、
/// 网页 `seriesSocialInfo`），不是照着重算的——两边独立对上了才算对。
///
/// | 原始 | 上游原样 |
/// | --- | --- |
/// | `hot_score 42033495` | `4203万热度`（App `series_sub_title_list` 与网页 `hot_score_data.text` 都是这个） |
/// | `hot_score 94677019` | `9467万热度`（榜单 `heatText`） |
/// | `rating_count 33371` | `3.3万人评分` |
/// | `series_like_count 3266000` | `326.6万` |
void main() {
  group('热度：整数万、截断、无小数', () {
    test('与上游文本逐字一致', () {
      expect(heatLabel('42033495'), '4203万热度');
      expect(heatLabel('94677019'), '9467万热度');
      expect(heatLabel('89220262'), '8922万热度');
      expect(heatLabel('69976091'), '6997万热度');
      expect(heatLabel('6036万'), '6036万热度');
    });

    test('上游已给文本时沿用它的量级，只统一后缀', () {
      expect(heatLabel('4203万热度'), '4203万热度');
      expect(heatLabel('红果热度值4203万'), '4203万热度');
    });

    test('截断不是四舍五入', () {
      // 94677019 / 10000 = 9467.7019 → 9467，不是 9468。
      expect(heatLabel('94677019'), '9467万热度');
      // 99999999 差 1 就到 1 亿，仍按万算。
      expect(heatLabel('99999999'), '9999万热度');
    });

    test('不到 1 万原样，空值不显示', () {
      expect(heatLabel('9532'), '9532热度');
      expect(heatLabel(''), '');
      expect(heatLabel('   '), '');
    });

    test('亿档', () {
      expect(heatLabel('123456789'), '1亿热度');
      expect(heatLabel('250000000'), '2亿热度');
    });
  });

  group('观看人数：一位小数、截断、本地合成后缀', () {
    test('真机上的那两个数字', () {
      expect(viewsLabel('2977018'), '297.7万人看过');
      expect(viewsLabel('42033495'), '4203.3万人看过');
    });

    test('小数位是截断的', () {
      // 2506000 / 10000 = 250.6 整；33371 / 10000 = 3.3371 → 3.3
      expect(viewsLabel('2506000'), '250.6万人看过');
      expect(viewsLabel('33371'), '3.3万人看过');
      // 整数万时不留 .0
      expect(viewsLabel('10000'), '1万人看过');
      expect(viewsLabel('20000'), '2万人看过');
    });

    test('不到 1 万原样', () {
      expect(viewsLabel('9532'), '9532人看过');
    });
  });

  group('评分', () {
    test('一位小数 + 「分」', () {
      expect(scoreLabel('9.2'), '9.2分');
      expect(scoreLabel('9'), '9.0分');
      expect(scoreLabel('6.7'), '6.7分');
    });
  });

  group('认不出来的输入不丢信息', () {
    test('非数字原样返回', () {
      expect(heatLabel('暂无'), '暂无');
      expect(viewsLabel('未知'), '未知');
      expect(scoreLabel(''), '');
    });
  });
}
