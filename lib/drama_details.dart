import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'core_bridge.dart';
import 'follow_state.dart';
import 'hongguo_series.dart';
import 'local_store.dart';
import 'models.dart';

const episodeGroupSize = 30;

class DramaDetails extends ChangeNotifier {
  DramaDetails(
    this.repository,
    this.store,
    Drama drama, {
    List<Drama> candidates = const [],
  }) : _drama = repository.catalogUpdates.current(drama),
       _candidates = candidates,
       _epoch = store.profileEpoch {
    store.addListener(_notify);
    load();
  }
  final AppRepository repository;
  final LocalStore store;
  final List<Drama> _candidates;
  final int _epoch;
  Drama _drama;
  List<Episode> _episodes = const [];
  List<HongguoSeriesEntry> _seasons = const [];
  int _seasonShown = 10;
  int _nextSeasonPage = 1;
  bool _seasonHasMore = true;
  bool _seasonLoading = false;
  String _warning = '';
  String? _error;
  bool _loading = false;
  int _group = 0;
  int _generation = 0;
  bool _disposed = false;

  Drama get drama => _drama;
  List<Episode> get episodes => _episodes;
  List<HongguoSeriesEntry> get seasons => _seasons;
  List<HongguoSeriesEntry> get shownSeasons =>
      _seasons.take(_seasonShown).toList();
  bool get hasMoreSeasons => _seasonHasMore || _seasonShown < _seasons.length;
  bool get seasonsLoading => _seasonLoading;
  String get warning => _warning;
  String? get error => _error;
  bool get loading => _loading;
  bool get allowed =>
      store.profileEpoch == _epoch && store.allowsSource(_drama.source);
  WatchEntry? get watch => allowed ? store.watched(_drama.id) : null;
  int get resumeIndex => resumeEpisodeIndex(_episodes, watch);
  int? get currentIndex {
    final number = watch?.episode;
    final index = _episodes.indexWhere((episode) => episode.number == number);
    return index < 0 ? null : index;
  }

  int get groupCount => (_episodes.length / episodeGroupSize).ceil();
  int get group => _group;
  List<Episode> get groupEpisodes =>
      _episodes.skip(_group * episodeGroupSize).take(episodeGroupSize).toList();

  String groupLabel(int group) {
    final start = group * episodeGroupSize;
    final end = (start + episodeGroupSize).clamp(0, _episodes.length) - 1;
    return '${_episodes[start].number}-${_episodes[end].number}';
  }

  void selectGroup(int group) {
    if (group == _group || group < 0 || group >= groupCount) return;
    _group = group;
    _notify();
  }

  Future<void> load() async {
    if (!allowed) return;
    final generation = ++_generation;
    _loading = true;
    _error = null;
    _notify();
    try {
      final detail = await repository.detail(_drama);
      if (!_current(generation)) return;
      _drama = repository.catalogUpdates.current(_drama).merge(detail.drama);
      _episodes = detail.episodes;
      _warning = detail.warning;
      _group = groupCount == 0 ? 0 : resumeIndex ~/ episodeGroupSize;
      _loading = false;
      _notify();
      repository.catalogUpdates.publish(_drama, retryCover: true);
      unawaited(store.refreshDrama(_drama).catchError((Object _) {}));
      unawaited(_supplement(generation));
      unawaited(_loadSeasons(generation));
    } catch (error) {
      if (!_current(generation)) return;
      _error = error.toString();
      _loading = false;
      _notify();
      repository.catalogUpdates.publish(_drama, retryCover: true);
    }
  }

  Future<void> _supplement(int generation) async {
    try {
      final fresh = await repository.supplementMetadata(_drama);
      if (fresh == null || !_current(generation)) return;
      _drama = _drama.merge(fresh);
      _notify();
      repository.catalogUpdates.publish(_drama);
      await store.refreshDrama(_drama);
    } catch (_) {}
  }

  Future<void> _loadSeasons(int generation) async {
    if (_drama.source != SourceSite.hongguo.id) return;
    final cached = store.seriesSeasons(_drama.id);
    if (cached != null) {
      _seasons = cached;
      _seasonShown = math.min(
        math.max(store.seriesSeasonsShown(_drama.id), 10),
        cached.length,
      );
      _seasonHasMore = false;
      _notify();
      return;
    }
    // 来源页面（搜索/分类/推荐）已加载的剧先算一遍，够一批就不必请求。
    if (_applySeasons(hongguoSeriesEntries(_drama, _candidates), generation)) {
      return;
    }
    await _fetchSeasonBatch(generation);
  }

  /// 只发一次 page=1：Go 核心会做名称检索 + 系列季补全，一次拿全整个系列。
  Future<void> _fetchSeasonBatch(int generation) async {
    if (_seasonLoading || !_seasonHasMore || !_current(generation)) return;
    final base = hongguoSeriesInfo(_drama)?.baseTitle ?? _drama.title.trim();
    if (base.isEmpty) return;
    _seasonLoading = true;
    _notify();
    try {
      final page = await repository.catalog(
        SourceSite.hongguo.id,
        query: base,
      );
      if (!_current(generation)) return;
      final seasons = hongguoSeriesEntries(_drama, [
        ..._candidates,
        ...page.items,
      ]);
      if (seasons.length > _seasons.length) {
        _seasons = seasons;
      }
      // 核心已在 page=1 补全整个系列，不再翻页；10 条分批纯本地。
      _seasonHasMore = false;
      _nextSeasonPage = 2;
      unawaited(store.saveSeriesSeasons(_drama.id, _seasons));
    } catch (_) {
    } finally {
      _seasonLoading = false;
      if (_current(generation)) _notify();
    }
  }

  bool _applySeasons(List<HongguoSeriesEntry> seasons, int generation) {
    if (seasons.isEmpty || !_current(generation)) return false;
    _seasons = seasons;
    _seasonHasMore = false;
    _notify();
    unawaited(store.saveSeriesSeasons(_drama.id, _seasons));
    return true;
  }

  /// 菜单滚动到底时再显示下一批 10 季；数据已在内存里，不再打网络。
  void loadMoreSeasons() {
    if (_seasonShown >= _seasons.length) return;
    _seasonShown = math.min(_seasonShown + 10, _seasons.length);
    _notify();
    unawaited(
      store.saveSeriesSeasons(_drama.id, _seasons, shown: _seasonShown),
    );
  }

  bool _current(int generation) =>
      !_disposed && generation == _generation && allowed;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    store.removeListener(_notify);
    super.dispose();
  }
}
