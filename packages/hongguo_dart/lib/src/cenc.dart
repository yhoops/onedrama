import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// CENC（ISO/IEC 23001-7）样本解密所需的解析与密码学。
///
/// **为什么需要这个**：红果 App 源的每个样本都是整段 AES-128-CTR 加密的，
/// 连 NAL 长度前缀都是密文。media3 的 `Mp4Extractor` 在 `nalUnitLengthFieldLength != 0`
/// 时无条件把 length-prefixed NAL 转成 Annex-B，**代码里没有任何加密分支**，所以
/// 会把密文当长度读、抛 `ParserException: Invalid NAL length`（真机实测）。
/// `pssh`、MediaDrm、ClearKey 都救不了——只能自己解。
///
/// 实测的红果形态：`schm=cenc`、**整样本加密**、`senc` 逐样本 **8 字节 IV**、
/// 无 subsample（`senc` flags=0，`saiz` 每样本恰好 8）。
///
/// 与 Go 包无关：那边明确「只给密钥，不解封装」。

/// MP4 盒子。`start` 含 8 字节头。
class Mp4Box {
  const Mp4Box(this.type, this.start, this.size);

  final String type;
  final int start;
  final int size;

  int get payload => start + 8;
  int get end => start + size;

  @override
  String toString() => '$type@$start+$size';
}

/// 会往里走的容器盒子。其它盒子一律当叶子。
const Set<String> mp4ContainerTypes = <String>{
  'moov', 'trak', 'mdia', 'minf', 'stbl', 'mvex', 'moof', 'traf',
  'edts', 'dinf', 'udta', 'schi', 'sinf', 'mfra', 'skip',
};

/// 走一段字节里的同级盒子。
List<Mp4Box> mp4Children(Uint8List data, int from, int to) {
  final out = <Mp4Box>[];
  var offset = from;
  final limit = to < data.length ? to : data.length;
  while (offset + 8 <= limit) {
    var size = _u32(data, offset);
    final type = String.fromCharCodes(data.sublist(offset + 4, offset + 8));
    if (size == 1) {
      if (offset + 16 > limit) break;
      size = _u64(data, offset + 8);
    } else if (size == 0) {
      size = limit - offset;
    }
    if (size < 8) break;
    out.add(Mp4Box(type, offset, size));
    offset += size;
  }
  return out;
}

/// 取父盒子的直接子盒子。
List<Mp4Box> mp4ChildrenOf(Uint8List data, Mp4Box parent) =>
    mp4Children(data, parent.payload, parent.end);

Mp4Box? mp4Child(Uint8List data, Mp4Box parent, String type) {
  for (final box in mp4ChildrenOf(data, parent)) {
    if (box.type == type) return box;
  }
  return null;
}

/// 逐层往下找。
Mp4Box? mp4Descend(Uint8List data, Mp4Box from, List<String> path) {
  var current = from;
  for (final name in path) {
    final next = mp4Child(data, current, name);
    if (next == null) return null;
    current = next;
  }
  return current;
}

/// 顶层找第一个指定类型的盒子。
Mp4Box? mp4Top(Uint8List data, String type) => mp4Child(
      data,
      Mp4Box('root', -8, data.length + 8),
      type,
    );

/// 一个加密样本。
class CencSample {
  const CencSample({
    required this.offset,
    required this.size,
    required this.iv,
  });

  /// 文件里的绝对偏移。
  final int offset;

  final int size;

  /// 8 或 16 字节的初始向量。
  final Uint8List iv;

  int get end => offset + size;
}

/// 一条轨道的样本。
class CencTrack {
  const CencTrack({required this.handler, required this.samples});

  /// `vide` / `soun`，来自 `hdlr`。
  final String handler;

  final List<CencSample> samples;
}

/// 整段流的 CENC 索引。
class CencIndex {
  const CencIndex({required this.tracks, required this.samples});

  final List<CencTrack> tracks;

  /// 跨轨合并、按文件偏移排序。数据源按字节范围查样本时二分这个。
  final List<CencSample> samples;

