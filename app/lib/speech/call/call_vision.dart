// 通话里的画面: what a call sees (the shared screen or the camera) and the
// watching done on it, after Doubao's video call but without a video stream.
//
// Doubao streams ~6 fps to a cloud VLM that decides on its own when to speak
// (its server flags `video_model_proactive_speak`). Here the main model gets
// pictures with what the person says (frames from while they spoke, picked by
// timestamp: [framesFor]); for 「…了叫我」 it calls watch_screen with a
// condition, and this class does the watching: on a visible change (the native
// gate already drops still frames) it asks the 看图模型 (vision_judge.dart)
// with the condition, the call's last turns and the newest frames, and on a
// hit [onHit] has her say it in the call. Model calls are paced and capped.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../../media/screen_capture.dart';
import '../../media/screen_frame_store.dart';
import 'vision_judge.dart';
import 'vision_settings.dart';

/// Something being watched for (from the model's watch_screen call).
class CallWatch {
  CallWatch({required this.condition, this.remind, required this.until, this.callId})
    : startedAt = DateTime.now();

  final String condition;
  final String? remind;
  final DateTime startedAt;
  final DateTime until;

  /// The watch_screen tool call this came from.
  final String? callId;
}

/// What was seen: the watch it answers (null for 陪看), her line, the frame.
class CallVisionHit {
  const CallVisionHit({required this.watch, required this.say, required this.frame});

  final CallWatch? watch;
  final String say;
  final VisionFrame frame;
}

enum CallVisionStart { started, declined, unsupported, failed }

class CallVision extends ChangeNotifier {
  CallVision({
    required this.settings,
    required this.apiKey,
    required this.context,
    required this.onHit,
    this.onNotice,
    VisionJudge? judge,
    DateTime Function()? clock,
  }) : _judge = judge ?? VisionJudge(),
       _now = clock ?? DateTime.now;

  final Future<VisionSettings> Function() settings;
  final Future<String?> Function() apiKey;

  /// The call's last turns, for the judge to understand the condition.
  final List<String> Function() context;
  final void Function(CallVisionHit hit) onHit;

  /// Something to tell the person (sharing stopped, the judge failing).
  final void Function(String text)? onNotice;

  final VisionJudge _judge;
  final DateTime Function() _now;

  static const _keepFor = Duration(seconds: 90);
  static const _ringSize = 24;
  static const _perMinute = 8;

  VisionSource? _source;
  bool _front = false;
  VisionFrame? _preview;
  final _ring = <VisionFrame>[];
  StreamSubscription<VisionFrame>? _sub;
  Timer? _limit;
  Timer? _beat;
  CallWatch? _watch;
  bool _judging = false;
  DateTime? _judgedAt;
  double _changeSince = 0;
  final _calls = <DateTime>[];
  int _failures = 0;
  bool _disposed = false;
  bool _judgeReady = false;
  bool _companion = false;

  VisionSource? get source => _source;
  bool get frontCamera => _front;
  CallWatch? get watch => _watch;

  /// The camera's newest small frame, for the call page's window.
  VisionFrame? get preview => _preview;

  /// The newest kept frame.
  VisionFrame? get latest => _ring.isEmpty ? null : _ring.last;

  Future<CallVisionStart> startScreen() async {
    if (_source == VisionSource.screen) return CallVisionStart.started;
    await stop();
    try {
      final started = await ScreenCapture.startSharing(intervalMs: 1000, maxDim: 1024);
      if (_disposed) {
        if (started) unawaited(ScreenCapture.stopSharing());
        return CallVisionStart.failed;
      }
      if (!started) return CallVisionStart.declined;
    } on MissingPluginException {
      return CallVisionStart.unsupported;
    } on PlatformException {
      return CallVisionStart.failed;
    }
    _begin(VisionSource.screen, ScreenCapture.frames());
    return CallVisionStart.started;
  }

