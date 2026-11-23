// A call with a conversation of the main chat: what the person says is sent
// as a message, as if typed (an open question takes it as its answer, like the
// composer does); the reply is every assistant step of the turn that follows,
// read in order (「我查一下」 before a tool call is said too).
//
// 通话里的画面 (call_vision.dart): while the screen or camera is shared, each
// message carries the frames from while the person spoke ([frames]); a 盯屏
// reminder she already said goes in with the next message as a hidden note, so
// the conversation knows about it. The model's watch_screen /
// stop_watching_screen calls are seen here and handed to [onTool].

import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../media/screen_capture.dart';
import '../../state/app_notes.dart';
import '../../state/attachments.dart';
import '../../state/chat_state.dart';
import '../../state/hosts_state.dart';
import '../../state/notify_state.dart';
import 'voice_call.dart';

/// The engine's tools for the call's picture (runtime/bridge/dsh-go-bridge/lib/screen-tool.js).
const callVisionTools = {'watch_screen', 'stop_watching_screen'};

/// [name] as one of [callVisionTools] (a namespaced name too), else null.
String? callVisionTool(String name) {
  for (final tool in callVisionTools) {
    if (name == tool || name.endsWith('.$tool') || name.endsWith(':$tool') || name.endsWith('__$tool')) return tool;
  }
  return null;
}

class ChatCallConversation implements CallConversation {
  /// [session] gives the conversation's id, creating it for a new chat.
  ChatCallConversation(this._container, this._session);

  final ProviderContainer _container;
  final Future<String?> Function() _session;
  final _replies = StreamController<CallReply>.broadcast();
  ProviderSubscription<ChatState>? _sub;
  String? _id;
  bool _disposed = false;

  /// The frames for the message being sent (none while nothing is shared).
  List<VisionFrame> Function()? frames;

  /// A watch_screen / stop_watching_screen call the model made in this call.
  void Function(ToolChatItem call)? onTool;

  /// Tool calls already handed to [onTool] (or there before the call).
  final Set<String> _toolsSeen = {};

  /// Hidden notes for the next message (a 盯屏 reminder she already said).
  final List<({String note, VisionFrame? frame})> _notes = [];

  /// 盯屏 said [said] in the call: the conversation hears of it with the next message.
  // l10n:keep-begin model-facing hidden notes
  void noteVision(String said, {String? condition, VisionFrame? frame}) {
    final what = condition == null ? '我在画面里看到值得提醒的变化' : '你让我盯的「$condition」出现了';
    _notes.add((note: appNote('盯屏提醒：$what，已经在通话里对用户说了：「$said」。附图是当时的画面。'), frame: frame));
    if (_notes.length > 3) _notes.removeAt(0);
  }

  /// 挂断前: a reminder not yet passed on, with its picture, so the
  /// conversation still knows what was seen.
  Future<void> sendPendingNotes() async {
    if (_notes.isEmpty || _disposed) return;
    final id = _id ?? await _session();
    if (id == null || _disposed) return;
    final state = _container.read(chatProvider(id));
    if (state.running) return;
    final notes = List.of(_notes);
    _notes.clear();
    await _container.read(chatProvider(id).notifier).send(
      [...notes.map((n) => n.note), appNote('（语音通话已经结束，简短确认即可。）')].join('\n'),
      attachments: [
        for (final (i, n) in notes.indexed)
          if (n.frame?.jpeg case final jpeg?) DraftAttachment.sniff('vision-note-$i.jpg', jpeg),
      ],
    );
  }

  // l10n:keep-end

  /// The assistant steps already there before the last send.
  Set<String> _before = const {};
  bool _tracking = false;
  bool _sawRunning = false;
  String _last = '';
  Timer? _idle;

  @override
  Stream<CallReply> get replies => _replies.stream;

  @override
  bool get waiting {
    final id = _id;
    if (id == null) return false;
    final s = _container.read(chatProvider(id));
    return s.openApproval != null || s.questions.isNotEmpty;
  }

  /// The conversation the call is in, once it has one.
  String? get sessionId => _id;

  void _follow(String id) {
    if (_id == id && _sub != null) return;
    _sub?.close();
    _id = id;
    _toolsSeen
      ..clear()
      ..addAll([
        for (final item in _container.read(chatProvider(id)).items)
          if (item is ToolChatItem) item.callId,
      ]);
    _sub = _container.listen<ChatState>(chatProvider(id), (_, next) => _changed(next));
    // Its replies are heard here: no banner for them while the call is up.
    _container.read(callChatProvider.notifier).set((host: _container.read(activeHostProvider), sessionId: id));
  }