  /// 从（至少含完整 `moov` 的）文件头部解析。
  ///
  /// 解析不出来时返回 null——调用方应当据此判定「这条流不是我们认识的形态」，
  /// 而不是硬解出一堆乱码。
  static CencIndex? parse(Uint8List data) {
    final moov = mp4Top(data, 'moov');
    if (moov == null) return null;

    final tracks = <CencTrack>[];
    final merged = <CencSample>[];

    for (final trak in mp4ChildrenOf(data, moov)) {
      if (trak.type != 'trak') continue;
      final stbl = mp4Descend(data, trak, const ['mdia', 'minf', 'stbl']);
      if (stbl == null) continue;

      final geometry = _sampleGeometry(data, stbl);
      if (geometry.isEmpty) continue;

      final ivSize = _ivSize(data, stbl);
      if (ivSize == null) continue;

      final ivs = _sampleIvs(data, stbl, ivSize);
      if (ivs.length < geometry.length) continue;

      final samples = <CencSample>[];
      for (var i = 0; i < geometry.length; i++) {
        samples.add(
          CencSample(
            offset: geometry[i].offset,
            size: geometry[i].size,
            iv: ivs[i],
          ),
        );
      }
      tracks.add(CencTrack(handler: _handler(data, trak), samples: samples));
      merged.addAll(samples);
    }

    if (merged.isEmpty) return null;
    merged.sort((left, right) => left.offset.compareTo(right.offset));
    return CencIndex(tracks: tracks, samples: merged);
  }
}

/// AES-128-CTR 解密，counter 语义按 ISO 23001-7 的 8 字节 IV：
///
/// counter 块 = `IV` ‖ `00000000_00000000`，低 8 字节按**大端**对每个 16 字节块递增。
/// 高 8 字节在整个样本内不变。
Uint8List aesCtrDecrypt(Uint8List key, Uint8List iv, Uint8List input) {
  // CTR 的 keystream 必须用 AES 的**加密**方向生成：ks = AES_encrypt(counter)。
  // 用解密方向会得到逆密码流，结果静默全错（踩过一次）。
  final engine = AESEngine()..init(true, KeyParameter(key));
  final counter = Uint8List(16);
  final copy = iv.length < 8 ? iv.length : 8;
  counter.setRange(0, copy, iv);

  final out = Uint8List(input.length);
  final keystream = Uint8List(16);
  for (var offset = 0; offset < input.length; offset += 16) {
    engine.processBlock(counter, 0, keystream, 0);
    final span = input.length - offset < 16 ? input.length - offset : 16;
    for (var i = 0; i < span; i++) {
      out[offset + i] = input[offset + i] ^ keystream[i];
    }
    for (var i = 15; i >= 8; i--) {
      counter[i] = (counter[i] + 1) & 0xff;
      if (counter[i] != 0) break;
    }
  }
  return out;
}

/// 按 4 字节长度前缀走一遍 AVCC 样本。
///
/// 这是「解密对不对」最直接的判据：明文 AVCC 样本应当能严丝合缝地走完。
({bool ok, int nalUnits}) walkAvcc(Uint8List sample) {
  var offset = 0;
  var nalUnits = 0;
  while (offset + 4 <= sample.length) {
    final length = _u32(sample, offset);
    if (length <= 0 || offset + 4 + length > sample.length) {
      return (ok: false, nalUnits: nalUnits);
    }
    offset += 4 + length;
    nalUnits++;
  }
  return (ok: offset == sample.length, nalUnits: nalUnits);
}

/// 一处**等长**字节替换。
///
/// 等长是刻意的：`moov` 尺寸不变 → `mdat` 不移动 → `stco`/`co64` 里那些**绝对**
/// 文件偏移一个都不用重算。改长度就要连带修所有偏移，那是另一类 bug。
class BytePatch {
  const BytePatch(this.offset, this.bytes);

  final int offset;
  final Uint8List bytes;
}

/// 造一个指定长度的 `free` 盒子，用来原地顶掉加密盒子。解析器会跳过它。
Uint8List freeBoxOfSize(int size) {
  if (size < 8) {
    throw ArgumentError('free 盒子至少要 8 字节，收到 $size');
  }
  final out = Uint8List(size);
  out[0] = (size >> 24) & 0xff;
  out[1] = (size >> 16) & 0xff;
  out[2] = (size >> 8) & 0xff;
  out[3] = size & 0xff;
  out[4] = 0x66; // f
  out[5] = 0x72; // r
  out[6] = 0x65; // e
  out[7] = 0x65; // e
  return out;
}

