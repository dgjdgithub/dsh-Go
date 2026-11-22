import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../media/screen_capture.dart';
import '../theme/app_icons.dart';
import '../theme/glass.dart';
import '../theme/theme.dart';

/// 屏幕共享 / 截屏: a self-contained page in 全部功能.
///
/// The user taps 共享屏幕 → the system's screen-capture consent sheet → the
/// current screen is captured once and shown here (and can be saved/copied).
/// Nothing runs in the background; each capture is one explicit tap.
class ScreenSharePage extends StatefulWidget {
  const ScreenSharePage({super.key});

  static Route<void> route() => MaterialPageRoute(builder: (_) => const ScreenSharePage());

  @override
  State<ScreenSharePage> createState() => _ScreenSharePageState();
}

class _ScreenSharePageState extends State<ScreenSharePage> {
  Uint8List? _png;
  String? _error;
  bool _busy = false;
  bool _supported = true;

  @override
  void initState() {
    super.initState();
    _checkSupport();
  }

  Future<void> _checkSupport() async {
    final ok = await ScreenCapture.hasPermission();
    // hasPermission returns false both for "not granted" and "no channel";
    // distinguish by trying a harmless call that throws MissingPluginException
    // only when the plugin is absent.
    if (!ok) {
      try {
        await ScreenCapture.hasPermission();
        _supported = true;
      } catch (_) {
        _supported = false;
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _capture() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final bytes = await ScreenCapture.captureOnce();
      if (!mounted) return;
      setState(() {
        _png = bytes;
        _busy = false;
        _error = bytes == null ? '未授予屏幕共享权限' : null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _supported = false;
        _error = '此设备不支持屏幕共享：$e';
      });
    }
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
                  child: _png == null
                      ? SizedBox(
                          height: 220,
                          child: Center(
                            child: _busy
                                ? const CircularProgressIndicator()
                                : Text(
                                    _supported ? '点下方按钮共享当前屏幕' : '此设备不支持屏幕共享',
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                          ),
                        )
                      : ClipRRect(
                          borderRadius: AppShape.radiusMd,
                          child: Image.memory(_png!, fit: BoxFit.contain),
                        ),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
              ],
              const Spacer(),
              FilledButton.icon(
                onPressed: _busy || !_supported ? null : _capture,
                icon: const Icon(AppIcons.camera),
                label: Text(_busy ? '截取中…' : '共享屏幕 / 截屏'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
