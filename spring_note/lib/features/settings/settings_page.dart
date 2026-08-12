import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/models/app_config.dart';
import '../../core/models/local_data_state.dart';
import '../../core/models/model_config.dart';
import '../../core/models/model_reference.dart';
import '../../core/models/provider_config.dart';
import '../../core/models/structured_note_section_config.dart';
import '../../core/services/ai_client_service.dart';
import '../../core/services/external_link_service.dart';
import '../../core/services/local_data_service.dart';
import '../../core/services/note_image_cleanup_service.dart';
import '../../core/services/platform_feature_support.dart';
import '../../core/services/sidecar_client.dart';
import '../../core/services/system_font_service.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/markdown_editor_highlight.dart';
import '../../l10n/l10n.dart';
import '../../src/rust/ai.dart' as rust_ai;

part 'settings_preferences_panel.dart';
part 'settings_providers_panel.dart';
part 'settings_default_models_panel.dart';
part 'settings_storage_panel.dart';
part 'settings_about_panel.dart';
part 'settings_shared_widgets.dart';

enum _SettingsSection {
  preferences(_SettingsNavIconType.monitor),
  providers(_SettingsNavIconType.boxes),
  models(_SettingsNavIconType.heart),
  storage(_SettingsNavIconType.storage),
  about(_SettingsNavIconType.info);

  const _SettingsSection(this.icon);

  final _SettingsNavIconType icon;
}

enum _SettingsNavIconType {
  monitor,
  boxes,
  heart,
  storage,
  info,
  image,
  layers,
  trash,
}

class SettingsPage extends StatefulWidget {
  SettingsPage({
    super.key,
    required this.localDataState,
    this.localDataService = const LocalDataService(),
    this.aiClientService = const AiClientService(),
    this.noteImageCleanupService = const NoteImageCleanupService(),
    this.onConfigChanged,
    this.onLocalDataStateChanged,
  });

  final LocalDataState localDataState;
  final LocalDataService localDataService;
  final AiClientService aiClientService;
  final NoteImageCleanupService noteImageCleanupService;
  final ValueChanged<AppConfig>? onConfigChanged;
  final ValueChanged<LocalDataState>? onLocalDataStateChanged;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  _SettingsSection _section = _SettingsSection.preferences;
  late AppConfig _config = widget.localDataState.config;
  String? _selectedProviderId;
  bool _saving = false;
  String? _settingsError;
  NoteImageCleanupScan? _storageScan;
  String? _storageScanDataDirectory;

