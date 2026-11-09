import 'package:duanju_app/drama_details.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/local_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

DramaDetails _open(FakeRepository repository, LocalStore store, Drama drama) {
  final details = DramaDetails(repository, store, drama);
  addTearDown(details.dispose);
  return details;
}

void main() {
  final first = drama('a', title: '剧甲');

  test('loads episodes and opens the group of the resume episode', () async {
    final repository = FakeRepository()
      ..details[first.id] = dramaDetail(
        Drama(id: first.id, source: first.source, title: '剧甲', tags: ['甜宠']),
      );
    final store = await openStore();
    await store.saveWatch(watching(first, episode: 35));
    final details = _open(repository, store, first);
    await pumpEventQueue();

    expect(details.loading, isFalse);
    expect(details.drama.tags, ['甜宠']);
    expect(details.episodes, hasLength(80));
    expect(details.groupCount, 3);
    expect(details.group, 1);
    expect(details.groupLabel(2), '61-80');
    expect(details.groupEpisodes.first.number, 31);
    expect(details.currentIndex, 34);
    expect(details.resumeIndex, 34);

    details.selectGroup(2);
    expect(details.groupEpisodes.map((episode) => episode.number).last, 80);
  });

  test('a finished episode resumes from the next one', () async {
    final repository = FakeRepository()
      ..details[first.id] = dramaDetail(first, count: 10);
    final store = await openStore();
    await store.saveWatch(watching(first, episode: 4, position: 100));
    final details = _open(repository, store, first);
    await pumpEventQueue();

    expect(details.currentIndex, 3);
    expect(details.resumeIndex, 4);
    expect(details.groupCount, 1);
  });

  test('failures keep the drama and can be retried', () async {
    final repository = FakeRepository()..detailFailure = '站源超时';
    final details = _open(repository, await openStore(), first);
    await pumpEventQueue();

    expect(details.error, contains('站源超时'));
    expect(details.drama.title, '剧甲');
    expect(details.episodes, isEmpty);

    repository
      ..detailFailure = ''
      ..details[first.id] = dramaDetail(first, count: 3);
    await details.load();
    expect(details.error, isNull);
    expect(details.episodes, hasLength(3));
  });

  test('sources outside the profile are never requested', () async {
    final repository = FakeRepository();
    final store = await openStore(viewerPreferences);
    final details = _open(repository, store, drama('x', source: 'dsd'));
    await pumpEventQueue();

    expect(details.allowed, isFalse);
    expect(repository.detailRequests, 0);
  });

  test('a hongguo drama discovers the seasons of its series', () async {
    final second = drama('s2', title: '剧甲 第2季');
    final third = drama('s3', title: '剧甲 第3季');
    final repository = FakeRepository()
      ..details[first.id] = dramaDetail(first, count: 3)
      ..searchResults[first.title] = [first, second, third];
    final details = _open(repository, await openStore(), first);
    await pumpEventQueue();

    expect(details.seasons, hasLength(3));
    expect(details.seasons.map((entry) => entry.label).toList(), [
      '第 1 季',
      '第 2 季',
      '第 3 季',
    ]);
    expect(details.seasons.map((entry) => entry.drama.id), containsAll([first.id, second.id, third.id]));
  });

  test('season search failure or no series keeps seasons empty', () async {
    final repository = FakeRepository()
      ..details[first.id] = dramaDetail(first, count: 3)
      ..searchFailure = '搜索超时';
    final details = _open(repository, await openStore(), first);
    await pumpEventQueue();

    expect(details.seasons, isEmpty);
    expect(details.error, isNull);

    repository.searchFailure = '';
    details.load();
    await pumpEventQueue();
    expect(details.seasons, isEmpty);
  });
}
