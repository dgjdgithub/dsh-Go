// 语音通话: one page over the conversation, lit like Siri but quieter: a
// sphere of clear glass with soft colour drifting inside, the same colour
// running faintly round the screen's edge, all of it made from the theme's
// colour and following its light or dark (call/call_visuals.dart). Behind it a dark field, the person's own picture,
// or 伙伴小屋's character mouthing the reply (call/call_backdrop.dart). What was
// heard and what she says arrive underneath; mute, hang up and loudspeaker sit
// at the bottom; an approval or question the conversation waits on comes up
// above them and is answered right here.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../media/screen_capture.dart';
import '../../performance/performance_state.dart';
import '../../state/android_features.dart' show operatingSystemProvider;
import '../../speech/call/chat_call.dart';
import '../../speech/call/voice_call.dart';
import '../../speech/read_aloud.dart';
import '../../speech/speech_out.dart';
import '../../speech/speech_settings.dart';
import '../../state/account_state.dart';
import '../companion/companion_ask.dart';
import '../companion/companion_stage.dart';
import '../fx/voice_ring/voice_ring.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import '../../speech/call/call_vision.dart';
import 'call/active_call.dart';
import 'call/call_backdrop.dart';
import 'call/call_parts.dart';
import 'call/call_transcript.dart';
import 'call/call_visuals.dart';
import 'speech_ui.dart';

/// Opens a call with the main chat's conversation. [session] gives its id,
/// creating it for a new chat; [title] heads the page. A call already under
/// way is brought back instead (one call at a time).
Future<void> openChatCall(
  BuildContext context, {
  required String title,
  required Future<String?> Function() session,
}) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final running = container.read(activeCallProvider);
  if (running != null && !running.ended) return showActiveCall(context, running);
  container.read(readAloudProvider.notifier).stop();
  final call = ActiveCall(container, title: title, conversation: ChatCallConversation(container, session));
  container.read(activeCallProvider.notifier).set(call);
  unawaited(call.start());
  await showActiveCall(context, call);
}

/// The call's page over whatever is open (from the return pill, a
/// notification, or a new call). Leaving it leaves the call going.
Future<void> showActiveCall(BuildContext context, ActiveCall call) async {
  if (call.onScreen || call.ended) return;
  await Navigator.of(context, rootNavigator: true).push(
    PageRouteBuilder<void>(
      opaque: true,
      fullscreenDialog: true,
      settings: const RouteSettings(name: voiceCallRouteName),
      transitionDuration: AppMotion.of(context, const Duration(milliseconds: 520)),
      reverseTransitionDuration: AppMotion.of(context, AppMotion.collapse),
      pageBuilder: (_, _, _) => VoiceCallPage(title: call.title, call: call),
      transitionsBuilder: (_, animation, _, child) {
        final curve = CurvedAnimation(parent: animation, curve: AppMotion.enter, reverseCurve: AppMotion.exit);
        // Opening: the page rises out of the dark.
        return FadeTransition(
          opacity: curve,
          child: ScaleTransition(scale: Tween(begin: 1.06, end: 1.0).animate(curve), child: child),
        );
      },
    ),
  );
}

/// The call page's route name.
const voiceCallRouteName = 'voice-call';

class VoiceCallPage extends ConsumerStatefulWidget {
  /// A view of [call], or (with [conversation]) a call of the page's own,
  /// hung up when the page goes.
  const VoiceCallPage({super.key, required this.title, this.conversation, this.call})
    : assert((conversation == null) != (call == null));

  final String title;
  final CallConversation? conversation;
  final ActiveCall? call;

  @override
  ConsumerState<VoiceCallPage> createState() => _VoiceCallPageState();
}

class _VoiceCallPageState extends ConsumerState<VoiceCallPage> with WidgetsBindingObserver, TickerProviderStateMixin {
  late final ActiveCall _active;

