import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';

/// 屏幕共享 / 截屏: the Dart side of `screencap/ScreenCapturePlugin.kt`.
///
/// [requestPermission] shows the system's screen-capture consent sheet;
/// [captureOnce] returns the current screen as PNG bytes. Android only. On any
/// other OS, or when the native channel is absent, both throw a
/// [MissingPluginException] that callers should surface as "此设备不支持".
class ScreenCapture {
  ScreenCapture._();

  static const _channel = MethodChannel('dsh/screencap');

  /// Whether a projection token is already granted (no dialog needed).
  static Future<bool> hasPermission() async {
    try {
      return await _channel.invokeMethod<bool>('hasPermission') ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Show the system consent dialog. Returns true when the user granted it.
  static Future<bool> requestPermission() async {
    return await _channel.invokeMethod<bool>('requestPermission') ?? false;
  }

  /// Grab the current screen as PNG bytes. If [ensurePermission] is true and no
  /// token is held yet, asks first. Returns null if permission is denied.
  static Future<Uint8List?> captureOnce({bool ensurePermission = true}) async {
    if (ensurePermission && !await hasPermission()) {
      final granted = await requestPermission();
      if (!granted) return null;
    }
    final b64 = await _channel.invokeMethod<String>('captureOnce');
    if (b64 == null || b64.isEmpty) return null;
    return base64Decode(b64);
  }

  /// Drop the projection token held natively.
  static Future<void> release() async {
    try {
      await _channel.invokeMethod<void>('release');
    } on MissingPluginException {
      // Nothing to release.
    }
  }
}
