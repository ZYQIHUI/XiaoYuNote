import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spring_note/core/models/app_config.dart';
import 'package:spring_note/core/models/local_data_state.dart';
import 'package:spring_note/core/models/note_file.dart';
import 'package:spring_note/core/services/note_service.dart';
import 'package:spring_note/core/theme/app_theme.dart';
import 'package:spring_note/features/notes/kb_file_tree_panel.dart';
import 'package:spring_note/features/notes/notes_page.dart';

const _notePath = 'D:\\Temp\\XiaoYuNote\\notes\\daily\\2026-06-18.md';

const _markdown = '''
# 内存测试

```springtree
- 中心主题
  - 分支 A
    - 叶子 A1
    - 叶子 A2
  - 分支 B
  - 分支 C
```

正文段落。
''';

final _localDataState = LocalDataState(
  dataDirectory: 'D:\\Temp\\XiaoYuNote',
  configPath: 'D:\\Temp\\XiaoYuNote\\config.json',
  dailyNotesDirectory: 'D:\\Temp\\XiaoYuNote\\notes\\daily',
  weeklyNotesDirectory: 'D:\\Temp\\XiaoYuNote\\notes\\weekly',
  monthlyNotesDirectory: 'D:\\Temp\\XiaoYuNote\\notes\\monthly',
  config: AppConfig.defaults(),
);

class _MemoryNoteService extends NoteService {
  _MemoryNoteService(this.contents);

  final Map<String, String> contents;

  @override
  Future<List<NoteFile>> listMarkdownFiles({
    required String directoryPath,
    required NoteKind kind,
  }) async {
    return [
      for (final entry in contents.entries)
        if (entry.key.startsWith(directoryPath))
          _noteFile(entry.key, entry.value, kind),
    ];
  }

  @override
  Future<NoteFile> ensureCurrentMarkdownFile({
    required String directoryPath,
    required NoteKind kind,
    DateTime? now,
  }) async {
    contents.putIfAbsent(_notePath, () => _markdown);
    return _noteFile(_notePath, contents[_notePath]!, kind);
  }

  @override
  Future<String> readMarkdown(String path) async => contents[path] ?? '';

  @override
  Future<void> writeMarkdown(String path, String content) async {
    contents[path] = content;
  }

  NoteFile _noteFile(String path, String content, NoteKind kind) {
    final name = path.split('\\').last;
    return NoteFile(
      path: path,
      name: name,
      title: name,
      modifiedAt: DateTime(2026, 6, 18, 12),
      kind: kind,
      preview: '',
      searchText: content,
    );
  }
}

/// 文件树 mock：返回 daily 目录 + 单个 md 文件。
class _MemoryKbFileDataSource implements KbFileDataSource {
  @override
  Future<Map<String, dynamic>> dirs() async => {
    'dirs': [{'path': '', 'label': 'XiaoYuNote', 'root': ''}],
  };
  @override
  Future<Map<String, dynamic>> filesTreeRoot(String root) async => {
    'name': 'XiaoYuNote',
    'type': 'dir',
    'children': [
      {
        'name': 'notes',
        'type': 'dir',
        'children': [
          {
            'name': 'daily',
            'type': 'dir',
            'children': [
              {'name': '2026-06-18.md', 'type': 'file', 'size': 10},
            ],
          },
        ],
      },
    ],
  };
  @override
  Future<String> readText(String path) async => _markdown;
  @override
  Future<void> writeText(String path, String content) async {}
  @override
  Future<Map<String, dynamic>> readXlsx(String path) async => {'content_base64': ''};
  @override
  Future<void> createFile(String path, {String content = ''}) async {}
  @override
  Future<void> createDir(String path) async {}
  @override
  Future<void> delete(String path) async {}

  @override
  Future<void> addSource(String path) async {}
}

void main() {
  testWidgets('notes workspace mode switches release springtree resources', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final noteService = _MemoryNoteService({_notePath: _markdown});
    final kbDataSource = _MemoryKbFileDataSource();

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: NotesPage(
          localDataState: _localDataState,
          noteService: noteService,
          kbFileDataSource: kbDataSource,
        ),
      ),
    );
    await tester.pumpAndSettle();
    // 展开文件树目录（默认收起）后点击文件
    await tester.tap(find.text('notes'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('daily'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('2026-06-18.md'));
    await tester.pumpAndSettle();

    for (var cycle = 0; cycle < 6; cycle++) {
      await tester.tap(
        find.byKey(const ValueKey('notes-workspace-mode-preview')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('notes-workspace-mode-edit')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('notes-workspace-mode-split')),
      );
      await tester.pumpAndSettle();
    }
  });
}