  /// The page made [_active] (no global call): it ends with the page.
  late final bool _owned;
  VoiceCallController get _call => _active.controller;
  int _noticeSeen = 0;
  final _scene = CallScene();
  late final AnimationController _enter = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );
  Timer? _leave;
  DateTime? get _since => _active.since;
  CallPhase _shown = CallPhase.starting;

  // Her, when she is the backdrop.
  final _stage = CompanionStageController();
  bool _stageReady = false;
  bool _stageFailed = false;
  String? _imageChecked;
  bool _imageExists = false;
  double _mouthAt = 0;
  bool _mouthOpen = false;

  /// A finger on the light: it gives a little.
  bool _pressed = false;

  /// 共享屏幕 / 摄像头 being turned on (the system sheet may be up).
  bool _visionBusy = false;

  /// The system asks for less motion (read each build): the light holds still
  /// and the page comes in without its staggered rise.
  bool _still = false;

  /// What [build] shows of the call. Not the audio levels: the light reads those
  /// itself each frame, so they alone (some 25 updates a second) leave the page as it is.
  Object _shows() => (
    _call.phase,
    _call.ended,
    _call.muted,
    _call.speaker,
    _call.heard,
    _call.caption,
    _call.error,
    _call.turns.isEmpty,
    _call.ended == CallEnd.noRecognizer && ref.read(accountProvider).signedIn,
    _active.sessionId,
    _active.vision.source,
    _active.vision.frontCamera,
    _active.vision.watch,
    _active.vision.preview,
    _active.since,
    _visionBusy,
  );

  /// [_shows] as of the last build.
  Object? _built;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final given = widget.call;
    _owned = given == null;
    _active = given ?? ActiveCall(ProviderScope.containerOf(context, listen: false), title: widget.title, conversation: widget.conversation!);
    _noticeSeen = _active.notice?.$1 ?? 0;
    _shown = _call.phase;
    _active
      ..attachView()
      ..addListener(_changed);
    HapticFeedback.mediumImpact();
    _enter.forward();
    if (_owned) unawaited(_active.start());
    // Came back to a call that ended meanwhile: the page goes again.
    if (_call.phase == CallPhase.ended) WidgetsBinding.instance.addPostFrameCallback((_) => _changed());
  }

  void _changed() {
    if (!mounted) return;
    final phase = _call.phase;
    if (_active.notice case (final serial, final text) when serial != _noticeSeen) {
      _noticeSeen = serial;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text)));
    }
    if (phase != _shown) {
      _arrived(phase);
      _shown = phase;
    }
    if (phase == CallPhase.ended && _leave == null) {
      // Hung up: the light sinks away first. Ended for a reason: the reason stays a moment.
      _leave = Timer(
        _call.ended == CallEnd.hungUp ? const Duration(milliseconds: 380) : const Duration(milliseconds: 2600),
        () {
          if (!mounted) return;
          // The call page itself, not a sheet open over it (字幕, 背景).
          final route = ModalRoute.of(context);
          // Already left (Back just before this): nothing of anyone else's is closed.
          if (route == null || !route.isActive) return;
          final navigator = Navigator.of(context);
          if (!route.isCurrent) navigator.popUntil((r) => r == route);
          unawaited(navigator.maybePop());
        },
      );
    }
    if (_shows() != _built) setState(() {});
  }

  /// A new phase: a touch under the finger, and her mood when she is there.
  void _arrived(CallPhase phase) {
    switch (phase) {
      case CallPhase.listening when _shown == CallPhase.starting:
        HapticFeedback.lightImpact();
      case CallPhase.hearing:
        HapticFeedback.selectionClick();
      case CallPhase.speaking:
        HapticFeedback.lightImpact();
      case CallPhase.ended:
        HapticFeedback.mediumImpact();
      default:
        break;
    }
    if (_stageReady) {
      _stage.command('mood', {
        'mood': switch (phase) {
          CallPhase.thinking || CallPhase.starting => 'thinking',
          CallPhase.speaking => 'speaking',
          CallPhase.ended => 'idle',
          _ => 'listening',
        },
      });
      if (phase != CallPhase.speaking) _stage.command('quiet');
    }
  }

  void _tick(double seconds) {
    _scene.tick(
      seconds,
      phase: _call.phase,
      mic: _call.micLevel,
      voice: _call.voiceLevel,
      isMuted: _call.muted,
      still: _still,
    );
    // Her mouth follows the voice, twenty times a second at most.
    if (_stageReady && seconds - _mouthAt > 0.05) {
      final speaking = _call.phase == CallPhase.speaking;
      final open = speaking ? (_scene.level * 1.3).clamp(0.0, 1.0) : 0.0;
      if (speaking || _mouthOpen) {
        _stage.command('mouth', {'value': open});
        _mouthOpen = open > 0;
        _mouthAt = seconds;
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 允许后台: the call keeps going when the app is backgrounded (the native
    // call foreground service holds the microphone and playback). Coming back
    // just resumes drawing. Only an explicit hang-up ends the call.
    if (state == AppLifecycleState.resumed) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _leave?.cancel();
    _enter.dispose();
    _active.removeListener(_changed);
    if (_owned) {
      _active.dispose();
    } else {
      _active.detachView();
    }
    _scene.dispose();
    super.dispose();
  }

  void _hangUp() {
    HapticFeedback.heavyImpact();
    _active.hangUp();
  }

  void _say(String text) => ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text)));

  /// 共享屏幕: on asks the system (whole screen or one window); off stops it.
  /// The camera goes off first: one picture at a time.
  Future<void> _toggleScreen() async {
    HapticFeedback.selectionClick();
    final vision = _active.vision;
    if (vision.source == VisionSource.screen) return vision.stop();
    setState(() => _visionBusy = true);
    final result = await vision.startScreen();
    if (!mounted) return;
    setState(() => _visionBusy = false);
    switch (result) {
      case CallVisionStart.started:
        break;
      case CallVisionStart.declined:
        _say(context.l10n.speechCallScreenDeclined);
      case CallVisionStart.unsupported || CallVisionStart.failed:
        _say(context.l10n.speechCallScreenFailed);
    }
  }

  /// 摄像头: the back camera; the little window turns it round.
  Future<void> _toggleCamera() async {
    HapticFeedback.selectionClick();
    final vision = _active.vision;
    if (vision.source == VisionSource.camera) return vision.stop();
    setState(() => _visionBusy = true);
    final result = await vision.startCamera();
    if (!mounted) return;
    setState(() => _visionBusy = false);
    switch (result) {
      case CallVisionStart.started:
        break;
      case CallVisionStart.declined:
        _say(context.l10n.speechCallCameraDeclined);
      case CallVisionStart.unsupported || CallVisionStart.failed:
        _say(context.l10n.speechCallCameraFailed);
    }
  }

  (String, bool) _status(L10n l10n) {
    if (_call.phase == CallPhase.ended) {
      return (
        switch (_call.ended) {
          CallEnd.permission => l10n.speechCallEndPermission,
          CallEnd.microphone => l10n.speechCallEndMicrophone,
          CallEnd.noRecognizer =>
            wordsForIos
                ? (ref.read(accountProvider).signedIn
                      ? l10n.iosSpeechCallEndNoRecognizerSignedIn
                      : l10n.iosSpeechCallEndNoRecognizer)
                : (ref.read(accountProvider).signedIn
                      ? l10n.speechCallEndNoRecognizerSignedIn
                      : l10n.speechCallEndNoRecognizer),
          CallEnd.background => l10n.speechCallEndBackground,
          CallEnd.failed => l10n.speechCallEndFailed,
          CallEnd.hungUp || null => l10n.speechCallEnded,
        },
        false,
      );
    }
    if (_call.muted && _call.phase != CallPhase.speaking && _call.phase != CallPhase.thinking) {
      return (l10n.speechCallMuted, false);
    }
    return switch (_call.phase) {
      CallPhase.starting => (l10n.speechCallStarting, true),
      CallPhase.listening => (l10n.speechCallListening, true),
      CallPhase.hearing => (l10n.speechCallHearing, false),
      CallPhase.thinking => (l10n.speechCallThinking, true),
      CallPhase.speaking => (l10n.speechCallSpeaking, false),
      CallPhase.ended => (l10n.speechCallEnded, false),
    };
  }

  /// The light in the middle: Libraries.dev's voice ring (its ribbon or its single line),
  /// listening to the person, speaking with her voice, turning while it thinks; or the glass orb.
  Widget _light(CallVisual visual, CallPalette palette, bool dark, double size) {
    if (visual == CallVisual.glass) {
      return CallLight(key: const ValueKey('glass'), scene: _scene, palette: palette, size: size);
    }
    final phase = _call.phase;
    return VoiceRing(
      key: ValueKey(visual),
      type: visual == CallVisual.mono ? VoiceRingType.mono : VoiceRingType.ring,
      state: switch (phase) {
        CallPhase.starting || CallPhase.thinking => VoiceRingState.processing,
        CallPhase.listening || CallPhase.hearing => VoiceRingState.listening,
        CallPhase.speaking => VoiceRingState.speaking,
        CallPhase.ended => VoiceRingState.idle,
      },
      size: size * 0.82,
      theme: dark ? VoiceRingTheme.dark : VoiceRingTheme.light,
      paused: phase == CallPhase.ended,
      level: () => switch (_call.phase) {
        CallPhase.hearing when !_call.muted => VoiceRingLevel.mic(_call.micLevel),
        CallPhase.speaking => VoiceRingLevel.playback(_call.voiceLevel),
        _ => 0,
      },
    );
  }

  /// [child] coming in with the page: a fade and a short rise, starting at [from] (0–1).
  Widget _rise(double from, Widget child, {double distance = 18}) {
    if (_still) return child;
    final curve = _enter.drive(CurveTween(curve: Interval(from, math.min(1, from + 0.5), curve: Curves.easeOutCubic)));
    return AnimatedBuilder(
      animation: curve,
      builder: (context, child) => Opacity(
        opacity: curve.value,
        child: Transform.translate(offset: Offset(0, (1 - curve.value) * distance), child: child),
      ),
      child: child,
    );
  }

  /// The light, which gives a little under the finger; tapped while she speaks, she skips ahead.
  Widget _lightKey(L10n l10n, String status, CallVisual visual, CallPalette palette, bool dark, double size) {
    return Semantics(
      button: _call.phase == CallPhase.speaking,
      label: status,
      hint: _call.phase == CallPhase.speaking ? l10n.speechCallSkipHint : null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: _call.phase == CallPhase.speaking
            ? () {
                HapticFeedback.lightImpact();
                _call.skip();
              }
            : null,
        child: AnimatedScale(
          scale: _pressed ? 0.93 : 1,
          duration: AppMotion.of(context, _pressed ? AppMotion.press : const Duration(milliseconds: 420)),
          curve: _pressed ? Curves.easeOut : Curves.elasticOut,
          child: AnimatedSwitcher(
            duration: AppMotion.of(context, AppMotion.slow),
            child: _light(visual, palette, dark, size),
          ),
        ),
      ),
    );
  }

  /// [child] growing and shrinking smoothly as its words come and go (at once with less motion).
  Widget _grow(Widget child) => _still
      ? child
      : AnimatedSize(
          duration: AppMotion.of(context, AppMotion.emphasized),
          curve: AppMotion.std,
          alignment: Alignment.bottomCenter,
          child: child,
        );

  void _openTranscript() {
    HapticFeedback.selectionClick();
    unawaited(showCallTranscript(context, _call));
  }

  @override
  Widget build(BuildContext context) {
    _built = _shows();
    final l10n = context.l10n;
    final theme = Theme.of(context);
    _still = AppMotion.reduced(context);
    final settings = ref.watch(callSettingsProvider);
    final performance = ref.watch(performanceDefaultsProvider);
    final blur = performance.blur;
    // The keys sit over a field that moves every frame, so their frosting is redone every
    // frame too: more than HarmonyOS's renderer, or the light mode, can spare.
    final keyBlur = blur && !performance.lightweight && ref.watch(operatingSystemProvider) != 'ohos';
    final ended = _call.phase == CallPhase.ended;
    // Looked up once per picture, not on each of the 25 level updates a second.
    if (settings.image != _imageChecked) {
      _imageChecked = settings.image;
      _imageExists = settings.image.isNotEmpty && File(settings.image).existsSync();
    }
    final image = settings.backdrop == CallBackdrop.image && _imageExists ? settings.image : null;
    final her = settings.backdrop == CallBackdrop.companion && !_stageFailed;
    final (status, dots) = _status(l10n);
    final error = _call.error;
    final sessionId = _active.sessionId;
    final vision = _active.vision;
    final watching = vision.watch;
    final width = MediaQuery.sizeOf(context).width;
    final lightSize = math.min(340.0, width * 0.86);
    final hearing = _call.phase == CallPhase.hearing;
    final heard = ended ? '' : _call.heard;
    // While the person speaks, her last words step aside for theirs.
    final reply = hearing ? '' : speakable(_call.caption).replaceAll('\n', ' ');
    final failing = ended ? null : error;
    // Light or dark as the theme is; a picture or her behind always reads as dark.
    final dark = theme.brightness == Brightness.dark || image != null || her;
    final palette = CallPalette.of(theme.colorScheme, light: !dark);
    final ink = CallInk(dark: dark, child: const SizedBox());

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      child: CallInk(
        dark: dark,
        child: Scaffold(
          backgroundColor: palette.field,
          body: CallClock(
            onTick: _tick,
            child: Stack(
              fit: StackFit.expand,
              children: [
                CallField(scene: _scene, palette: palette, center: her ? 0.66 : 0.4),
                // A new backdrop fades in over the old one.
                AnimatedSwitcher(
                  duration: AppMotion.of(context, AppMotion.slow),
                  switchInCurve: AppMotion.enter,
                  switchOutCurve: AppMotion.exit,
                  child: switch ((image, her)) {
                    (final path?, _) => ImageBackdrop(key: ValueKey(path), path: path, blur: blur),
                    (_, true) => CompanionBackdrop(
                      key: const ValueKey('her'),
                      controller: _stage,
                      onReady: () {
                        if (!mounted) return;
                        setState(() => _stageReady = true);
                        _arrived(_call.phase);
                      },
                      onFailed: () {
                        if (mounted) {
                          setState(() {
                            _stageFailed = true;
                            _stageReady = false;
                          });
                        }
                      },
                    ),
                    _ => const SizedBox.expand(key: ValueKey('sea')),
                  },
                ),
                // The screen's edge glows only with the glass orb; the ring is light enough on its own.
                if (settings.visual == CallVisual.glass) CallEdgeGlow(scene: _scene, palette: palette),
                if (her)
                  // Her feet fade into the water so the words below stay readable.
                  const IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Color(0x00030712), Color(0x00030712), Color(0xD9030712), Color(0xF2030712)],
                          stops: [0, 0.46, 0.7, 1],
                        ),
                      ),
                    ),
                  ),
                SafeArea(
                  child: Column(
                    children: [
                      _rise(
                        0.05,
                        _TopBar(
                          title: widget.title,
                          since: _since,
                          live: !ended && _since != null,
                          blur: keyBlur,
                          onTranscript: _openTranscript,
                          onBackdrop: ended
                              ? null
                              // Trying voices out plays on her speaker: she stops this reply first.
                              : () => unawaited(showCallBackdropSheet(context, inCall: true, beforeVoice: _call.skip)),
                        ),
                        distance: -14,
                      ),
                      Expanded(
                        child: her
                            ? const SizedBox.expand()
                            : LayoutBuilder(
                                // The words below take the room they need; the light gives way (to 56 % at least).
                                builder: (context, box) => Center(
                                  child: Transform.scale(
                                    scale: (box.maxHeight / (lightSize * 1.04)).clamp(0.56, 1.0),
                                    child: OverflowBox(
                                      maxWidth: lightSize,
                                      maxHeight: lightSize,
                                      child: _lightKey(l10n, status, settings.visual, palette, dark, lightSize),
                                    ),
                                  ),
                                ),
                              ),
                      ),
                      _rise(
                        0.3,
                        CallStatus(
                          text: status,
                          dots: dots,
                          color: ended && _call.ended != CallEnd.hungUp ? ink.warn : null,
                        ),
                      ),
                      const SizedBox(height: 14),
                      // What is being said, as much of it as fits; a tap opens all of it.
                      Semantics(
                        button: _call.turns.isNotEmpty,
                        hint: _call.turns.isNotEmpty ? l10n.speechCallTranscriptHint : null,
                        child: GestureDetector(
                          key: const ValueKey('call-captions'),
                          behavior: HitTestBehavior.opaque,
                          onTap: _call.turns.isEmpty ? null : _openTranscript,
                          child: _grow(
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 28),
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(maxWidth: 560),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    HeardLine(text: heard, speaking: hearing),
                                    if (heard.isNotEmpty && (reply.isNotEmpty || failing != null))
                                      const SizedBox(height: 12),
                                    if (failing != null)
                                      Text(
                                        speechErrorText(l10n, failing, listening: true),
                                        key: const ValueKey('call-error'),
                                        textAlign: TextAlign.center,
                                        style: theme.textTheme.bodyMedium?.copyWith(color: ink.warn),
                                      )
                                    else
                                      RevealText(
                                        key: const ValueKey('call-reply'),
                                        text: reply,
                                        done: _call.phase != CallPhase.speaking,
                                        style: theme.textTheme.bodyLarge?.copyWith(
                                          color: ink.fg.withValues(alpha: 0.94),
                                          height: 1.6,
                                          fontSize: 18,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (watching != null && !ended)
                        Padding(
                          key: const ValueKey('call-watching'),
                          padding: const EdgeInsets.fromLTRB(28, 10, 28, 0),
                          child: Text(
                            l10n.speechCallWatching(watching.condition),
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(color: ink.fg.withValues(alpha: 0.72)),
                          ),
                        ),
                      if (sessionId != null)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                          child: CompanionAsk(sessionId: sessionId),
                        ),
                      const SizedBox(height: 26),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          _rise(
                            0.4,
                            CallKey(
                              key: const ValueKey('call-mute'),
                              icon: _call.muted ? AppIcons.micMuted : AppIcons.voice,
                              label: _call.muted ? l10n.speechCallUnmute : l10n.speechCallMute,
                              on: _call.muted,
                              blur: keyBlur,
                              onTap: ended ? null : () => _call.setMuted(!_call.muted),
                            ),
                            distance: 28,
                          ),
                          _rise(
                            0.44,
                            CallKey(
                              key: const ValueKey('call-share-screen'),
                              icon: vision.source == VisionSource.screen ? AppIcons.stopSharing : AppIcons.shareImage,
                              label: vision.source == VisionSource.screen
                                  ? l10n.speechCallScreenStop
                                  : l10n.speechCallScreen,
                              on: vision.source == VisionSource.screen,
                              blur: keyBlur,
                              onTap: ended || _visionBusy ? null : () => unawaited(_toggleScreen()),
                            ),
                            distance: 26,
                          ),
                          _rise(
                            0.48,
                            HangUpKey(
                              key: const ValueKey('call-hang-up'),
                              icon: AppIcons.hangUp,
                              label: l10n.speechCallHangUp,
                              onTap: ended ? null : _hangUp,
                            ),
                            distance: 34,
                          ),
                          _rise(
                            0.52,
                            CallKey(
                              key: const ValueKey('call-camera'),
                              icon: AppIcons.camera,
                              label: vision.source == VisionSource.camera
                                  ? l10n.speechCallCameraStop
                                  : l10n.speechCallCamera,
                              on: vision.source == VisionSource.camera,
                              blur: keyBlur,
                              onTap: ended || _visionBusy ? null : () => unawaited(_toggleCamera()),
                            ),
                            distance: 26,
                          ),
                          _rise(
                            0.56,
                            CallKey(
                              key: const ValueKey('call-speaker'),
                              icon: _call.speaker ? AppIcons.readAloud : AppIcons.earpiece,
                              label: _call.speaker ? l10n.speechCallSpeakerOn : l10n.speechCallEarpiece,
                              on: _call.speaker,
                              blur: keyBlur,
                              onTap: ended ? null : () => unawaited(_call.setSpeaker(!_call.speaker)),
                            ),
                            distance: 28,
                          ),
                        ],
                      ),
                      const SizedBox(height: 28),
                    ],
                  ),
                ),
                if (vision.source == VisionSource.camera && !ended)
                  Positioned(
                    top: MediaQuery.viewPaddingOf(context).top + 72,
                    right: 16,
                    child: _CameraWindow(
                      frame: vision.preview,
                      onSwitch: () => unawaited(vision.switchCamera()),
                      switchLabel: l10n.speechCallCameraSwitch,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The top bar: the clock and the conversation's name in one frosted capsule,
/// between two frosted round keys, 字幕 and 背景, all three the same height.
class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.title,
    required this.since,
    required this.live,
    required this.blur,
    required this.onTranscript,
    required this.onBackdrop,
  });

  final String title;
  final DateTime? since;
  final bool live;
  final bool blur;
  final VoidCallback onTranscript;
  final VoidCallback? onBackdrop;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final ink = CallInk.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
      child: Row(
        children: [
          _RoundKey(
            key: const ValueKey('call-transcript'),
            icon: AppIcons.callTranscript,
            label: l10n.speechCallTranscriptHint,
            blur: blur,
            onTap: onTranscript,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Center(
              child: _Frosted(
                blur: blur,
                shape: const StadiumBorder(),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CallTimer(since: since, live: live),
                      Container(
                        width: 1,
                        height: 14,
                        margin: const EdgeInsets.symmetric(horizontal: 10),
                        color: ink.glassBorder,
                      ),
                      Flexible(
                        child: Text(
                          title,
                          key: const ValueKey('call-title'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: ink.fg,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.2,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          _RoundKey(
            key: const ValueKey('call-backdrop'),
            icon: AppIcons.settings,
            label: l10n.speechCallSettings,
            blur: blur,
            onTap: onBackdrop,
          ),
        ],
      ),
    );
  }
}

/// Frosted glass 40 high in [shape]: the call's glass tint and hairline over a
/// blur of what is behind ([blur], as the performance setting allows).
class _Frosted extends StatelessWidget {
  const _Frosted({required this.shape, required this.blur, required this.child, this.width});

  final OutlinedBorder shape;
  final bool blur;
  final double? width;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ink = CallInk.of(context);
    final glass = Container(
      width: width,
      height: 40,
      decoration: ShapeDecoration(
        color: ink.glass,
        shape: shape.copyWith(side: BorderSide(color: ink.glassBorder)),
      ),
      child: child,
    );
    if (!blur) return glass;
    return ClipPath(
      clipper: ShapeBorderClipper(shape: shape),
      child: BackdropFilter(filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18), child: glass),
    );
  }
}

/// A small round glass key in the top bar; gives a little under the finger.
class _RoundKey extends StatefulWidget {
  const _RoundKey({super.key, required this.icon, required this.label, required this.blur, required this.onTap});

  final IconData icon;
  final String label;
  final bool blur;
  final VoidCallback? onTap;

  @override
  State<_RoundKey> createState() => _RoundKeyState();
}

class _RoundKeyState extends State<_RoundKey> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final ink = CallInk.of(context);
    final onTap = widget.onTap;
    return Semantics(
      button: true,
      enabled: onTap != null,
      label: widget.label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: onTap == null ? null : (_) => setState(() => _down = true),
        onTapCancel: () => setState(() => _down = false),
        onTapUp: (_) => setState(() => _down = false),
        onTap: onTap == null
            ? null
            : () {
                HapticFeedback.selectionClick();
                onTap();
              },
        child: AnimatedScale(
          scale: _down ? 0.9 : 1,
          duration: AppMotion.of(context, _down ? AppMotion.press : AppMotion.standard),
          curve: _down ? Curves.easeOut : Curves.easeOutBack,
          child: _Frosted(
            width: 40,
            shape: const CircleBorder(),
            blur: widget.blur,
            child: Icon(widget.icon, size: 18, color: ink.fg.withValues(alpha: onTap == null ? 0.35 : 0.8)),
          ),
        ),
      ),
    );
  }
}

/// The camera's picture in a corner of the call, a tap turning the camera round.
class _CameraWindow extends StatelessWidget {
  const _CameraWindow({required this.frame, required this.onSwitch, required this.switchLabel});

  final VisionFrame? frame;
  final VoidCallback onSwitch;
  final String switchLabel;

  @override
  Widget build(BuildContext context) {
    final jpeg = frame?.jpeg;
    final ratio = frame == null || frame!.height == 0 ? 3 / 4 : frame!.width / frame!.height;
    return Semantics(
      button: true,
      label: switchLabel,
      child: GestureDetector(
        key: const ValueKey('call-camera-window'),
        onTap: onSwitch,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: Container(
            width: 112,
            height: 112 / ratio.clamp(0.4, 2.0),
            color: const Color(0xFF0B1020),
            child: jpeg == null
                ? const Center(child: SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)))
                : Image.memory(jpeg, fit: BoxFit.cover, gaplessPlayback: true),
          ),
        ),
      ),
    );
  }
}
