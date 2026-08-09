import 'package:flutter/services.dart';

class ClipboardImageService {
  const ClipboardImageService([
    this._channel = const MethodChannel('spring_note/clipboard_image'),
  ]);

  final MethodChannel _channel;

  Future<List<String>> readImageFiles() async {
    try {
      final files = await _channel.invokeMethod<List<Object?>>(
        'readImageFiles',
      );
      if (files == null || files.isEmpty) {
        return const [];
      }
      return files
          .whereType<String>()
          .where((path) => path.trim().isNotEmpty)
          .toList();
    } on MissingPluginException {
      return const [];
    } on PlatformException {
      return const [];
    }
  }

  Future<Uint8List?> readPngImage() async {
    try {
      final bytes = await _channel.invokeMethod<Uint8List>('readPngImage');
      if (bytes == null || bytes.isEmpty) {
        return null;
      }
      return bytes;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}
