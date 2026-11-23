// A call with a conversation of the main chat: what the person says is sent
// as a message, as if typed (an open question takes it as its answer, like the
// composer does); the reply is every assistant step of the turn that follows,
// read in order (「我查一下」 before a tool call is said too).

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

  /// 盯屏: set by a spoken request like「帮我盯着…，没了告诉我」. While on, the
  /// page pushes a frame every few seconds and [watchTick] asks the AI whether
  /// the thing is still there; the answer is silent unless it is gone.
  bool _watching = false;
  String _watchInstruction = '';
  bool _watchBusy = false;

  bool get watching => _watching;

  void stopWatching() {
    _watching = false;
    _watchInstruction = '';
  }

  static bool _isWatchRequest(String text) {
    if (text.contains('盯')) return true;
    const ends = ['通知', '告诉', '提醒', '没了', '不见', '消失'];
    return text.contains('看') && ends.any(text.contains);
  }

  static bool _isStopWatch(String text) {
    const words = ['别盯', '不盯', '停止盯', '停止监控', '不用盯', '别监控', '取消监控'];
    return words.any(text.contains);
  }

  /// One silent watch check. Returns the AI's answer text (e.g. 还在 / 不在了),
  /// or null when it could not check now (a turn is running, or no reply yet).
  Future<String?> watchTick(Uint8List frame) async {
    if (!_watching || _watchBusy || _disposed) return null;
    final id = _id ?? await _session();
    if (id == null || _disposed) return null;
    _follow(id);
    var state = _container.read(chatProvider(id));
    if (state.running) return null;
    _watchBusy = true;
    try {
      final before = {
        for (final item in state.items)
          if (item is AssistantChatItem) item.key,
      };
      final note = appNote(
        '（屏幕监控检查，不要朗读这条，也不要在聊天里显示。）看这张截图。我之前让你盯的是：$_watchInstruction。'
        '如果它已经不在了，只回答“不在了”；否则只回答“还在”。不要解释。',
      );
      final ok = await _container.read(chatProvider(id).notifier).send(
        note,
        attachments: [DraftAttachment.sniff('watch.jpg', frame)],
      );
      if (!ok) return null;
      for (var i = 0; i < 30; i++) {
        await Future.delayed(const Duration(milliseconds: 500));
        if (_disposed) return null;
        final s = _container.read(chatProvider(id));
        final steps = [
          for (final item in s.items)
            if (item is AssistantChatItem && !before.contains(item.key)) item.text.trim(),
        ];
        final text = steps.join('\n').trim();
        if (text.isNotEmpty && !s.running) return text;
      }
      return null;
    } finally {
      _watchBusy = false;
    }
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
    if (_isStopWatch(text)) {
      stopWatching();
    } else if (_isWatchRequest(text)) {
      _watching = true;
      _watchInstruction = text;
    }
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
        // The image was refused (a text-only model, or an invalid frame): the
        // words still go, so the conversation is not blocked by the picture.
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
        DraftAttachment.sniff('screen-$stamp-$i.jpg', picked[i]),
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
