import 'dart:async';

import 'package:flutter/material.dart';

import '../../features/kb/kb_page.dart';
import '../../features/notes/notes_page.dart';
import '../../features/settings/settings_page.dart';
import '../models/app_config.dart';
import '../models/local_data_state.dart';
import '../services/auto_start_service.dart';
import '../services/global_hotkey_service.dart';
import '../services/local_data_service.dart';
import '../services/note_service.dart';
import '../services/tray_service.dart';
import '../theme/app_theme.dart';
import '../../l10n/l10n.dart';

enum AppSection { notes, kb, settings }

class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.localDataState,
    this.localDataService = const LocalDataService(),
    this.noteService = const NoteService(),
    this.onConfigChanged,
  });

  final LocalDataState localDataState;
  final LocalDataService localDataService;
  final NoteService noteService;
  final ValueChanged<AppConfig>? onConfigChanged;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  AppSection _section = AppSection.notes;
  late LocalDataState _localDataState = widget.localDataState;
  final AutoStartService _autoStartService = const AutoStartService();
  final GlobalHotkeyService _globalHotkeyService = const GlobalHotkeyService();
  final TrayService _trayService = const TrayService();

  /// 知识库引用跳转：请求便签页打开的文件路径（每次跳转生成唯一值触发 didUpdateWidget）。
  String? _openKbFileRequest;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 托盘「打开知识库」→ 切换到知识库面板
    _trayService.setOpenKbHandler(() => _selectSection(AppSection.kb));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncAutoStart(_localDataState.config);
      _syncTray(_localDataState.config);
      _syncGlobalHotkey(_localDataState.config);
    });
  }

  @override
  void didUpdateWidget(covariant AppShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.localDataState != oldWidget.localDataState) {
      _localDataState = widget.localDataState;
      _syncAutoStart(_localDataState.config);
      _syncTray(_localDataState.config);
      _syncGlobalHotkey(_localDataState.config);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_globalHotkeyService.unregisterToggleWindowHotkey());
    unawaited(_trayService.dispose());
    super.dispose();
  }

  void _selectSection(AppSection section) {
    if (_section == section) {
      return;
    }
    setState(() => _section = section);
  }

  /// 知识库引用点击：切到便签页并请求打开文件。
  void _openKbFileInNotes(String path) {
    setState(() {
      // 用时间戳保证每次跳转 openKbFileRequest 都变化（触发 NotesPage.didUpdateWidget）
      _openKbFileRequest = '$path#${DateTime.now().microsecondsSinceEpoch}';
      _section = AppSection.notes;
    });
  }

  void _handleLocalDataStateChanged(LocalDataState state) {
    setState(() {
      _localDataState = state;
    });
    widget.onConfigChanged?.call(state.config);
    _syncAutoStart(state.config);
    _syncTray(state.config);
    _syncGlobalHotkey(state.config);
  }

  void _syncGlobalHotkey(AppConfig config) {
    unawaited(
      _globalHotkeyService.setToggleWindowHotkey(
        config.hotkeys['toggleWindow'],
      ),
    );
  }

  void _syncAutoStart(AppConfig config) {
    unawaited(_autoStartService.setEnabled(config.autoStart));
  }

  void _syncTray(AppConfig config) {
    unawaited(_trayService.sync(config));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppTheme.colors(context);

    return Theme(
      data: theme,
      child: Scaffold(
        backgroundColor: colors.background,
        body: Row(
          children: [
            GlobalSidebar(
              selectedSection: _section,
              onSectionSelected: _selectSection,
            ),
            Expanded(
              child: IndexedStack(
                index: _section.index,
                children: [
                  NotesPage(
                    localDataState: _localDataState,
                    noteService: widget.noteService,
                    localDataService: widget.localDataService,
                    onConfigChanged: (config) {
                      final state = _localDataState.copyWith(config: config);
                      _handleLocalDataStateChanged(state);
                    },
                    openKbFileRequest: _openKbFileRequest,
                  ),
                  KbPage(
                    onOpenFileInNotes: _openKbFileInNotes,
                  ),
                  SettingsPage(
                    localDataState: _localDataState,
                    onConfigChanged: (config) {
                      final state = _localDataState.copyWith(config: config);
                      _handleLocalDataStateChanged(state);
                    },
                    onLocalDataStateChanged: _handleLocalDataStateChanged,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class GlobalSidebar extends StatelessWidget {
  const GlobalSidebar({
    super.key,
    required this.selectedSection,
    required this.onSectionSelected,
  });

  final AppSection selectedSection;
  final ValueChanged<AppSection> onSectionSelected;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.colors(context);
    return Container(
      width: 80,
      color: colors.sidebar,
      padding: const EdgeInsets.symmetric(vertical: 28),
      child: Column(
        children: [
          _SidebarButton(
            icon: _SidebarIconType.stickyNote,
            semanticLabel: l10n(context).coreSidebarNotesLabel,
            selected: selectedSection == AppSection.notes,
            onPressed: () => onSectionSelected(AppSection.notes),
          ),
          const SizedBox(height: 8),
          _SidebarButton(
            icon: _SidebarIconType.database,
            semanticLabel: l10n(context).coreSidebarKbLabel,
            selected: selectedSection == AppSection.kb,
            onPressed: () => onSectionSelected(AppSection.kb),
          ),
          const Spacer(),
          _SidebarButton(
            icon: _SidebarIconType.settings,
            semanticLabel: l10n(context).coreSidebarSettingsLabel,
            selected: selectedSection == AppSection.settings,
            onPressed: () => onSectionSelected(AppSection.settings),
          ),
        ],
      ),
    );
  }
}

class _SidebarButton extends StatefulWidget {
  const _SidebarButton({
    required this.icon,
    required this.semanticLabel,
    required this.selected,
    required this.onPressed,
  });

  final _SidebarIconType icon;
  final String semanticLabel;
  final bool selected;
  final VoidCallback onPressed;

  @override
  State<_SidebarButton> createState() => _SidebarButtonState();
}

class _SidebarButtonState extends State<_SidebarButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.colors(context);
    final backgroundColor = widget.selected
        ? colors.surfacePressed
        : _hovered
        ? colors.surfaceHover
        : Colors.transparent;

    return Tooltip(
      message: widget.semanticLabel,
      waitDuration: const Duration(milliseconds: 500),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Material(
          color: backgroundColor,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: widget.onPressed,
            child: SizedBox(
              width: 48,
              height: 44,
              child: Center(
                child: _SidebarLucideIcon(
                  type: widget.icon,
                  size: 20,
                  color: widget.selected ? colors.onAccent : colors.textMuted,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

enum _SidebarIconType { stickyNote, database, settings }

class _SidebarLucideIcon extends StatelessWidget {
  const _SidebarLucideIcon({
    required this.type,
    required this.size,
    required this.color,
  });

  final _SidebarIconType type;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.square(size),
      painter: _SidebarLucidePainter(type: type, color: color),
    );
  }
}

class _SidebarLucidePainter extends CustomPainter {
  _SidebarLucidePainter({required this.type, required this.color});

  final _SidebarIconType type;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final sx = size.width / 24;
    final sy = size.height / 24;

    switch (type) {
      case _SidebarIconType.stickyNote:
        // lucide sticky-note：矩形 + 右下折角
        final path = Path()
          ..moveTo(4 * sx, 3 * sy)
          ..lineTo(20 * sx, 3 * sy)
          ..lineTo(20 * sx, 15 * sy)
          ..lineTo(14 * sx, 21 * sy)
          ..lineTo(4 * sx, 21 * sy)
          ..close();
        canvas.drawPath(path, paint);
        canvas.drawLine(Offset(14 * sx, 15 * sy), Offset(20 * sx, 15 * sy), paint);
        canvas.drawLine(Offset(14 * sx, 15 * sy), Offset(14 * sx, 21 * sy), paint);
      case _SidebarIconType.database:
        // lucide database：顶部/底部椭圆 + 桶身弧线
        canvas.drawOval(Rect.fromLTWH(3 * sx, 3 * sy, 18 * sx, 6 * sy), paint);
        canvas.drawOval(Rect.fromLTWH(3 * sx, 15 * sy, 18 * sx, 6 * sy), paint);
        canvas.drawArc(Rect.fromLTWH(3 * sx, 9 * sy, 18 * sx, 6 * sy), 0, 3.1415926, false, paint);
      case _SidebarIconType.settings:
        // lucide settings：齿轮（简化：圆 + 8 齿）
        canvas.drawCircle(Offset(12 * sx, 12 * sy), 4 * sy, paint);
        final teeth = 8;
        for (var i = 0; i < teeth; i++) {
          final angle = i * 2 * 3.1415926 / teeth;
          final inner = 6 * sx;
          final outer = 9 * sx;
          final c = Offset(12 * sx, 12 * sy);
          canvas.drawLine(
            Offset(c.dx + inner * _cos(angle), c.dy + inner * _sin(angle)),
            Offset(c.dx + outer * _cos(angle), c.dy + outer * _sin(angle)),
            paint,
          );
        }
    }
  }

  double _cos(double angle) => _approxCos(angle);
  double _sin(double angle) => _approxSin(angle);

  // 轻量三角函数近似（避免 dart:math 依赖）
  double _approxSin(double x) {
    // Taylor 级数 sin(x) ≈ x - x^3/6 + x^5/120
    final x2 = x * x;
    return x * (1 - x2 / 6 + x2 * x2 / 120);
  }

  double _approxCos(double x) {
    // Taylor 级数 cos(x) ≈ 1 - x^2/2 + x^4/24
    final x2 = x * x;
    return 1 - x2 / 2 + x2 * x2 / 24;
  }

  @override
  bool shouldRepaint(covariant _SidebarLucidePainter oldDelegate) {
    return oldDelegate.type != type || oldDelegate.color != color;
  }
}
