import 'dart:convert';
import 'dart:io';

import '../models/global_sign_item.dart';

class GlobalSignService {
  const GlobalSignService();

  Future<List<GlobalSignItem>> readItems({required String appDataDir}) async {
    final file = File(globalSignPath(appDataDir));
    if (!await file.exists()) {
      return const [];
    }

    final content = await file.readAsString();
    if (content.trim().isEmpty) {
      return const [];
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(content);
    } catch (_) {
      return const [];
    }
    if (decoded is! Map) {
      return const [];
    }
    return _readItemList(decoded['items']);
  }

  Future<void> writeItems({
    required String appDataDir,
    required List<GlobalSignItem> items,
  }) async {
    final file = File(globalSignPath(appDataDir));
    await file.parent.create(recursive: true);
    const encoder = JsonEncoder.withIndent('  ');
    await file.writeAsString(
      '${encoder.convert({
        'schemaVersion': 1,
        'updatedAt': DateTime.now().toIso8601String(),
        'items': [for (final item in items) item.toJson()],
      })}\n',
    );
  }

  /// 彻底删除（不经过 AI、不写入日报）：按 id 移除后直接落盘。
  Future<void> removeItem({
    required String appDataDir,
    required String id,
  }) async {
    final items = await readItems(appDataDir: appDataDir);
    await writeItems(
      appDataDir: appDataDir,
      items: [for (final item in items) if (item.id != id) item],
    );
  }

  String globalSignPath(String appDataDir) {
    final separator = Platform.pathSeparator;
    final root = appDataDir.endsWith(separator)
        ? appDataDir.substring(0, appDataDir.length - 1)
        : appDataDir;
    return [root, 'globalsign.json'].join(separator);
  }

  /// 把当前列表渲染为嵌入提示词的 JSON（只含 id 与 content）。
  String itemsToPromptJson(List<GlobalSignItem> items) {
    const encoder = JsonEncoder.withIndent('  ');
    return encoder.convert({
      'items': [
        for (final item in items) {'id': item.id, 'content': item.content},
      ],
    });
  }

  /// 以 AI 返回的全量草稿为准生成新列表：命中已有 id 的保留 createdAt，
  /// 内容变化时刷新 updatedAt；无 id 或未命中的分配新 id。
  List<GlobalSignItem> reconcileItems({
    required List<GlobalSignItem> existing,
    required List<GlobalSignDraftItem> drafts,
    required DateTime now,
  }) {
    final existingById = {for (final item in existing) item.id: item};
    final result = <GlobalSignItem>[];
    var newIndex = 0;
    for (final draft in drafts) {
      final content = draft.content.trim();
      if (content.isEmpty) {
        continue;
      }
      final matched = draft.id.isEmpty ? null : existingById.remove(draft.id);
      if (matched != null) {
        result.add(
          matched.content == content
              ? matched
              : matched.copyWith(content: content, updatedAt: now),
        );
      } else {
        newIndex += 1;
        result.add(
          GlobalSignItem(
            id: 'gs-${now.millisecondsSinceEpoch.toRadixString(36)}-$newIndex',
            content: content,
            createdAt: now,
            updatedAt: now,
          ),
        );
      }
    }
    return result;
  }

  List<GlobalSignItem> _readItemList(Object? value) {
    if (value is! List) {
      return const [];
    }
    final items = <GlobalSignItem>[];
    for (final entry in value.whereType<Map>()) {
      final item = GlobalSignItem.fromJson(
        entry.map((key, value) => MapEntry(key.toString(), value)),
      );
      if (item.id.isNotEmpty && item.content.trim().isNotEmpty) {
        items.add(item);
      }
    }
    return items;
  }
}
