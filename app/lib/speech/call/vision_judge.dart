// 盯屏的判断: one request to the 看图模型 (vision_settings.dart) with what is
// being watched for, the call's last few turns (so 「那个」 in the condition
// still means what it meant), and the newest frames. It answers in JSON:
// whether the condition is met, and one short spoken line if it is.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../media/screen_capture.dart';

class VisionVerdict {
  const VisionVerdict({required this.met, this.say = ''});

  final bool met;

  /// What she says in the call (short, spoken).
  final String say;
}

class VisionJudge {
  VisionJudge({http.Client Function()? client}) : _client = client ?? http.Client.new;

  final http.Client Function() _client;

  static Uri endpoint(String baseUrl) {
    var base = baseUrl.trim();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    if (base.endsWith('/chat/completions')) return Uri.parse(base);
    return Uri.parse('$base/chat/completions');
  }

  /// [condition] null: 陪看 — is there anything worth mentioning unasked?
  Future<VisionVerdict> ask({
    required String baseUrl,
    required String model,
    required String? apiKey,
    required String? condition,
    required String? remind,
    required List<String> context,
    required List<VisionFrame> frames,
    Duration timeout = const Duration(seconds: 25),
  }) async {
    // l10n:keep-begin model-facing prompt
    final source = frames.isNotEmpty && frames.last.source == VisionSource.camera ? '摄像头' : '手机屏幕';
    final task = condition == null
        ? '用户正在和助手语音通话，同时共享了$source。判断画面里是否刚出现了值得主动告诉用户的变化'
              '（例如报错、弹窗、任务完成、明显的危险或用户可能错过的重要信息）。普通的滚动、输入、切换页面不算。'
        : '用户正在和助手语音通话，同时共享了$source，并请助手盯着：「$condition」。判断最新画面里这个情况是否已经出现。'
              '${remind == null || remind.isEmpty ? '' : '满足时想提醒的要点：$remind。'}';
    final prompt = StringBuffer()
      ..writeln(task)
      ..writeln('图片按时间先后排列，最后一张是最新的。');
    if (context.isNotEmpty) {
      prompt
        ..writeln('最近的通话内容（供理解条件，不要复述）：')
        ..writeln(context.join('\n'));
    }
    prompt.writeln(
      '只输出一个 JSON 对象，不要其他文字：{"met": true 或 false, "say": "满足时在通话里对用户说的一句简短口语提醒，'
      '不超过 30 个字，不用 Markdown；不满足时为空字符串"}',
    );
    // l10n:keep-end
    final body = {
      'model': model.trim(),
      'stream': false,
      'temperature': 0,
      'max_tokens': 200,
      'messages': [
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': prompt.toString()},
            for (final frame in frames)
              if (frame.jpeg case final jpeg?)
                {
                  'type': 'image_url',
                  'image_url': {'url': 'data:image/jpeg;base64,${base64Encode(jpeg)}'},
                },
          ],
        },
      ],
    };
    final client = _client();
    try {
      final response = await client
          .post(
            endpoint(baseUrl),
            headers: {
              'content-type': 'application/json',
              if (apiKey != null && apiKey.trim().isNotEmpty) 'authorization': 'Bearer ${apiKey.trim()}',
            },
            body: jsonEncode(body),
          )
          .timeout(timeout);
      if (response.statusCode != 200) throw VisionJudgeFailed(response.statusCode);
      final json = jsonDecode(utf8.decode(response.bodyBytes));
      final choices = json is Map ? json['choices'] : null;
      final first = choices is List && choices.isNotEmpty ? choices.first : null;
      final message = first is Map ? first['message'] : null;
      final content = message is Map ? message['content'] : null;
      return parse(content is String ? content : '');
    } finally {
      client.close();
    }
  }

  /// The model's answer: the JSON object in it, wherever it is.
  static VisionVerdict parse(String text) {
    final start = text.indexOf('{');
    final end = text.lastIndexOf('}');
    if (start < 0 || end <= start) return const VisionVerdict(met: false);
    try {
      final json = jsonDecode(text.substring(start, end + 1));
      if (json is! Map) return const VisionVerdict(met: false);
      final met = json['met'] == true;
      final say = json['say'] is String ? (json['say'] as String).trim() : '';
      return VisionVerdict(met: met, say: say);
    } on FormatException {
      return const VisionVerdict(met: false);
    }
  }
}

/// The 看图模型 answered with an HTTP error.
class VisionJudgeFailed implements Exception {
  const VisionJudgeFailed(this.status);

  final int status;

  @override
  String toString() => 'VisionJudgeFailed($status)';
}
