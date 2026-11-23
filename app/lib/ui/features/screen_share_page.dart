import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../media/screen_capture.dart';
import '../theme/app_icons.dart';
import '../theme/glass.dart';
import '../theme/theme.dart';

/// 屏幕共享: continuous. Tap 开始共享 → system consent (whole screen or one
/// window) → the newest screen frame arrives every few seconds and is shown
/// here, refreshing in place. Tap again to stop. Android only; each fresh
/// projection token needs its own consent (the system re-asks after a stop).
class ScreenSharePage extends StatefulWidget {
  const ScreenSharePage({super.key});

  static Route<void> route() => MaterialPageRoute(builder: (_) => const ScreenSharePage());

  @override
  State<ScreenSharePage> createState() => _ScreenSharePageState();
}

class _ScreenSharePageState extends State<ScreenSharePage> {
  static const _intervalMs = 3000;

  StreamSubscription<Uint8List>? _sub;
  Uint8List? _frame;
  String? _error;
  bool _busy = false;
  bool _sharing = false;

  @override
  void dispose() {
    _stopSub();
    // Release the projection when leaving the page.
    unawaited(ScreenCapture.stopSharing());
    super.dispose();
  }

  void _stopSub() {
    _sub?.cancel();
    _sub = null;
  }

  Future<void> _start() async {
    setState(() { _busy = true; _error = null; });
    try {
      final started = await ScreenCapture.startSharing(intervalMs: _intervalMs);
      if (!mounted) return;
      if (!started) {
        setState(() { _busy = false; _error = '未授予屏幕共享权限'; });
        return;
      }
      _stopSub();
      _sub = ScreenCapture.frames().listen(
        (bytes) { if (mounted) setState(() { _frame = bytes; _busy = false; }); },
        onError: (e) { if (mounted) setState(() { _error = '读取画面失败：$e'; _busy = false; _sharing = false; }); },
      );
      setState(() { _sharing = true; _busy = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _busy = false; _sharing = false; _error = '此设备不支持屏幕共享：$e'; });
    }
  }

  Future<void> _stop() async {
    _stopSub();
    await ScreenCapture.stopSharing();
    if (mounted) setState(() { _sharing = false; _frame = null; });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('屏幕共享')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              GlassSurface(
                tier: GlassTier.card,
                borderRadius: AppShape.radiusLg,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: _frame == null
                      ? SizedBox(
                          height: 220,
                          child: Center(
                            child: _busy
                                ? const CircularProgressIndicator()
                                : Text(
                                    _sharing ? '等待第一帧画面…' : '点下方按钮开始共享屏幕（每 3 秒刷新）',
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                          ),
                        )
                      : ClipRRect(
                          borderRadius: AppShape.radiusMd,
                          child: Image.memory(_frame!, fit: BoxFit.contain, gaplessPlayback: true),
                        ),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
              ],
              const Spacer(),
              FilledButton.icon(
                onPressed: _busy ? null : (_sharing ? _stop : _start),
                icon: Icon(_sharing ? AppIcons.stopSharing : AppIcons.camera),
                label: Text(_busy ? '启动中…' : (_sharing ? '停止共享' : '开始共享屏幕')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