  @override
  Future<bool> send(String text) async {
    final id = await _session();
    // The call ended while its conversation was made: nothing to follow.
    if (id == null || _disposed) return false;
    _follow(id);
    final chat = _container.read(chatProvider(id).notifier);
    var state = _container.read(chatProvider(id));
    if (!state.controlReady && !await chat.waitForSync()) return false;
    // Hung up while the conversation caught up: it is not sent.
    if (_disposed) return false;
    state = _container.read(chatProvider(id));
    _before = {
      for (final item in state.items)
        if (item is AssistantChatItem) item.key,
    };
    _tracking = true;
    _sawRunning = state.running;
    _last = '';
    bool ok;
    if (state.singleQuestion case final request? when state.openApproval == null) {
      ok = await chat.answer(request, [QuestionAnswer(request.questions.single.id, custom: text)]);
    } else {
      // l10n:keep-begin model-facing hidden note
      final shown = frames?.call() ?? const <VisionFrame>[];
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final notes = List.of(_notes);
      final attachments = [
        for (final (i, n) in notes.indexed)
          if (n.frame?.jpeg case final jpeg?) DraftAttachment.sniff('vision-note-$stamp-$i.jpg', jpeg),
        for (final (i, f) in shown.indexed)
          if (f.jpeg case final jpeg?) DraftAttachment.sniff('${f.source.name}-$stamp-$i.jpg', jpeg),
      ];
      final camera = shown.isNotEmpty && shown.last.source == VisionSource.camera;
      final lead = [
        ...notes.map((n) => n.note),
        if (shown.isNotEmpty)
          appNote('（语音通话中，我在共享${camera ? '摄像头' : '屏幕'}。最后${shown.length > 1 ? '几张' : '一张'}图是我说这句话时的画面'
              '${shown.length > 1 ? '，按时间先后排列' : ''}。不要逐条念图里的内容，像打电话一样用简短口语只说要紧的；'
              '要我等某个变化就用 watch_screen。）'),
      ];
      // l10n:keep-end
      final body = lead.isEmpty ? text : '${lead.join('\n')}\n$text';
      ok = await chat.send(body, attachments: attachments);
      if (!ok && attachments.isNotEmpty) {
        // The images were refused (a text-only model): the words still go.
        ok = await chat.send(lead.isEmpty ? text : [...notes.map((n) => n.note), text].join('\n'));
      }
      if (ok) _notes.removeRange(0, notes.length.clamp(0, _notes.length));
    }
    if (!ok) {
      _tracking = false;
      return false;
    }
    if (_disposed) return true;
    // A turn that never starts (sent while another one wraps up): give up waiting after a while.
    _idle?.cancel();
    _idle = Timer(const Duration(seconds: 90), () {
      if (_tracking && !_sawRunning) _done();
    });
    return true;
  }

  void _changed(ChatState state) {
    final tool = onTool;
    if (tool != null) {
      for (final item in state.items) {
        if (item is ToolChatItem &&
            callVisionTool(item.name) != null &&
            item.status != ToolStatus.streaming &&
            _toolsSeen.add(item.callId)) {
          tool(item);
        }
      }
    }
    if (!_tracking) return;
    if (state.running) _sawRunning = true;
    final steps = [
      for (final item in state.items)
        if (item is AssistantChatItem && !_before.contains(item.key) && item.text.trim().isNotEmpty) item.text.trim(),
    ];
    final text = steps.join('\n');
    if (text != _last && text.length >= _last.length) {
      _last = text;
      if (!_replies.isClosed) _replies.add(CallReply(text, done: false));
    }
    if (_sawRunning && !state.running) _done();
  }

  void _done() {
    if (!_tracking) return;
    _tracking = false;
    _idle?.cancel();
    if (!_replies.isClosed) _replies.add(CallReply(_last, done: true));
  }

  @override
  Future<void> interrupt() async {
    final id = _id;
    _tracking = false;
    _idle?.cancel();
    if (id == null) return;
    if (_container.read(chatProvider(id)).running) await _container.read(chatProvider(id).notifier).cancel();
  }

  @override
  void dispose() {
    _disposed = true;
    _idle?.cancel();
    _sub?.close();
    _sub = null;
    unawaited(_replies.close());
  }
}