  @override
  void didUpdateWidget(covariant SettingsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.localDataState.dataDirectory !=
        oldWidget.localDataState.dataDirectory) {
      _storageScan = null;
      _storageScanDataDirectory = null;
    }
  }

  void _rememberStorageScan(NoteImageCleanupScan scan) {
    _storageScan = scan;
    _storageScanDataDirectory = widget.localDataState.dataDirectory;
  }

  ProviderConfig? get _selectedProvider {
    if (_config.providers.isEmpty) {
      return null;
    }
    return _config.providers.firstWhere(
      (provider) => provider.id == _selectedProviderId,
      orElse: () => _config.providers.first,
    );
  }

  List<_ProviderModelOption> get _allModels {
    return [
      for (final provider in _config.providers)
        for (final model in provider.models)
          _ProviderModelOption(provider: provider, model: model),
    ];
  }

  Future<void> _updateConfig(AppConfig config) async {
    setState(() {
      _config = config;
      _saving = true;
      if (_selectedProviderId == null && config.providers.isNotEmpty) {
        _selectedProviderId = config.providers.first.id;
      }
    });
    try {
      await widget.localDataService.saveConfig(config);
      widget.onConfigChanged?.call(config);
      if (mounted) {
        setState(() {
          _saving = false;
          _settingsError = null;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _settingsError = _migrationErrorText(error);
        });
      }
    }
  }

  String _migrationErrorText(Object error) {
    final strings = l10n(context);
    if (error is DataDirectoryMigrationException) {
      return switch (error.error) {
        DataDirectoryMigrationError.nestedInsideCurrent =>
          strings.settingsMigrationErrorNested,
        DataDirectoryMigrationError.isAFile =>
          strings.settingsMigrationErrorIsFile,
        DataDirectoryMigrationError.macOSSecurityScopedAccessFailed =>
          strings.settingsMigrationErrorMacAccess,
      };
    }
    return error.toString();
  }

  Future<void> _migrateDataDirectory(String? targetDirectory) async {
    if (_saving) {
      return;
    }
    setState(() {
      _saving = true;
      _settingsError = null;
    });
    try {
      final state = await widget.localDataService.migrateDataDirectory(
        currentState: widget.localDataState.copyWith(config: _config),
        targetDirectory: targetDirectory,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _config = state.config;
        _saving = false;
      });
      widget.onLocalDataStateChanged?.call(state);
      if (mounted) {
        await _showDataMigrationCompleteDialog();
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _settingsError = _migrationErrorText(error);
        });
      }
    }
  }

  Future<void> _showDataMigrationCompleteDialog() {
    return showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: l10n(context).actionClose,
      barrierColor: Colors.black.withValues(alpha: 0.18),
      transitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (context, _, _) => const _DataMigrationCompleteDialog(),
      transitionBuilder: (context, animation, _, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return FadeTransition(
          opacity: curved,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.975, end: 1).animate(curved),
            child: child,
          ),
        );
      },
    );
  }

  Future<void> _updateProvider(ProviderConfig provider) async {
    final providers = [
      for (final item in _config.providers)
        if (item.id == provider.id) provider else item,
    ];
    await _updateConfig(_config.copyWith(providers: providers));
  }

  Future<void> _deleteProvider(String id) async {
    final removedModelIds = _config.providers
        .where((provider) => provider.id == id)
        .expand((provider) => provider.models)
        .map((model) => model.modelId)
        .toSet();
    final removedModelRefs = _config.providers
        .where((provider) => provider.id == id)
        .expand((provider) => provider.models)
        .map(
          (model) =>
              ModelReference.encode(providerId: id, modelId: model.modelId),
        )
        .toSet();
    final providers = _config.providers
        .where((provider) => provider.id != id)
        .toList();
    final defaultModels = Map<String, String?>.from(_config.defaultModels);
    for (final entry in defaultModels.entries.toList()) {
      final modelRef = ModelReference.parse(entry.value);
      if (modelRef?.providerId == id ||
          (modelRef?.providerId == null &&
              removedModelIds.contains(modelRef?.modelId)) ||
          removedModelRefs.contains(entry.value)) {
        defaultModels[entry.key] = null;
      }
    }
    await _updateConfig(
      _config.copyWith(providers: providers, defaultModels: defaultModels),
    );
    setState(
      () => _selectedProviderId = providers.isEmpty ? null : providers.first.id,
    );
  }

  Future<void> _addProvider(ProviderConfig provider) async {
    final providers = [..._config.providers, provider];
    await _updateConfig(_config.copyWith(providers: providers));
    setState(() => _selectedProviderId = provider.id);
  }

  Future<void> _upsertModel(ProviderConfig provider, ModelConfig model) async {
    final currentProvider = _config.providers.firstWhere(
      (item) => item.id == provider.id,
      orElse: () => provider,
    );
    final exists = currentProvider.models.any(
      (item) => item.modelId == model.modelId,
    );
    final models = exists
        ? [
            for (final item in currentProvider.models)
              if (item.modelId == model.modelId) model else item,
          ]
        : [...currentProvider.models, model];
    await _updateProvider(currentProvider.copyWith(models: models));
  }

  Future<void> _deleteModel(ProviderConfig provider, String modelId) async {
    final currentProvider = _config.providers.firstWhere(
      (item) => item.id == provider.id,
      orElse: () => provider,
    );
    final models = currentProvider.models
        .where((model) => model.modelId != modelId)
        .toList();
    final defaultModels = Map<String, String?>.from(_config.defaultModels);
    for (final entry in defaultModels.entries.toList()) {
      final modelRef = ModelReference.parse(entry.value);
      if (modelRef?.matches(providerId: currentProvider.id, modelId: modelId) ??
          false) {
        defaultModels[entry.key] = null;
      }
    }
    final providers = [
      for (final item in _config.providers)
        if (item.id == currentProvider.id)
          currentProvider.copyWith(models: models)
        else
          item,
    ];
    await _updateConfig(
      _config.copyWith(providers: providers, defaultModels: defaultModels),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.colors(context);
    return Material(
      color: colors.background,
      child: Row(
        children: [
          Container(
            width: 220,
            padding: const EdgeInsets.fromLTRB(18, 28, 18, 18),
            decoration: BoxDecoration(
              color: colors.sidebar,
              border: Border(right: BorderSide(color: colors.divider)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      l10n(context).settingsTitle,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const Spacer(),
                    if (_saving)
                      const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                  ],
                ),
                const SizedBox(height: 18),
                for (final section in _SettingsSection.values)
                  _SettingsNavItem(
                    section: section,
                    selected: section == _section,
                    onTap: () {
                      if (_section == section) {
                        return;
                      }
                      setState(() => _section = section);
                    },
                  ),
              ],
            ),
          ),
          Expanded(child: _buildSection()),
        ],
      ),
    );
  }

  Widget _buildSection() {
    return switch (_section) {
      _SettingsSection.preferences => _PreferencesPanel(
        config: _config,
        onChanged: _updateConfig,
        dataDirectory: widget.localDataState.dataDirectory,
        configPath: widget.localDataState.configPath,
        appDataDir: widget.localDataState.dataDirectory,
        aiClientService: widget.aiClientService,
        saving: _saving,
        errorMessage: _settingsError,
        onDataDirectoryChanged: _migrateDataDirectory,
      ),
      _SettingsSection.providers => _ProvidersPanel(
        appDataDir: widget.localDataState.dataDirectory,
        apiLogEnabled: _config.apiLogEnabled,
        aiClientService: widget.aiClientService,
        providers: _config.providers,
        selectedProvider: _selectedProvider,
        selectedProviderId: _selectedProviderId,
        onSelectedProviderChanged: (id) =>
            setState(() => _selectedProviderId = id),
        onProviderChanged: _updateProvider,
        onProviderDeleted: _deleteProvider,
        onProviderAdded: _addProvider,
        onModelChanged: _upsertModel,
        onModelDeleted: _deleteModel,
      ),
      _SettingsSection.models => _DefaultModelsPanel(
        config: _config,
        models: _allModels,
        onChanged: _updateConfig,
      ),
      _SettingsSection.storage => _StoragePanel(
        localDataState: widget.localDataState.copyWith(config: _config),
        cleanupService: widget.noteImageCleanupService,
        initialScan:
            _storageScanDataDirectory == widget.localDataState.dataDirectory
            ? _storageScan
            : null,
        onScanChanged: _rememberStorageScan,
      ),
      _SettingsSection.about => _AboutPanel(),
    };
  }
}