  Future<CallVisionStart> startCamera({bool front = false}) async {
    if (_source == VisionSource.camera) return CallVisionStart.started;
    await stop();
    try {
      if (!await CameraCapture.requestPermission()) return CallVisionStart.declined;
      if (_disposed) return CallVisionStart.failed;
      // Subscribed before the first frame can come.
      _begin(VisionSource.camera, CameraCapture.frames());
      _front = front;
      if (!await CameraCapture.start(front: front, sampleMs: 1000)) {
        await stop();
        return CallVisionStart.failed;
      }
    } on MissingPluginException {
      await stop();
      return CallVisionStart.unsupported;
    } on PlatformException {
      await stop();
      return CallVisionStart.failed;
    }
    return CallVisionStart.started;
  }

  Future<void> switchCamera() async {
    if (_source != VisionSource.camera) return;
    try {
      _front = await CameraCapture.switchCamera();
    } on PlatformException {
      return;
    }
    notifyListeners();
  }

  void _begin(VisionSource source, Stream<VisionFrame> frames) {
    _source = source;
    _ring.clear();
    _preview = null;
    _changeSince = 0;
    _sub = frames.listen(_onFrame, onError: (Object error) {
      if (_source != source) return;
      unawaited(stop());
      onNotice?.call(source == VisionSource.screen ? appL10n.speechCallScreenStopped : appL10n.speechCallCameraStopped);
    });
    unawaited(_refreshSettings().then((s) {
      _limit?.cancel();
      if (_source == source) {
        _limit = Timer(Duration(minutes: s.maxMinutes), () {
          if (_source != source) return;
          unawaited(stop());
          onNotice?.call(appL10n.speechCallVisionTimeUp(s.maxMinutes));
        });
      }
      _writeStatus();
    }));
    // The tools take a frame older than 30 s as "not shared": a still screen sends none.
    _beat = Timer.periodic(const Duration(seconds: 10), (_) => _writeStatus());
    notifyListeners();
  }

  Future<VisionSettings> _refreshSettings() async {
    final s = await settings();
    _judgeReady = s.configured;
    _companion = s.companion;
    return s;
  }

  void _writeStatus() {
    if (_disposed) return;
    unawaited(ScreenFrameStore.status(source: _source?.name, judge: _judgeReady));
  }

  Future<void> stop() async {
    final was = _source;
    _source = null;
    await _sub?.cancel();
    _sub = null;
    _limit?.cancel();
    _beat?.cancel();
    _ring.clear();
    _preview = null;
    _watch = null;
    if (was == VisionSource.screen) await ScreenCapture.stopSharing();
    if (was == VisionSource.camera) await CameraCapture.stop();
    if (was != null) unawaited(ScreenFrameStore.status(source: null, judge: _judgeReady));
    if (!_disposed) notifyListeners();
  }

  void _onFrame(VisionFrame frame) {
    if (_disposed || frame.source != _source) return;
    if (frame.source == VisionSource.camera && frame.jpeg != null) {
      _preview = frame;
      notifyListeners();
    }
    final jpeg = frame.jpeg;
    if (jpeg == null || !frame.keep) {
      if (frame.still) unawaited(_maybeJudge(null));
      return;
    }
    _ring.add(frame);
    final cutoff = frame.at.subtract(_keepFor);
    while (_ring.length > _ringSize || (_ring.length > 2 && _ring.first.at.isBefore(cutoff))) {
      _ring.removeAt(0);
    }
    unawaited(ScreenFrameStore.write(jpeg));
    _changeSince += frame.change;
    unawaited(_maybeJudge(frame));
  }

