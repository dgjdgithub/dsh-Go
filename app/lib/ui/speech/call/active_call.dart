// The call itself, apart from its page: the controller, its conversation, live
// captions, what it sees (call_vision.dart). It lives in [activeCallProvider]
// from the first ring to the hang-up, so leaving the page (Back, a tapped
// notification, another chat) leaves the call going; the page is one view of
// it, and a pill over the app (call_return_host.dart) brings it back.

import 'dart:async';
import 'dart:convert';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../companion/companion_voice.dart';
import '../../../companion/companion_voice_source.dart';
import '../../../l10n/l10n.dart';
import '../../../speech/call/call_vision.dart';
import '../../../speech/call/chat_call.dart';
import '../../../speech/call/thinking_cue.dart';
import '../../../speech/call/vision_settings.dart';
import '../../../speech/call/voice_call.dart';
import '../../../speech/deepseek_speech.dart';
import '../../../speech/speech_audio.dart';
import '../../../speech/speech_out.dart';
import '../../../speech/speech_settings.dart';
import '../../../speech/voice_cloud.dart';
import '../../../state/app_notes.dart';
import '../../../state/hosts_state.dart';
import '../../../state/notify_state.dart';
import '../../../state/streaming_asr_state.dart';
import '../../../state/streaming_pcm_state.dart';
import '../../../state/voice_settings.dart';
import '../../../state/voice_state.dart';
import '../../../usage/usage_stats.dart';
import '../../../voice/live_words.dart';
import '../../../voice/live_words_model.dart';
import '../../../voice/streaming_pcm.dart';
import '../../chat/voice/voice_bridge.dart';

/// The call under way, or null.
final activeCallProvider = NotifierProvider<ActiveCallSlot, ActiveCall?>(ActiveCallSlot.new);

class ActiveCallSlot extends Notifier<ActiveCall?> {
  @override
  ActiveCall? build() => null;

  void set(ActiveCall? call) => state = call;

  /// [call] is over: the slot empties if it still holds it.
  void release(ActiveCall call) {
    if (identical(state, call)) state = null;
  }
}

class ActiveCall extends ChangeNotifier {
  ActiveCall(this._container, {required this.title, required this.conversation}) {
    final c = _container;
    final callSettings = c.read(callSettingsProvider.notifier);
    final voices = c.read(speechVoiceSettingsProvider.notifier);
    _voice = c.read(speechVoiceSettingsProvider) ?? voices.defaults;
    final speaker = c.read(speechSpeakerProvider);
    final audio = c.read(speechAudioProvider);
    final deepseek = c.read(deepSeekSpeechProvider);
    final bridge = c.read(voiceBridgeProvider);
    controller = VoiceCallController(
      audio: audio,
      conversation: conversation,
      recognizer: () async {
        // The phone's own voice warms up while the call starts, not when changed mid-reply.
        await _settleVoice(warm: controller.phase == CallPhase.starting);
        if (_disposed) return null;
        return c.read(callRecognizerProvider)();
      },
      voice: () => speechOutFor(
        _voice,
        deepseek: deepseek,
        audio: audio,
        speaker: speaker,
        call: true,
        levels: true,
        gap: c.read(deepSeekSpeechGapProvider),
      ),
      // The saved ones, not the defaults shown while they load (a first call after launch).
      choices: () async {
        final saved = await callSettings.ready();
        return (
          bargeIn: saved.bargeIn,
          speaker: saved.speaker,
          spokenHint: saved.spoken ? appNote(appL10n.speechCallHint) : null,
          pause: saved.pause,
        );
      },
      permission: () async => await bridge.requestPermission() == VoicePermission.granted,
      cutNote: (heard) => appNote(heard.isEmpty ? appL10n.speechCallCutEarly : appL10n.speechCallCutNote(heard)),
      thinkingCue: () async {
        // Asked again after the settings: her voice may have begun meanwhile.
        if ((await callSettings.ready()).cue && controller.cueStill) await playThinkingCue(audio);
      },
    )..addListener(_changed);
    final visionSettings = c.read(visionSettingsProvider.notifier);
    vision = CallVision(
      settings: visionSettings.ready,
      apiKey: visionSettings.apiKey,
      context: _context,
      onHit: _hit,
      onNotice: _notice,
    )..addListener(notifyListeners);
    if (conversation case final ChatCallConversation chat) {
      chat
        ..frames = () {
          final span = controller.spokenSpan;
          return vision.framesFor(from: span.from, to: span.to);
        }
        ..onTool = _tool;
    }
    // Changed in 通话设置 (or anywhere) during the call: from the next sentence on.
    _subs.addAll([
      c.listen(speechVoiceSettingsProvider, (_, _) => unawaited(_settleVoice())),
      c.listen(voiceSettingsProvider, (_, _) => unawaited(controller.refreshRecognizer())),
      c.listen(cloudAsrProvider, (_, _) => unawaited(controller.refreshRecognizer())),
      c.listen<CallPause>(callSettingsProvider.select((s) => s.pause), (_, pause) => controller.setPause(pause)),
    ]);
  }

