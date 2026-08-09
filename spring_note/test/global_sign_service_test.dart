import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:spring_note/core/models/global_sign_item.dart';
import 'package:spring_note/core/services/ai_client_service.dart';
import 'package:spring_note/core/services/global_sign_service.dart';

void main() {
  const service = GlobalSignService();

  test('global sign service writes and reads items round trip', () async {
    final temp = await Directory.systemTemp.createTemp(
      'spring_note_global_sign_',
    );
    addTearDown(() async {
      if (await temp.exists()) {
        await temp.delete(recursive: true);
      }
    });

    final created = DateTime(2026, 8, 1, 9, 30);
    final updated = DateTime(2026, 8, 3, 18, 45);
    await service.writeItems(
      appDataDir: temp.path,
      items: [
        GlobalSignItem(
          id: 'gs-abc-1',
          content: '跟进季度复盘',
          createdAt: created,
          updatedAt: updated,
        ),
      ],
    );

    final path = service.globalSignPath(temp.path);
    expect(path, endsWith('${Platform.pathSeparator}globalsign.json'));
    final savedJson = jsonDecode(await File(path).readAsString()) as Map;
    expect(savedJson['schemaVersion'], 1);
    expect(savedJson['items'], hasLength(1));

    final items = await service.readItems(appDataDir: temp.path);
    expect(items, hasLength(1));
    expect(items.single.id, 'gs-abc-1');
    expect(items.single.content, '跟进季度复盘');
    expect(items.single.createdAt, created);
    expect(items.single.updatedAt, updated);
  });

  test('removeItem deletes only the matching item', () async {
    final temp = await Directory.systemTemp.createTemp(
      'spring_note_global_sign_remove_',
    );
    addTearDown(() async {
      if (await temp.exists()) {
        await temp.delete(recursive: true);
      }
    });

    final now = DateTime(2026, 8, 4, 10, 30);
    await service.writeItems(
      appDataDir: temp.path,
      items: [
        GlobalSignItem(
          id: 'gs-1',
          content: '保留项',
          createdAt: now,
          updatedAt: now,
        ),
        GlobalSignItem(
          id: 'gs-2',
          content: '待删除项',
          createdAt: now,
          updatedAt: now,
        ),
      ],
    );

    await service.removeItem(appDataDir: temp.path, id: 'gs-2');

    final items = await service.readItems(appDataDir: temp.path);
    expect(items, hasLength(1));
    expect(items.single.id, 'gs-1');
  });

  test('global sign service tolerates missing, empty and corrupt files', () async {    final temp = await Directory.systemTemp.createTemp(
      'spring_note_global_sign_corrupt_',
    );
    addTearDown(() async {
      if (await temp.exists()) {
        await temp.delete(recursive: true);
      }
    });

    expect(await service.readItems(appDataDir: temp.path), isEmpty);

    final file = File(service.globalSignPath(temp.path));
    await file.writeAsString('   ');
    expect(await service.readItems(appDataDir: temp.path), isEmpty);

    await file.writeAsString('not json');
    expect(await service.readItems(appDataDir: temp.path), isEmpty);
  });

  test('reconcileItems keeps ids and timestamps for surviving items', () {
    final old = DateTime(2026, 8, 1, 9);
    final now = DateTime(2026, 8, 4, 10, 30);
    final existing = [
      GlobalSignItem(
        id: 'gs-keep-1',
        content: '保持不变',
        createdAt: old,
        updatedAt: old,
      ),
      GlobalSignItem(
        id: 'gs-edit-2',
        content: '原始内容',
        createdAt: old,
        updatedAt: old,
      ),
    ];

    final result = service.reconcileItems(
      existing: existing,
      drafts: const [
        GlobalSignDraftItem(id: 'gs-edit-2', content: '修订内容'),
        GlobalSignDraftItem(id: 'gs-keep-1', content: '保持不变'),
        GlobalSignDraftItem(id: '', content: '全新事项'),
      ],
      now: now,
    );

    expect(result, hasLength(3));

    expect(result[0].id, 'gs-edit-2');
    expect(result[0].content, '修订内容');
    expect(result[0].createdAt, old);
    expect(result[0].updatedAt, now);

    expect(result[1].id, 'gs-keep-1');
    expect(result[1].content, '保持不变');
    expect(result[1].createdAt, old);
    expect(result[1].updatedAt, old);

    expect(result[2].id, startsWith('gs-'));
    expect(result[2].content, '全新事项');
    expect(result[2].createdAt, now);
    expect(result[2].updatedAt, now);
  });

  test('reconcileItems drops missing and duplicate drafts safely', () {
    final old = DateTime(2026, 8, 1, 9);
    final now = DateTime(2026, 8, 4, 10, 30);
    final existing = [
      GlobalSignItem(
        id: 'gs-1',
        content: '保留',
        createdAt: old,
        updatedAt: old,
      ),
      GlobalSignItem(
        id: 'gs-2',
        content: '被移除',
        createdAt: old,
        updatedAt: old,
      ),
    ];

    final result = service.reconcileItems(
      existing: existing,
      drafts: const [
        GlobalSignDraftItem(id: 'gs-1', content: '保留'),
        GlobalSignDraftItem(id: 'gs-1', content: '重复的同一 id'),
        GlobalSignDraftItem(id: '', content: '   '),
      ],
      now: now,
    );

    expect(result, hasLength(2));
    expect(result[0].id, 'gs-1');
    expect(result[1].id, isNot('gs-1'));
    expect(result[1].id, isNot('gs-2'));
    expect(result[1].content, '重复的同一 id');
  });

  test('itemsToPromptJson renders id and content only', () {
    final json = service.itemsToPromptJson([
      GlobalSignItem(
        id: 'gs-1',
        content: '内容',
        createdAt: DateTime(2026, 8, 1),
        updatedAt: DateTime(2026, 8, 2),
      ),
    ]);

    final decoded = jsonDecode(json) as Map;
    expect(decoded, hasLength(1));
    expect(decoded['items'], [
      {'id': 'gs-1', 'content': '内容'},
    ]);
  });

  test('parseGlobalSignDrafts parses fenced and plain json', () {
    final fenced = parseGlobalSignDrafts(
      '```json\n{"items": [{"id": "gs-1", "content": "事项"}, {"id": "", "content": "新事项"}]}\n```',
    );
    expect(fenced, isNotNull);
    expect(fenced!, hasLength(2));
    expect(fenced[0].id, 'gs-1');
    expect(fenced[0].content, '事项');
    expect(fenced[1].id, '');
    expect(fenced[1].content, '新事项');

    final plain = parseGlobalSignDrafts('{"items": []}');
    expect(plain, isNotNull);
    expect(plain!, isEmpty);
  });

  test('parseGlobalSignDrafts rejects malformed payloads', () {
    expect(parseGlobalSignDrafts('not json'), isNull);
    expect(parseGlobalSignDrafts('{"sections": []}'), isNull);
    expect(parseGlobalSignDrafts('{"items": [{"id": "gs-1"}]}'), isNull);
    expect(
      parseGlobalSignDrafts('{"items": [{"id": "gs-1", "content": "  "}]}'),
      isNull,
    );
    expect(parseGlobalSignDrafts('{"items": ["字符串项"]}'), isNull);
  });
}