  /// Frames for a message: the last one from before [from] (what was there when
  /// they began), the most changed one while they spoke, and the newest; at
  /// most three, oldest first. Without times, the newest.
  List<VisionFrame> framesFor({DateTime? from, DateTime? to}) {
    if (_ring.isEmpty) return const [];
    final newest = _ring.last;
    if (from == null) return [newest];
    final end = to ?? _now();
    VisionFrame? before;
    final during = <VisionFrame>[];
    for (final f in _ring) {
      if (f.at.isBefore(from)) {
        before = f;
      } else if (!f.at.isAfter(end)) {
        during.add(f);
      }
    }
    final picked = <VisionFrame>{};
    if (before != null && (during.isNotEmpty || identical(before, newest))) picked.add(before);
    if (during.length > 1) {
      final rest = during.sublist(0, during.length - 1)..sort((a, b) => b.change.compareTo(a.change));
      if (rest.first.change >= 0.03) picked.add(rest.first);
    }
    picked.add(newest);
    return picked.toList()..sort((a, b) => a.at.compareTo(b.at));
  }

  /// From watch_screen: watch for [condition] (replacing any watch on).
  Future<bool> setWatch(String condition, {String? remind, double? minutes, String? callId}) async {
    if (_source == null) return false;
    final s = await _refreshSettings();
    if (!s.configured || _source == null) return false;
    final span = (minutes ?? 30).clamp(1, s.maxMinutes).toDouble();
    _watch = CallWatch(
      condition: condition,
      remind: remind,
      until: _now().add(Duration(seconds: (span * 60).round())),
      callId: callId,
    );
    _failures = 0;
    // Already true when asked: the first look is now.
    _judgedAt = null;
    _changeSince = 1;
    notifyListeners();
    unawaited(_maybeJudge(latest));
    return true;
  }

  void clearWatch() {
    if (_watch == null) return;
    _watch = null;
    notifyListeners();
  }

  Future<void> _maybeJudge(VisionFrame? frame) async {
    if (_disposed || _judging || _source == null) return;
    final now = _now();
    final watch = _watch;
    if (watch != null && now.isAfter(watch.until)) {
      _watch = null;
      notifyListeners();
      onNotice?.call(appL10n.speechCallWatchExpired(watch.condition));
      return;
    }
    final companion = watch == null && _companion && _judgeReady;
    if (watch == null && !companion) return;
    final last = _judgedAt;
    final since = last == null ? null : now.difference(last);
    if (watch != null) {
      // A change, or now and then anyway (a slow progress bar barely changes the picture).
      final due = since == null || (since >= const Duration(seconds: 4) && _changeSince >= 0.02) ||
          since >= const Duration(seconds: 20);
      if (!due) return;
    } else {
      if (since != null && since < const Duration(seconds: 20)) return;
      if (_changeSince < 0.08) return;
    }
    _calls.removeWhere((t) => now.difference(t) > const Duration(minutes: 1));
    if (_calls.length >= _perMinute) return;
    final frames = _ring.length <= 2 ? List.of(_ring) : _ring.sublist(_ring.length - 2);
    if (frames.isEmpty) return;
    _judging = true;
    _calls.add(now);
    _judgedAt = now;
    _changeSince = 0;
    try {
      final s = await settings();
      final verdict = await _judge.ask(
        baseUrl: s.baseUrl,
        model: s.model,
        apiKey: await apiKey(),
        condition: watch?.condition,
        remind: watch?.remind,
        context: context(),
        frames: frames,
      );
      _failures = 0;
      // Stopped, or the watch changed, while it was asked: the answer is for nothing now.
      if (_disposed || _source == null || !identical(_watch, watch)) return;
      if (!verdict.met) return;
      if (watch != null) _watch = null;
      notifyListeners();
      onHit(CallVisionHit(
        watch: watch,
        say: verdict.say.isNotEmpty ? verdict.say : (watch == null ? '' : appL10n.speechCallWatchMet(watch.condition)),
        frame: frames.last,
      ));
    } on Object catch (error) {
      if (kDebugMode) debugPrint('vision judge: $error');
      if (++_failures >= 3 && _watch != null && identical(_watch, watch)) {
        _watch = null;
        notifyListeners();
        onNotice?.call(appL10n.speechCallVisionDown);
      }
    } finally {
      _judging = false;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(stop());
    super.dispose();
  }
}
