import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';

/// 屏幕共享: the Dart side of `screencap/ScreenCapturePlugin.kt`.
///
/// [requestPermission] shows the system's screen-capture consent sheet (the
/// person picks the whole screen or one window there). After that:
///  - [startSharing]/[frames] stream the newest screen frame as PNG/JPEG bytes at
///    a chosen interval (default 3 s), for continuous sharing.
///  - [captureOnce] grabs a single PNG frame.
class ScreenCapture {
  ScreenCapture._();

  static const _channel = MethodChannel('dsh/screencap');
  static const _frames = EventChannel('dsh/screencap/frames');

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

  /// Continuous screen frames (base64 JPEG strings) at [intervalMs].
  /// Call [startSharing] first, then listen here.
  static Stream<Uint8List> frames() {
    return _frames.receiveBroadcastStream().map((event) {
      final b64 = event as String;
      return base64Decode(b64);
    });
  }

  /// Begin continuous capture at [intervalMs] (default 3 s). Asks for
  /// permission first if none is held yet. Returns true when sharing started.
  static Future<bool> startSharing({int intervalMs = 3000, bool ensurePermission = true}) async {
    if (ensurePermission && !await hasPermission()) {
      final granted = await requestPermission();
      if (!granted) return false;
    }
    await _channel.invokeMethod<void>('startSharing', {'intervalMs': intervalMs});
    return true;
  }

  /// Stop continuous capture.
  static Future<void> stopSharing() async {
    try {
      await _channel.invokeMethod<void>('stopSharing');
    } on MissingPluginException {
      // Nothing to stop.
    }
  }

  /// Grab the current screen once as PNG bytes.
  static Future<Uint8List?> captureOnce({bool ensurePermission = true}) async {
    if (ensurePermission && !await hasPermission()) {
      final granted = await requestPermission();
      if (!granted) return null;
    }
    final b64 = await _channel.invokeMethod<String>('captureOnce');
    if (b64 == null || b64.isEmpty) return null;
    return base64Decode(b64);
  }

  /// Drop any projection token held natively.
  static Future<void> release() async {
    try {
      await _channel.invokeMethod<void>('release');
    } on MissingPluginException {
      // Nothing to release.
    }
  }
}
