import 'dart:async';

import 'package:flutter/services.dart';

/// Where a call's picture comes from.
enum VisionSource { screen, camera }

/// One frame from `screencap/ScreenCapturePlugin.kt` or `CameraCapturePlugin.kt`.
///
/// [jpeg] is null for a heartbeat of a still screen (nothing new to send; the
/// last frame still stands). [keep] is false for the camera's small preview
/// frames, which only feed the call page's little window.
class VisionFrame {
  const VisionFrame({
    required this.at,
    required this.source,
    this.jpeg,
    this.change = 0,
    this.keep = true,
    this.width = 0,
    this.height = 0,
  });

  final DateTime at;
  final VisionSource source;
  final Uint8List? jpeg;

  /// How much it differs from the last kept frame, 0..1 (1 for the first).
  final double change;
  final bool keep;
  final int width;
  final int height;

  bool get still => jpeg == null;

  static VisionFrame? fromEvent(Object? event) {
    if (event is! Map) return null;
    final ts = event['ts'];
    final at = DateTime.fromMillisecondsSinceEpoch(ts is int ? ts : DateTime.now().millisecondsSinceEpoch);
    final source = event['source'] == 'camera' ? VisionSource.camera : VisionSource.screen;
    final jpeg = event['jpeg'];
    final change = event['change'];
    return VisionFrame(
      at: at,
      source: source,
      jpeg: jpeg is Uint8List ? jpeg : null,
      change: change is num ? change.toDouble() : 0,
      keep: event['keep'] != false,
      width: event['width'] is int ? event['width'] as int : 0,
      height: event['height'] is int ? event['height'] as int : 0,
    );
  }
}

/// 屏幕共享: the Dart side of `screencap/ScreenCapturePlugin.kt`.
///
/// [startSharing] shows the system's consent sheet (the person picks the whole
/// screen or one window there) and then streams [frames]: a frame when the
/// screen visibly changed, a heartbeat otherwise. The native side starts the
/// mediaProjection foreground service, so capture goes on in the background.
class ScreenCapture {
  ScreenCapture._();

  static const _channel = MethodChannel('dsh/screencap');
  static const _frames = EventChannel('dsh/screencap/frames');

  static Stream<VisionFrame>? _stream;

  /// Frames while sharing. Errors with `projection_stopped` when the system ends it.
  static Stream<VisionFrame> frames() =>
      _stream ??= _frames.receiveBroadcastStream().map(VisionFrame.fromEvent).where((f) => f != null).cast<VisionFrame>();

  static Future<bool> isSharing() async {
    try {
      return await _channel.invokeMethod<bool>('isSharing') ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Asks for consent and starts. False when the person declined.
  static Future<bool> startSharing({int intervalMs = 1000, int maxDim = 1024}) async {
    return await _channel.invokeMethod<bool>('startSharing', {'intervalMs': intervalMs, 'maxDim': maxDim}) ?? false;
  }

  static Future<void> stopSharing() async {
    try {
      await _channel.invokeMethod<void>('stopSharing');
    } on MissingPluginException {
      // Nothing to stop.
    }
  }
}

/// 通话里开摄像头: the Dart side of `screencap/CameraCapturePlugin.kt`. The
/// camera follows the app: it pauses in the background and comes back with it.
class CameraCapture {
  CameraCapture._();

  static const _channel = MethodChannel('dsh/camcap');
  static const _frames = EventChannel('dsh/camcap/frames');

  static Stream<VisionFrame>? _stream;

  static Stream<VisionFrame> frames() =>
      _stream ??= _frames.receiveBroadcastStream().map(VisionFrame.fromEvent).where((f) => f != null).cast<VisionFrame>();

  static Future<bool> requestPermission() async {
    try {
      return await _channel.invokeMethod<bool>('requestPermission') ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Starts the back camera (or the front one), a kept frame every [sampleMs].
  static Future<bool> start({bool front = false, int sampleMs = 1000}) async {
    return await _channel.invokeMethod<bool>('start', {'front': front, 'sampleMs': sampleMs}) ?? false;
  }

  /// Turns to the other camera; returns whether the front one is on now.
  static Future<bool> switchCamera() async => await _channel.invokeMethod<bool>('switchCamera') ?? false;

  static Future<void> stop() async {
    try {
      await _channel.invokeMethod<void>('stop');
    } on MissingPluginException {
      // Nothing to stop.
    }
  }
}
