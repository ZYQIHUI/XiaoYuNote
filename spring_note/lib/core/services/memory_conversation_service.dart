import 'dart:convert';
import 'dart:io';

import '../models/memory_message.dart';

class MemoryConversationService {
  const MemoryConversationService();

  Future<List<MemoryMessage>> readMessages({required String appDataDir}) async {
    final file = _rememberFile(appDataDir);
    if (!await file.exists()) {
      return [];
    }
    final content = await file.readAsString();
    if (content.trim().isEmpty) {
      return [];
    }
    final decoded = jsonDecode(content);
    if (decoded is! List) {
      return [];
    }
    return decoded
        .whereType<Map>()
        .map(
          (item) => item.map((key, value) => MapEntry(key.toString(), value)),
        )
        .map(MemoryMessage.fromJson)
        .toList();
  }

  Future<void> saveMessages({
    required String appDataDir,
    required List<MemoryMessage> messages,
  }) async {
    final file = _rememberFile(appDataDir);
    await file.parent.create(recursive: true);
    const encoder = JsonEncoder.withIndent('  ');
    await file.writeAsString(
      '${encoder.convert(messages.map((message) => message.toJson()).toList())}\n',
    );
  }

  Future<void> clear({required String appDataDir}) async {
    final file = _rememberFile(appDataDir);
    await file.parent.create(recursive: true);
    await file.writeAsString('[]\n');
  }

  File _rememberFile(String appDataDir) {
    return File(_join(appDataDir, 'remember.json'));
  }

  String _join(String left, String right) {
    if (left.endsWith(Platform.pathSeparator)) {
      return '$left$right';
    }
    return '$left${Platform.pathSeparator}$right';
  }
}
