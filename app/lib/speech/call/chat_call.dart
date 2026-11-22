// A call with a conversation of the main chat: what the person says is sent
// as a message, as if typed (an open question takes it as its answer, like the
// composer does); the reply is every assistant step of the turn that follows,
// read in order (「我查一下」 before a tool call is said too).

import 'dart:async';
import 'dart:typed_data';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/attachments.dart';
import '../../state/chat_state.dart';
import '../../state/hosts_state.dart';
import '../../state/notify_state.dart';
import 'voice_call.dart';

class ChatCallConversation implements CallConversation {
  /// [session] gives the conversation's id, creating it for a new chat.
  ChatCallConversation(this._container, this._session);

  final ProviderContainer _container;
  final Future<String?> Function() _session;
  final _replies = StreamController<CallReply>.broadcast();
  ProviderSubscription<ChatState>? _sub;
  String? _id;
  bool _disposed = false;

  /// 屏幕共享: the most recent captured frames (oldest first). Frames are pushed
  /// about once a second while sharing is on; they are never sent on their own.
  /// When the person says something that refers to the screen, the newest frame
  /// (and, for a change/error question, the one before it) rides along with that
  /// message, so the AI sees the screen as of the question.
  final List<Uint8List> _screenFrames = [];

  /// Feed one captured frame; keeps the last few for a before/after comparison.
  void pushScreenFrame(Uint8List frame) {
    _screenFrames.add(frame);
    if (_screenFrames.length > 4) _screenFrames.removeAt(0);
  }

  /// Drop the buffered frames when sharing stops.
  void clearScreenFrames() => _screenFrames.clear();

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
    final bool ok;
    if (state.singleQuestion case final request? when state.openApproval == null) {
      ok = await chat.answer(request, [QuestionAnswer(request.questions.single.id, custom: text)]);
    } else {
      ok = await chat.send(text, attachments: _screenAttachmentsFor(text));
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

  /// 屏幕共享: pick the frames to ride along with this message. Nothing when the
  /// person is not talking about the screen; the newest frame when they are; the
  /// previous one too when they ask what changed or what went wrong.
  List<DraftAttachment> _screenAttachmentsFor(String text) {
    if (_screenFrames.isEmpty || !_asksAboutScreen(text)) return const [];
    final picked = <Uint8List>[_screenFrames.last];
    if (_asksWhatChanged(text) && _screenFrames.length >= 2) {
      picked.add(_screenFrames[_screenFrames.length - 2]);
    }
    final stamp = DateTime.now().millisecondsSinceEpoch;
    return [
      for (var i = 0; i < picked.length; i++)
        DraftAttachment(name: 'screen-$stamp-$i.png', bytes: picked[i], mediaType: 'image/png'),
    ];
  }

  /// Whether what the person said refers to what is on screen.
  static bool _asksAboutScreen(String text) {
    const words = [
      '屏幕', '画面', '看看', '看一下', '看下', '这个', '这里', '上面', '界面', '页面', '显示', '图',
      '报错', '出错', '错误', '怎么回事', '为什么',
    ];
    return words.any(text.contains);
  }

  /// Whether it asks about a change or a problem — then the previous frame helps.
  static bool _asksWhatChanged(String text) {
    const words = ['刚才', '之前', '怎么', '为什么', '变了', '报错', '出错', '错误', '怎么回事'];
    return words.any(text.contains);
  }

  void _changed(ChatState state) {
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
