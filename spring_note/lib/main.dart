import 'dart:async';

import 'package:flutter/material.dart';

import 'app.dart';
import 'core/services/desktop_window_controller.dart';
import 'core/services/indexed_note_service.dart';
import 'core/services/sidecar_lifecycle.dart';
import 'src/rust/frb_generated.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await DesktopWindowController.initializeAndShow();
  await RustLib.init();
  // 后台启动 sidecar（health 复用/失败降级，不阻塞 UI）
  unawaited(SidecarLifecycle.instance.start());
  runApp(const XiaoYuNoteApp(noteService: IndexedNoteService()));
}
