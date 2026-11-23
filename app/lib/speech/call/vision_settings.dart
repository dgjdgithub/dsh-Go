// 看图模型: the vision model a call's 盯屏 asks whether a watched thing has
// happened (an OpenAI-compatible chat/completions endpoint that takes images,
// e.g. DeepSeek V4 Flash). Its key stays in secure storage; the rest is in
// SharedPreferences under `speech_vision_v1`.

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../secrets/secure_storage.dart';

class VisionSettings {
  const VisionSettings({
    this.baseUrl = '',
    this.model = '',
    this.hasKey = false,
    this.companion = false,
    this.maxMinutes = 30,
  });

  /// e.g. `https://api.deepseek.com/v1`; `/chat/completions` is added.
  final String baseUrl;
  final String model;

  /// A key is saved (it is never held here).
  final bool hasKey;

  /// 陪看: while sharing, she may speak up on her own about something worth
  /// mentioning, without being asked to watch for it.
  final bool companion;

  /// Sharing (screen or camera) stops by itself after this long.
  final int maxMinutes;

  bool get configured => baseUrl.trim().isNotEmpty && model.trim().isNotEmpty;

  VisionSettings copyWith({String? baseUrl, String? model, bool? hasKey, bool? companion, int? maxMinutes}) =>
      VisionSettings(
        baseUrl: baseUrl ?? this.baseUrl,
        model: model ?? this.model,
        hasKey: hasKey ?? this.hasKey,
        companion: companion ?? this.companion,
        maxMinutes: maxMinutes ?? this.maxMinutes,
      );
}

class VisionSettingsController extends Notifier<VisionSettings> {
  static const _key = 'speech_vision_v1';
  static const _secretKey = 'speech_vision_api_key_v1';
  static const _secure = AppSecureStorage();
  late Future<void> _loaded;

  @override
  VisionSettings build() {
    _loaded = _load();
    return const VisionSettings();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      final json = raw == null ? null : jsonDecode(raw);
      final key = await _secure.read(key: _secretKey).catchError((Object _) => null);
      if (!ref.mounted) return;
      state = VisionSettings(
        baseUrl: json is Map && json['baseUrl'] is String ? json['baseUrl'] as String : '',
        model: json is Map && json['model'] is String ? json['model'] as String : '',
        hasKey: key != null && key.isNotEmpty,
        companion: json is Map && json['companion'] == true,
        maxMinutes: json is Map && json['maxMinutes'] is int ? (json['maxMinutes'] as int).clamp(5, 240) : 30,
      );
    } on Object {
      // Defaults for this run.
    }
  }

  Future<VisionSettings> ready() async {
    await _loaded;
    return state;
  }

  Future<String?> apiKey() async {
    try {
      return await _secure.read(key: _secretKey);
    } on Object {
      return null;
    }
  }

  Future<void> setApiKey(String? key) async {
    await _loaded;
    final value = key?.trim();
    if (value == null || value.isEmpty) {
      await _secure.delete(key: _secretKey);
    } else {
      await _secure.write(key: _secretKey, value: value);
    }
    if (ref.mounted) state = state.copyWith(hasKey: value != null && value.isNotEmpty);
  }

  Future<void> edit(VisionSettings Function(VisionSettings saved) change) async {
    await _loaded;
    if (!ref.mounted) return;
    final next = change(state);
    state = next;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode({
        'baseUrl': next.baseUrl.trim(),
        'model': next.model.trim(),
        'companion': next.companion,
        'maxMinutes': next.maxMinutes,
      }),
    );
  }
}

final visionSettingsProvider = NotifierProvider<VisionSettingsController, VisionSettings>(VisionSettingsController.new);
