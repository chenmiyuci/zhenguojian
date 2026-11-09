import 'catalog_sort.dart';
import 'follow_state.dart';
import 'models.dart';

const _hongguoSeriesLimit = 200;

/// 系列识别规则变化时递增，让旧落盘缓存失效重建。
const seriesSeasonsCacheVersion = 2;

// 标题末尾的季号后缀：第2季 / 44季 / 2部 / 二 / 3。基础名相同即为一剧。
final _seasonSuffix = RegExp(
  r'[\s　]*第?\s*([0-9零〇一二两兩三四五六七八九十百]{1,7})\s*([季部])?[\s　，。！？、：；·「」『』（）【】《》“”‘’.,!?:;\-_/()\[\]{}]*$',
);

// 季号在开头：第2季 剧名 → 基础名取开头之后的部分。
final _seasonPrefix = RegExp(
  r'^第\s*([0-9零〇一二两兩三四五六七八九十百]+)\s*([季部])[\s　]+(\S.*)$',
);

class HongguoSeriesInfo {
  const HongguoSeriesInfo({
    required this.baseTitle,
    required this.key,
    required this.season,
    required this.unit,
    required this.explicit,
  });

  final String baseTitle;
  final String key;
  final int season;
  final String unit;
  final bool explicit;
}

class HongguoSeriesEntry {
  const HongguoSeriesEntry({
    required this.drama,
    required this.season,
    required this.unit,
  });

  final Drama drama;
  final int season;
  final String unit;

  String get label => '第 $season $unit';

  Map<String, Object?> toJson() => {
    'drama': drama.toJson(),
    'season': season,
    'unit': unit,
  };

  factory HongguoSeriesEntry.fromJson(Map<String, dynamic> json) =>
      HongguoSeriesEntry(
        drama: Drama.fromJson(Map<String, dynamic>.from(json['drama'] as Map)),
        season: json['season'] as int,
        unit: json['unit'] as String,
      );
}

int? _seasonNumber(String label) {
  final numeric = int.tryParse(label);
  if (numeric != null) {
    return numeric >= 1 && numeric <= _hongguoSeriesLimit ? numeric : null;
  }
  const digits = {
    '零': 0,
    '〇': 0,
    '一': 1,
    '二': 2,
    '两': 2,
    '兩': 2,
    '三': 3,
    '四': 4,
    '五': 5,
    '六': 6,
    '七': 7,
    '八': 8,
    '九': 9,
  };
  var number = 0;
  if (!label.contains(RegExp('[十百]'))) {
    for (final rune in label.runes) {
      final digit = digits[String.fromCharCode(rune)];
      if (digit == null) return null;
      number = number * 10 + digit;
      if (number > _hongguoSeriesLimit) return null;
    }
    return number >= 1 ? number : null;
  }
  var digit = 0;
  var previous = 1000;
  for (final rune in label.runes) {
    final character = String.fromCharCode(rune);
    final value = digits[character];
    if (value != null) {
      digit = digit * 10 + value;
      continue;
    }
    final multiplier = character == '百' ? 100 : 10;
    if (multiplier >= previous || digit > 9) return null;
    number += (digit == 0 ? 1 : digit) * multiplier;
    digit = 0;
    previous = multiplier;
  }
  number += digit;
  return number >= 1 && number <= _hongguoSeriesLimit ? number : null;
}

HongguoSeriesInfo? hongguoSeriesInfo(Drama drama, {String? unit}) {
  if (drama.source != SourceSite.hongguo.id) return null;
  final title = drama.title.trim();
  if (title.isEmpty) return null;
  final prefix = _seasonPrefix.firstMatch(title);
  if (prefix != null) {
    final base = prefix[3]!.trim();
    final season = _seasonNumber(prefix[1]!);
    if (base.isNotEmpty && season != null) {
      return HongguoSeriesInfo(
        baseTitle: base,
        key: normalizedSearchText(base),
        season: season,
        unit: '季',
        explicit: true,
      );
    }
  }
  final match = _seasonSuffix.firstMatch(title);
  if (match != null) {
    final base = title.substring(0, match.start).trim();
    final season = _seasonNumber(match[1]!);
    if (base.isNotEmpty && season != null) {
      return HongguoSeriesInfo(
        baseTitle: base,
        key: normalizedSearchText(base),
        season: season,
        unit: '季',
        explicit: true,
      );
    }
  }
  if (unit == null) return null;
  return HongguoSeriesInfo(
    baseTitle: title,
    key: normalizedSearchText(title),
    season: 1,
    unit: '季',
    explicit: false,
  );
}

List<HongguoSeriesEntry> hongguoSeriesEntries(
  Drama anchor,
  Iterable<Drama> candidates,
) {
  if (anchor.source != SourceSite.hongguo.id) return const [];
  var anchorInfo = hongguoSeriesInfo(anchor);
  String key;
  int anchorSeason;
  if (anchorInfo == null) {
    key = normalizedSearchText(anchor.title);
    anchorSeason = 1;
    anchorInfo = hongguoSeriesInfo(anchor, unit: '季');
  } else {
    key = anchorInfo.key;
    anchorSeason = anchorInfo.season;
  }
  if (anchorInfo == null) return const [];
  final byId = <String, HongguoSeriesEntry>{};
  for (final drama in [anchor, ...candidates]) {
    if (drama.source != SourceSite.hongguo.id) continue;
    final info = hongguoSeriesInfo(drama, unit: '季');
    if (info == null || info.key != key) continue;
    byId[drama.id] = HongguoSeriesEntry(
      drama: drama,
      season: drama.id == anchor.id ? anchorSeason : info.season,
      unit: '季',
    );
  }
  final entries = byId.values.toList()
    ..sort((a, b) {
      final season = a.season.compareTo(b.season);
      return season != 0
          ? season
          : naturalTitleCompare(a.drama.title, b.drama.title);
    });
  return entries.length > 1 ? entries : const [];
}

FollowState observeHongguoSeriesSeasons({
  required Drama anchor,
  required FollowState state,
  required Iterable<Drama> candidates,
  required Set<String> favoriteIds,
}) {
  final entries = hongguoSeriesEntries(anchor, candidates);
  if (entries.isEmpty) return state;
  final anchorSeason = entries
      .where((entry) => entry.drama.id == anchor.id)
      .firstOrNull
      ?.season;
  if (anchorSeason == null) return state;
  var seasons = state.seriesSeasons;
  for (final id in seasons.keys.toList()) {
    if (id == anchor.id || favoriteIds.contains(id)) {
      seasons = Map.of(seasons)..remove(id);
    }
  }
  for (final entry in entries) {
    if (entry.drama.id == anchor.id ||
        favoriteIds.contains(entry.drama.id) ||
        entry.season <= anchorSeason) {
      continue;
    }
    final previous = seasons[entry.drama.id];
    final notice = SeriesSeasonNotice(
      id: entry.drama.id,
      title: entry.drama.title,
      season: entry.season,
      unit: entry.unit,
      read: previous?.read ?? false,
    );
    if (previous?.title == notice.title &&
        previous?.season == notice.season &&
        previous?.unit == notice.unit &&
        previous?.read == notice.read) {
      continue;
    }
    seasons = Map.of(seasons)..[notice.id] = notice;
  }
  return identical(seasons, state.seriesSeasons)
      ? state
      : state.copyWith(seriesSeasons: seasons);
}