  final ProviderContainer _container;
  final String title;
  final CallConversation conversation;
  late final VoiceCallController controller;
  late final CallVision vision;
  final _subs = <ProviderSubscription<Object?>>[];

  LiveWords? _live;
  late CompanionVoiceSettings _voice;
  int _settling = 0;
  bool _disposed = false;
  bool _started = false;
  void Function(UsageOutcome, {UsageOperation? actual})? _callConnect;
  void Function(UsageOutcome, {UsageOperation? actual})? _callSession;

  /// Since the microphone first listened.
  DateTime? get since => _since;
  DateTime? _since;

  /// Pages showing the call now.
  int _views = 0;
  bool get onScreen => _views > 0;

  /// The latest thing to tell the person on the page (sharing stopped, …), with its serial.
  (int, String)? get notice => _noticeShown;
  (int, String)? _noticeShown;
  int _notices = 0;

  bool get ended => controller.phase == CallPhase.ended;

  String? get sessionId => switch (conversation) {
    final ChatCallConversation chat => chat.sessionId,
    _ => null,
  };

  /// The call's conversation, for notifications and the return pill.
  ChatTarget? get target => switch (sessionId) {
    final id? => (host: _container.read(activeHostProvider), sessionId: id),
    null => null,
  };

  void attachView() {
    _views++;
    notifyListeners();
  }

  /// The page went away. Over and unseen: the call is let go.
  void detachView() {
    _views = (_views - 1).clamp(0, 1 << 20);
    if (ended && _views == 0) return dispose();
    // After the frame: the page is being torn down right now.
    scheduleMicrotask(notifyListeners);
  }

  Future<void> start() async {
    if (_started) return;
    _started = true;
    final pcm = _container.read(streamingPcmCaptureProvider);
    final asr = _container.read(streamingAsrProvider);
    final found = liveWordsModelIn(_container);
    _callConnect = _container.read(usageStatsProvider.notifier).beginOperation(UsageOperation.callConnect);
    await controller.start();
    try {
      final chosen = await found;
      if (chosen == null || _disposed || ended) return;
      final live = _live = LiveWords(
        pcm,
        asr,
        chosen.model,
        StreamingPcmSource.call,
        controller.live,
        trial: chosen.trial,
        // Captions that stop mid-call leave the call itself going.
        onFailure: (_) => _live = null,
      );
      await live.start();
    } on Object {
      // Without live captions the call goes on as before.
      _live = null;
    }
  }

  /// [_voice] from the settings: DeepSeek's with nobody to pay for it here
  /// becomes the phone's own; the phone's own warms up.
  Future<void> _settleVoice({bool warm = false}) async {
    final mine = ++_settling;
    var next = await _container.read(speechVoiceSettingsProvider.notifier).ready();
    if (_disposed) return;
    if (next.source == CompanionVoiceSource.deepseek) {
      final speech = await _container.read(deepSeekSpeechProvider)();
      if (speech == null) {
        next = next.copyWith(source: CompanionVoiceSource.system);
      } else {
        speech.close();
      }
    }
    // A later choice has the last word, whichever answer comes back first.
    if (_disposed || mine != _settling) return;
    if (next.source != CompanionVoiceSource.deepseek) {
      final speaker = _container.read(speechSpeakerProvider);
      unawaited(warm ? speaker.ready(next) : speaker.warmPhone());
    }
    _voice = next;
  }

  CallPhase _phase = CallPhase.starting;

