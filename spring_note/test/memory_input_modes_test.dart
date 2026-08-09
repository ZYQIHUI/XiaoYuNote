import 'package:flutter_test/flutter_test.dart';
import 'package:spring_note/features/memory/memory_input_modes.dart';

void main() {
  group('resolveMemoryInputModes', () {
    test('passes plain text through untouched', () {
      final resolved = resolveMemoryInputModes('整理一下上周的周报');

      expect(resolved.userText, '整理一下上周的周报');
      expect(resolved.modes, isEmpty);
      expect(resolved.promptSuffix, isEmpty);
    });

    test('strips the mind map tag and activates its prompt', () {
      final resolved = resolveMemoryInputModes(
        '${mindMapInputMode.token}整理上周周报',
      );

      expect(resolved.userText, '整理上周周报');
      expect(resolved.modes, [mindMapInputMode]);
      expect(resolved.promptSuffix, contains('SpringTree 输出模式'));
    });

    test('folds duplicate tags into one mode', () {
      final resolved = resolveMemoryInputModes(
        '${mindMapInputMode.token}a${mindMapInputMode.token}b',
      );

      expect(resolved.userText, 'ab');
      expect(resolved.modes, hasLength(1));
    });

    test('tag-only input resolves to empty user text', () {
      final resolved = resolveMemoryInputModes(mindMapInputMode.token);

      expect(resolved.userText, isEmpty);
      expect(resolved.modes, hasLength(1));
    });
  });
}
