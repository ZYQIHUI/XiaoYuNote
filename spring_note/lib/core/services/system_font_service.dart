import 'dart:async';
import 'dart:io';

class SystemFontService {
  const SystemFontService();

  Future<List<String>> loadFonts() async {
    if (!Platform.isWindows) {
      return _fallbackFonts();
    }

    final powershellFonts = await _loadWindowsFontsFromPowerShell();
    if (powershellFonts.isNotEmpty) {
      return _normalizeFonts(powershellFonts);
    }

    final registryFonts = await _loadWindowsFontsFromRegistry();
    if (registryFonts.isNotEmpty) {
      return _normalizeFonts(registryFonts);
    }

    return _fallbackFonts();
  }

  Future<List<String>> _loadWindowsFontsFromPowerShell() async {
    const command = '''
Add-Type -AssemblyName System.Drawing
\$collection = New-Object System.Drawing.Text.InstalledFontCollection
\$collection.Families | ForEach-Object { \$_.Name }
''';

    try {
      final result = await Process.run('powershell', [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        command,
      ]).timeout(const Duration(seconds: 5));
      if (result.exitCode != 0) {
        return const [];
      }
      return _splitLines(result.stdout.toString());
    } on Object {
      return const [];
    }
  }

  Future<List<String>> _loadWindowsFontsFromRegistry() async {
    final fonts = <String>[];
    const keys = [
      r'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts',
      r'HKCU\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts',
    ];

    for (final key in keys) {
      try {
        final result = await Process.run('reg', [
          'query',
          key,
        ]).timeout(const Duration(seconds: 3));
        if (result.exitCode != 0) {
          continue;
        }
        fonts.addAll(_parseRegistryFonts(result.stdout.toString()));
      } on Object {
        continue;
      }
    }

    return fonts;
  }

  List<String> _parseRegistryFonts(String output) {
    final fonts = <String>[];
    final linePattern = RegExp(r'^\s*(.+?)\s+REG_\w+\s+.+$');
    for (final line in _splitLines(output)) {
      final match = linePattern.firstMatch(line);
      if (match == null) {
        continue;
      }
      var name = match.group(1) ?? '';
      name = name.replaceAll(
        RegExp(
          r'\s*\((?:TrueType|OpenType|Type 1)\)\s*$',
          caseSensitive: false,
        ),
        '',
      );
      name = name.replaceAll(
        RegExp(
          r'\s+(?:Regular|Bold|Italic|Bold Italic|Oblique|Light|Medium|SemiBold|Semibold|Black|Thin|Condensed|Narrow)$',
          caseSensitive: false,
        ),
        '',
      );
      fonts.add(name);
    }
    return fonts;
  }

  List<String> _normalizeFonts(Iterable<String> fonts) {
    final blocked = RegExp(
      r'^(?:@|Marlett$|Symbol$|Webdings$|Wingdings|Segoe Fluent Icons$|Segoe MDL2 Assets$)',
      caseSensitive: false,
    );
    final result = <String>{};
    for (final font in fonts) {
      final value = font.trim();
      if (value.isEmpty || blocked.hasMatch(value)) {
        continue;
      }
      result.add(value);
    }
    final sorted = result.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return sorted;
  }

  List<String> _splitLines(String value) {
    return value
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
  }

  List<String> _fallbackFonts() {
    if (Platform.isMacOS) {
      return const ['Helvetica Neue', 'PingFang SC', 'Arial'];
    }
    if (Platform.isLinux) {
      return const ['Noto Sans CJK SC', 'Noto Sans', 'DejaVu Sans'];
    }
    return const [
      'Segoe UI',
      'Segoe UI Variable',
      'Microsoft YaHei UI',
      'Microsoft YaHei',
      'Arial',
    ];
  }
}