  void _changed() {
    if (_disposed) return;
    final phase = controller.phase;
    // Listening only proves the microphone opened. A received assistant
    // reply proves the call's conversation path actually worked.
    if (_callConnect != null && phase == CallPhase.speaking) {
      _callConnect?.call(UsageOutcome.ready);
      _callConnect = null;
      _callSession = _container.read(usageStatsProvider.notifier).beginOperation(UsageOperation.callSession);
    }
    if (phase == CallPhase.listening && _since == null) {
      _since = DateTime.now();
      // Anonymous usage statistics: a call got through (the microphone is on).
      _container.read(usageStatsProvider.notifier).count(UsageCount.call);
    }
    if (phase == CallPhase.ended && _phase != CallPhase.ended) _over();
    _phase = phase;
    notifyListeners();
  }

  void _over() {
    final why = controller.ended;
    _callConnect?.call(switch (why) {
      CallEnd.permission || CallEnd.microphone || CallEnd.noRecognizer || CallEnd.failed => UsageOutcome.failed,
      _ => UsageOutcome.unknown,
    });
    _callConnect = null;
    _callSession?.call(why == CallEnd.failed ? UsageOutcome.failed : UsageOutcome.ready);
    _callSession = null;
    unawaited(_live?.stop());
    _live = null;
    unawaited(vision.stop());
    // Off the call: its conversation is no longer the one being heard (ChatCallConversation set it).
    _container.read(callChatProvider.notifier).set(null);
    _container.read(activeCallProvider.notifier).release(this);
    // Nobody looking: nothing waits for the page to close.
    if (_views == 0) scheduleMicrotask(dispose);
  }

  void hangUp() {
    if (conversation case final ChatCallConversation chat) unawaited(chat.sendPendingNotes());
    controller.hangUp();
  }

  // ── 通话里的画面 ─────────────────────────────────────────────────────────

  List<String> _context() => [
    for (final turn in controller.turns.reversed.take(4).toList().reversed) ...[
      if (turn.you.isNotEmpty) '用户：${turn.you}',
      if (turn.her.isNotEmpty) '助手：${turn.her}',
    ],
  ];

  void _tool(ToolChatItem call) {
    switch (callVisionTool(call.name)) {
      case 'stop_watching_screen':
        vision.clearWatch();
      case 'watch_screen':
        if (call.failure != null) return;
        Object? args;
        try {
          args = jsonDecode(call.arguments);
        } on FormatException {
          return;
        }
        if (args is! Map) return;
        final condition = args['condition'];
        if (condition is! String || condition.trim().isEmpty) return;
        final remind = args['remind'];
        final minutes = args['minutes'];
        unawaited(vision.setWatch(
          condition.trim(),
          remind: remind is String ? remind : null,
          minutes: minutes is num ? minutes.toDouble() : null,
          callId: call.callId,
        ));
    }
  }

  void _hit(CallVisionHit hit) {
    if (_disposed || ended || hit.say.isEmpty) return;
    controller.announce(hit.say);
    if (conversation case final ChatCallConversation chat) {
      chat.noteVision(hit.say, condition: hit.watch?.condition, frame: hit.frame);
    }
    _notifyAway(hit.say);
  }

  void _notice(String text) {
    if (_disposed || ended) return;
    _noticeShown = (++_notices, text);
    controller.announce(text);
    _notifyAway(text);
    notifyListeners();
  }

  /// The app is in the background: what she said shows as a notification too,
  /// and a tap on it comes back to the call.
  void _notifyAway(String text) {
    if (_container.read(appForegroundProvider)) return;
    final to = target;
    if (to == null) return;
    unawaited(_container.read(notifyChannelProvider).tryShow(
      NotifyPost(
        group: notifyGroup(to.host, to.sessionId),
        key: 'call-vision-${DateTime.now().millisecondsSinceEpoch}',
        attention: true,
        title: title,
        text: text,
        publicText: appL10n.speechCallSection,
        sessionId: to.sessionId,
        host: to.host,
        kind: 'call-vision',
      ),
    ));
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    // Hung up first if it still runs (a page that owned it went away).
    if (!ended) controller.hangUp();
    _disposed = true;
    for (final sub in _subs) {
      sub.close();
    }
    unawaited(_live?.stop());
    _callConnect?.call(UsageOutcome.unknown);
    _callSession?.call(UsageOutcome.unknown);
    vision
      ..removeListener(notifyListeners)
      ..dispose();
    controller
      ..removeListener(_changed)
      ..dispose();
    _container.read(activeCallProvider.notifier).release(this);
    super.dispose();
  }
}