class _SettingsNavItem extends StatefulWidget {
  const _SettingsNavItem({
    required this.section,
    required this.selected,
    required this.onTap,
  });

  final _SettingsSection section;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_SettingsNavItem> createState() => _SettingsNavItemState();
}

class _SettingsNavItemState extends State<_SettingsNavItem> {
  bool _hovered = false;

  String _sectionLabel() {
    final strings = l10n(context);
    return switch (widget.section) {
      _SettingsSection.preferences => strings.settingsSectionPreferences,
      _SettingsSection.providers => strings.settingsSectionProviders,
      _SettingsSection.models => strings.settingsSectionModels,
      _SettingsSection.storage => strings.settingsSectionStorage,
      _SettingsSection.about => strings.settingsSectionAbout,
    };
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.colors(context);
    final active = widget.selected || _hovered;
    final contentColor = active ? colors.text : colors.textSubtle;
    final backgroundColor = widget.selected
        ? colors.surfacePressed
        : colors.surfaceHover;

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: SizedBox(
            height: 36,
            child: Stack(
              children: [
                Positioned.fill(
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 240),
                    curve: Curves.easeOutCubic,
                    opacity: active ? 1 : 0,
                    child: TweenAnimationBuilder<Color?>(
                      tween: ColorTween(end: backgroundColor),
                      duration: const Duration(milliseconds: 280),
                      curve: Curves.easeOutCubic,
                      builder: (context, color, _) {
                        return DecoratedBox(
                          decoration: BoxDecoration(
                            color: color ?? backgroundColor,
                            borderRadius: BorderRadius.circular(12),
                          ),
                        );
                      },
                    ),
                  ),
                ),
                TweenAnimationBuilder<Color?>(
                  tween: ColorTween(end: contentColor),
                  duration: const Duration(milliseconds: 280),
                  curve: Curves.easeOutCubic,
                  builder: (context, color, _) {
                    final animatedColor = color ?? contentColor;
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Row(
                        children: [
                          _SettingsNavLucideIcon(
                            type: widget.section.icon,
                            size: 17,
                            color: animatedColor,
                          ),
                          const SizedBox(width: 10),
                          Text(
                            _sectionLabel(),
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(
                                  color: animatedColor,
                                  fontWeight: FontWeight.w500,
                                ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SettingsNavLucideIcon extends StatelessWidget {
  const _SettingsNavLucideIcon({
    super.key,
    required this.type,
    required this.size,
    required this.color,
  });

  final _SettingsNavIconType type;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: CustomPaint(
        size: Size.square(size),
        painter: _SettingsNavLucidePainter(type: type, color: color),
      ),
    );
  }
}

class _SettingsNavLucidePainter extends CustomPainter {
  const _SettingsNavLucidePainter({required this.type, required this.color});

  final _SettingsNavIconType type;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / 24;
    final sy = size.height / 24;
    final strokeScale = sx < sy ? sx : sy;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.05 * strokeScale
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    Offset point(double x, double y) => Offset(x * sx, y * sy);
    Rect rect(double left, double top, double width, double height) =>
        Rect.fromLTWH(left * sx, top * sy, width * sx, height * sy);
    RRect roundedRect(double left, double top, double width, double height) {
      return RRect.fromRectAndRadius(
        rect(left, top, width, height),
        Radius.circular(2 * strokeScale),
      );
    }

    Path path(List<Offset> points, {bool close = false}) {
      final result = Path()..moveTo(points.first.dx, points.first.dy);
      for (final point in points.skip(1)) {
        result.lineTo(point.dx, point.dy);
      }
      if (close) {
        result.close();
      }
      return result;
    }

    void drawCube(double cx, double cy, double r) {
      final top = point(cx, cy - r);
      final rightTop = point(cx + r * 1.18, cy - r * 0.34);
      final rightBottom = point(cx + r * 1.18, cy + r * 0.9);
      final bottom = point(cx, cy + r * 1.55);
      final leftBottom = point(cx - r * 1.18, cy + r * 0.9);
      final leftTop = point(cx - r * 1.18, cy - r * 0.34);
      final center = point(cx, cy + r * 0.28);

      canvas.drawPath(
        path([
          top,
          rightTop,
          rightBottom,
          bottom,
          leftBottom,
          leftTop,
        ], close: true),
        paint,
      );
      canvas.drawLine(top, center, paint);
      canvas.drawLine(leftTop, center, paint);
      canvas.drawLine(rightTop, center, paint);
      canvas.drawLine(center, bottom, paint);
    }

    switch (type) {
      case _SettingsNavIconType.monitor:
        canvas.drawRRect(roundedRect(3.5, 4.5, 17, 12), paint);
        canvas.drawLine(point(12, 16.5), point(12, 20), paint);
        canvas.drawLine(point(8.5, 20), point(15.5, 20), paint);
        break;
      case _SettingsNavIconType.boxes:
        drawCube(12, 5.8, 2.55);
        drawCube(7.5, 13.4, 2.55);
        drawCube(16.5, 13.4, 2.55);
        break;
      case _SettingsNavIconType.heart:
        final heart = Path()
          ..moveTo(point(12, 20.2).dx, point(12, 20.2).dy)
          ..cubicTo(
            point(5.1, 15.2).dx,
            point(5.1, 15.2).dy,
            point(3.7, 11.5).dx,
            point(3.7, 11.5).dy,
            point(3.7, 8.6).dx,
            point(3.7, 8.6).dy,
          )
          ..cubicTo(
            point(3.7, 5.6).dx,
            point(3.7, 5.6).dy,
            point(6, 3.9).dx,
            point(6, 3.9).dy,
            point(8.5, 3.9).dx,
            point(8.5, 3.9).dy,
          )
          ..cubicTo(
            point(10.1, 3.9).dx,
            point(10.1, 3.9).dy,
            point(11.3, 4.8).dx,
            point(11.3, 4.8).dy,
            point(12, 6).dx,
            point(12, 6).dy,
          )
          ..cubicTo(
            point(12.7, 4.8).dx,
            point(12.7, 4.8).dy,
            point(13.9, 3.9).dx,
            point(13.9, 3.9).dy,
            point(15.5, 3.9).dx,
            point(15.5, 3.9).dy,
          )
          ..cubicTo(
            point(18, 3.9).dx,
            point(18, 3.9).dy,
            point(20.3, 5.6).dx,
            point(20.3, 5.6).dy,
            point(20.3, 8.6).dx,
            point(20.3, 8.6).dy,
          )
          ..cubicTo(
            point(20.3, 11.5).dx,
            point(20.3, 11.5).dy,
            point(18.9, 15.2).dx,
            point(18.9, 15.2).dy,
            point(12, 20.2).dx,
            point(12, 20.2).dy,
          );
        canvas.drawPath(heart, paint);
        break;
      case _SettingsNavIconType.storage:
        canvas.drawRRect(roundedRect(3.5, 5, 17, 14), paint);
        canvas.drawLine(point(3.5, 14), point(20.5, 14), paint);
        canvas.drawCircle(point(16.8, 17), 0.55 * strokeScale, paint);
        canvas.drawCircle(point(13.8, 17), 0.55 * strokeScale, paint);
        break;
      case _SettingsNavIconType.info:
        final badge = Path()..addOval(rect(4.8, 4.8, 14.4, 14.4));
        canvas.drawPath(badge, paint);
        canvas.drawCircle(point(12, 7.8), 0.42 * strokeScale, paint);
        canvas.drawLine(point(12, 11), point(12, 16.5), paint);
        canvas.drawLine(point(10.9, 11), point(12, 11), paint);
        break;
      case _SettingsNavIconType.image:
        canvas.drawRRect(roundedRect(3, 3, 18, 18), paint);
        canvas.drawCircle(point(9, 9), 2 * strokeScale, paint);
        canvas.drawPath(
          path([
            point(6, 20.5),
            point(15.1, 11.9),
            point(17.9, 11.9),
            point(21, 15),
          ]),
          paint,
        );
        break;
      case _SettingsNavIconType.layers:
        canvas.drawPath(
          path([
            point(12, 3.2),
            point(20.5, 7.5),
            point(12, 11.8),
            point(3.5, 7.5),
          ], close: true),
          paint,
        );
        canvas.drawPath(
          path([point(3.5, 12.4), point(12, 16.7), point(20.5, 12.4)]),
          paint,
        );
        canvas.drawPath(
          path([point(3.5, 17), point(12, 21.2), point(20.5, 17)]),
          paint,
        );
        break;
      case _SettingsNavIconType.trash:
        canvas.drawLine(point(3.8, 6.5), point(20.2, 6.5), paint);
        canvas.drawPath(
          path([point(6, 6.5), point(7, 20), point(17, 20), point(18, 6.5)]),
          paint,
        );
        canvas.drawPath(
          path([
            point(9, 6.5),
            point(9.6, 3.8),
            point(14.4, 3.8),
            point(15, 6.5),
          ]),
          paint,
        );
        canvas.drawLine(point(10, 10.5), point(10.5, 16.5), paint);
        canvas.drawLine(point(14, 10.5), point(13.5, 16.5), paint);
        break;
    }
  }

  @override
  bool shouldRepaint(covariant _SettingsNavLucidePainter oldDelegate) {
    return oldDelegate.type != type || oldDelegate.color != color;
  }
}
