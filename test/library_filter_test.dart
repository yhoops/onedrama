import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_dart/hongguo_dart.dart';
import 'package:onedrama/data/library_filter.dart';

/// `applyLibraryFilters` 的守卫：本地状态/篇幅过滤 + 排序，且「缺数据排最后」。
///
/// 这类顺序/过滤逻辑写反了不报错，只表现成很隐蔽的「列表顺序不对」，所以钉死。
Drama _d(
  String id, {
  String status = '',
  String ep = '',
  String heat = '',
  String views = '',
  String online = '',
  String title = '',
}) =>
    Drama(
      id: id,
      title: title.isEmpty ? id : title,
      releaseStatus: status,
      episodeCount: ep,
      heat: heat,
      views: views,
      onlineDate: online,
    );

List<String> _ids(List<Drama> list) => list.map((d) => d.id).toList();

void main() {
  test('状态过滤：连载中 / 已完结 各取对应 releaseStatus', () {
    final src = [
      _d('a', status: 'ongoing'),
      _d('b', status: 'finished'),
      _d('c', status: ''),
    ];
    expect(_ids(applyLibraryFilters(src, status: LibraryStatus.ongoing)), ['a']);
    expect(_ids(applyLibraryFilters(src, status: LibraryStatus.finished)), ['b']);
    expect(_ids(applyLibraryFilters(src, status: LibraryStatus.any)),
        ['a', 'b', 'c']);
  });

  test('60集内：解不出集数或超过 60 的都剔除', () {
    final src = [_d('a', ep: '30'), _d('b', ep: '60'), _d('c', ep: '61'), _d('d')];
    expect(_ids(applyLibraryFilters(src, withinSixty: true)), ['a', 'b']);
  });

  test('集数少优先：升序，缺集数排最后', () {
    final src = [_d('a', ep: '80'), _d('b'), _d('c', ep: '10'), _d('d', ep: '40')];
    expect(_ids(applyLibraryFilters(src, sort: LibrarySort.fewestEpisodes)),
        ['c', 'd', 'a', 'b']);
  });

  test('热度：降序，缺热度排最后', () {
    final src = [_d('a', heat: '100'), _d('b'), _d('c', heat: '900')];
    expect(_ids(applyLibraryFilters(src, sort: LibrarySort.heat)),
        ['c', 'a', 'b']);
  });

  test('播放量：降序，缺的排最后', () {
    final src = [_d('a', views: '5'), _d('b', views: '50'), _d('c')];
    expect(_ids(applyLibraryFilters(src, sort: LibrarySort.views)),
        ['b', 'a', 'c']);
  });

  test('最新上线：onlineDate 降序，缺日期排最后', () {
    final src = [
      _d('a', online: '2024-01-01'),
      _d('b'),
      _d('c', online: '2025-06-01'),
    ];
    expect(_ids(applyLibraryFilters(src, sort: LibrarySort.latest)),
        ['c', 'a', 'b']);
  });

  test('剧名：按字符升序', () {
    final src = [_d('a', title: 'Cc'), _d('b', title: 'Aa'), _d('c', title: 'Bb')];
    expect(applyLibraryFilters(src, sort: LibrarySort.title).map((d) => d.title),
        ['Aa', 'Bb', 'Cc']);
  });

  test('默认排序保持原序；相等键稳定不乱序', () {
    final src = [_d('a', ep: '10'), _d('b', ep: '10'), _d('c', ep: '10')];
    expect(_ids(applyLibraryFilters(src, sort: LibrarySort.none)), ['a', 'b', 'c']);
    // 集数都相等 → 稳定：仍是原序
    expect(_ids(applyLibraryFilters(src, sort: LibrarySort.fewestEpisodes)),
        ['a', 'b', 'c']);
  });

  test('过滤 + 排序组合：已完结 + 集数少优先', () {
    final src = [
      _d('a', status: 'finished', ep: '50'),
      _d('b', status: 'ongoing', ep: '10'),
      _d('c', status: 'finished', ep: '20'),
    ];
    expect(
      _ids(applyLibraryFilters(src,
          status: LibraryStatus.finished, sort: LibrarySort.fewestEpisodes)),
      ['c', 'a'],
    );
  });
}