/// 造出把加密痕迹抹平的等长替换：`senc`/`saiz`/`saio`/`sinf`/`pssh` → `free`，
/// 样本条目的 `encv`/`enca` 还原成 `sinf`/`frma` 里记录的那个原始格式。
///
/// 为什么要抹：解出来之后数据已经是明文，再留着加密声明会让提取器把 `cryptoData`
/// 交给解码器，而又没有 DRM 会话，等于自己给自己下绊子。
List<BytePatch> buildNeutralizingPatches(Uint8List data) {
  final patches = <BytePatch>[];
  final moov = mp4Top(data, 'moov');
  if (moov == null) return patches;

  for (final child in mp4ChildrenOf(data, moov)) {
    if (child.type == 'pssh') {
      patches.add(BytePatch(child.start, freeBoxOfSize(child.size)));
      continue;
    }
    if (child.type != 'trak') continue;

    final stbl = mp4Descend(data, child, const ['mdia', 'minf', 'stbl']);
    if (stbl != null) {
      for (final box in mp4ChildrenOf(data, stbl)) {
        if (box.type == 'senc' || box.type == 'saiz' || box.type == 'saio') {
          patches.add(BytePatch(box.start, freeBoxOfSize(box.size)));
        }
      }
    }

    final stsd = mp4Child(data, stbl ?? child, 'stsd') ??
        mp4Descend(data, child, const ['mdia', 'minf', 'stbl', 'stsd']);
    if (stsd == null) continue;

    // stsd 是 FullBox：version+flags(4) + entry_count(4)，条目从 payload+8 起。
    for (final entry in mp4Children(data, stsd.payload + 8, stsd.end)) {
      if (entry.type != 'encv' && entry.type != 'enca') continue;
      // 样本条目的子盒子起点随 handler 而变，不去算它，直接找一个头部自洽的 sinf。
      final sinf = _wellFormedBox(data, entry.payload, entry.end, 'sinf');
      if (sinf == null) continue;

      final frma = mp4Child(data, sinf, 'frma');
      if (frma != null && frma.payload + 4 <= frma.end) {
        // frma 记录的就是被包起来的原始格式（这条流是 hvc1），还原它而不是写死 avc1。
        patches.add(
          BytePatch(
            entry.start + 4,
            Uint8List.fromList(data.sublist(frma.payload, frma.payload + 4)),
          ),
        );
      }
      patches.add(BytePatch(sinf.start, freeBoxOfSize(sinf.size)));
    }
  }
  return patches;
}

/// 把整段流解成一份可直接播放的明文 MP4。
///
/// 两件事：① 按 [patches] 抹掉加密痕迹；② 按样本索引解密。总长不变。
Uint8List decryptToClearFile({
  required Uint8List key,
  required CencIndex index,
  required Uint8List file,
  List<BytePatch> patches = const [],
}) {
  final out = Uint8List.fromList(file);
  for (final patch in patches) {
    if (patch.offset + patch.bytes.length > out.length) continue;
    out.setRange(patch.offset, patch.offset + patch.bytes.length, patch.bytes);
  }
  for (final sample in index.samples) {
    if (sample.end > out.length) break;
    final plain = aesCtrDecrypt(
      key,
      sample.iv,
      Uint8List.sublistView(out, sample.offset, sample.end),
    );
    out.setRange(sample.offset, sample.end, plain);
  }
  return out;
}

/// 在 [from, to) 里找一个头部自洽的指定盒子。
///
/// 样本条目的子盒子起点取决于 handler（视觉 78、音频 28 起，还随 version 变），
/// 与其把算术写对，不如按「size 字段自洽且不越界」来认。
Mp4Box? _wellFormedBox(Uint8List data, int from, int to, String type) {
  final needle = type.codeUnits;
  final limit = to < data.length ? to : data.length;
  for (var at = from; at + 8 <= limit; at++) {
    var matched = true;
    for (var i = 0; i < needle.length; i++) {
      if (data[at + i] != needle[i]) {
        matched = false;
        break;
      }
    }
    if (!matched) continue;
    final start = at - 4;
    if (start < 0) continue;
    final size = _u32(data, start);
    if (size < 8 || start + size > to) continue;
    return Mp4Box(type, start, size);
  }
  return null;
}

/// `hdlr` 里的 handler type。
String _handler(Uint8List data, Mp4Box trak) {
  final hdlr = mp4Descend(data, trak, const ['mdia', 'hdlr']);
  if (hdlr == null || hdlr.payload + 12 > data.length) return '';
  return String.fromCharCodes(
    data.sublist(hdlr.payload + 8, hdlr.payload + 12),
  );
}

