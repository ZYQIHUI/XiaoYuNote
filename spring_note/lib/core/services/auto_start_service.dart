import 'package:flutter/services.dart';

import 'platform_feature_support.dart';

class AutoStartService {
  const AutoStartService([
    this._channel = const MethodChannel('spring_note/auto_start'),
  ]);

  final MethodChannel _channel;

  Future<bool> setEnabled(bool enabled) async {
    if (!PlatformFeatureSupport.supportsAutoStart) {
      return false;
    }

    try {
      return await _channel.invokeMethod<bool>('setEnabled', enabled) ?? false;
    } on PlatformException {
      return false;
    }
  }
}
