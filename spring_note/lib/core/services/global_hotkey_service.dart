import 'package:flutter/services.dart';

import 'platform_feature_support.dart';

class GlobalHotkeyService {
  const GlobalHotkeyService([
    this._channel = const MethodChannel('spring_note/global_hotkeys'),
  ]);

  final MethodChannel _channel;

  Future<bool> setToggleWindowHotkey(String? hotkey) async {
    if (!PlatformFeatureSupport.supportsGlobalHotkeys) {
      return false;
    }

    final normalized = hotkey?.trim() ?? '';
    if (normalized.isEmpty) {
      await unregisterToggleWindowHotkey();
      return true;
    }

    try {
      return await _channel.invokeMethod<bool>(
            'setToggleWindowHotkey',
            normalized,
          ) ??
          false;
    } on PlatformException {
      return false;
    }
  }

  Future<void> unregisterToggleWindowHotkey() async {
    if (!PlatformFeatureSupport.supportsGlobalHotkeys) {
      return;
    }

    try {
      await _channel.invokeMethod<void>('unregisterToggleWindowHotkey');
    } on PlatformException {
      // Global hotkeys are an optional native integration.
    }
  }
}