/// 每个样本的（文件偏移、长度），按解码顺序。走 `stsz` + `stsc` + `stco`/`co64`。
List<({int offset, int size})> _sampleGeometry(Uint8List data, Mp4Box stbl) {
  final stsz = mp4Child(data, stbl, 'stsz');
  final stsc = mp4Child(data, stbl, 'stsc');
  final stco = mp4Child(data, stbl, 'stco');
  final co64 = mp4Child(data, stbl, 'co64');
  if (stsz == null || stsc == null || (stco == null && co64 == null)) {
    return const [];
  }

  final uniform = _u32(data, stsz.payload + 4);
  final count = _u32(data, stsz.payload + 8);
  final sizes = <int>[];
  if (uniform != 0) {
    sizes.addAll(List<int>.filled(count, uniform));
  } else {
    for (var i = 0; i < count && stsz.payload + 12 + i * 4 + 4 <= data.length; i++) {
      sizes.add(_u32(data, stsz.payload + 12 + i * 4));
    }
  }
  if (sizes.isEmpty) return const [];

  final chunkOffsets = <int>[];
  if (stco != null) {
    final chunks = _u32(data, stco.payload + 4);
    for (var i = 0; i < chunks && stco.payload + 8 + i * 4 + 4 <= data.length; i++) {
      chunkOffsets.add(_u32(data, stco.payload + 8 + i * 4));
    }
  } else {
    final chunks = _u32(data, co64!.payload + 4);
    for (var i = 0; i < chunks && co64.payload + 8 + i * 8 + 8 <= data.length; i++) {
      chunkOffsets.add(_u64(data, co64.payload + 8 + i * 8));
    }
  }
  if (chunkOffsets.isEmpty) return const [];

  final runs = <({int firstChunk, int perChunk})>[];
  final runCount = _u32(data, stsc.payload + 4);
  for (var i = 0; i < runCount; i++) {
    final base = stsc.payload + 8 + i * 12;
    if (base + 12 > data.length) break;
    runs.add((firstChunk: _u32(data, base), perChunk: _u32(data, base + 4)));
  }
  if (runs.isEmpty) return const [];

  final out = <({int offset, int size})>[];
  var sample = 0;
  for (var chunk = 0; chunk < chunkOffsets.length && sample < sizes.length; chunk++) {
    // stsc 的 firstChunk 是 1 基的，取最后一个 firstChunk <= chunk+1 的 run。
    var perChunk = runs.first.perChunk;
    for (final run in runs) {
      if (chunk + 1 >= run.firstChunk) perChunk = run.perChunk;
    }
    var offset = chunkOffsets[chunk];
    for (var i = 0; i < perChunk && sample < sizes.length; i++) {
      out.add((offset: offset, size: sizes[sample]));
      offset += sizes[sample];
      sample++;
    }
  }
  return out;
}

/// 每样本的辅助信息长度。红果实测 `saiz` 默认值是 8（正好只放 IV，无 subsample）。
int? _ivSize(Uint8List data, Mp4Box stbl) {
  final saiz = mp4Child(data, stbl, 'saiz');
  if (saiz == null) return null;
  final uniform = data[saiz.payload + 4];
  if (uniform == 8 || uniform == 16) return uniform;
  return null;
}

/// 按顺序读 `senc` 里的 IV。
List<Uint8List> _sampleIvs(Uint8List data, Mp4Box stbl, int ivSize) {
  final senc = mp4Child(data, stbl, 'senc');
  if (senc == null) return const [];
  final flags = (data[senc.payload + 1] << 16) |
      (data[senc.payload + 2] << 8) |
      data[senc.payload + 3];
  final count = _u32(data, senc.payload + 4);
  final hasSubsamples = (flags & 0x2) != 0;

  final out = <Uint8List>[];
  var cursor = senc.payload + 8;
  for (var i = 0; i < count; i++) {
    if (cursor + ivSize > senc.end || cursor + ivSize > data.length) break;
    out.add(Uint8List.fromList(data.sublist(cursor, cursor + ivSize)));
    cursor += ivSize;
    if (hasSubsamples) {
      if (cursor + 2 > data.length) break;
      final subsamples = (data[cursor] << 8) | data[cursor + 1];
      cursor += 2 + subsamples * 6;
    }
  }
  return out;
}

int _u32(Uint8List data, int offset) =>
    (data[offset] << 24) |
    (data[offset + 1] << 16) |
    (data[offset + 2] << 8) |
    data[offset + 3];

int _u64(Uint8List data, int offset) {
  var value = 0;
  for (var i = 0; i < 8; i++) {
    value = (value << 8) | data[offset + i];
  }
  return value;
}
