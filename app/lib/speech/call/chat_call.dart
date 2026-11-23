// A call with a conversation of the main chat: what the person says is sent
// as a message, as if typed (an open question takes it as its answer, like the
// composer does); the reply is every assistant step of the turn that follows,
// read in order (「我查一下」 before a tool call is said too).
//
// 屏幕共享 is tool-driven now: the engine exposes look_at_screen, and the model
// decides when to look. This class only keeps the last frame so a hang-up can
// leave the final screen in the conversation.

import 'dart:async';
import 'dart:typed_data';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/app_notes.dart';
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

  /// 屏幕共享: the most recent captured frames (oldest first). While sharing is
  /// on every spoken turn carries the newest one, so the AI always sees the
  /// screen when the person talks; the look_at_screen tool is there for the
  /// model to look on its own too.
  final List<Uint8List> _screenFrames = [];

  void pushScreenFrame(Uint8List frame) {
    _screenFrames.add(frame);
    if (_screenFrames.length > 4) _screenFrames.removeAt(0);
  }

  void clearScreenFrames() => _screenFrames.clear();

  /// 挂断前: send the last captured screen frame once, so the conversation
  /// still has what was on screen when the call ended.
  Future<void> sendLastScreenFrame() async {
    if (_screenFrames.isEmpty || _disposed) return;
    final frame = _screenFrames.last;
    final id = _id ?? await _session();
    if (id == null || _disposed) return;
    _follow(id);
    final state = _container.read(chatProvider(id));
    if (state.running) return;
    final note = appNote('（语音通话结束前，这是我最后的屏幕画面。像正常打电话一样，简短说重点即可。）');
    await _container.read(chatProvider(id).notifier).send(
      note,
      attachments: [DraftAttachment.sniff('screen-last.jpg', frame)],
    );
  }

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
    bool ok;
    if (state.singleQuestion case final request? when state.openApproval == null) {
      ok = await chat.answer(request, [QuestionAnswer(request.questions.single.id, custom: text)]);
    } else {
      final attachments = _screenAttachmentsFor(text);
      final body = attachments.isEmpty
          ? text
          : '${appNote('（这是语音通话：你正在和我打电话，不是文字聊天。附上的图片是我当前屏幕的画面。不要逐条念出或播报图片里的内容；像正常打电话那样，用简短口语只说重要的、需要提醒我的信息，必要时用一两句描述画面即可。不要用 Markdown、列表或表格。）')}\n$text';
      ok = await chat.send(body, attachments: attachments);
      if (!ok && attachments.isNotEmpty) {
        // The image was refused: the words still go.
        ok = await chat.send(text);
      }
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

  /// While sharing is on, every spoken turn carries the latest frame; a
  /// change/error question also carries the one before it for comparison.
  List<DraftAttachment> _screenAttachmentsFor(String text) {
    if (_screenFrames.isEmpty) return const [];
    final picked = <Uint8List>[_screenFrames.last];
    if (_asksWhatChanged(text) && _screenFrames.length >= 2) {
      picked.add(_screenFrames[_screenFrames.length - 2]);
    }
    final stamp = DateTime.now().millisecondsSinceEpoch;
    return [
      for (var i = 0; i < picked.length; i++)
        DraftAttachment.sniff('screen-$stamp-$i.jpg', picked[i]),
    ];
  }

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
