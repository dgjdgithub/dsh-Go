// 回到通话: while a call goes on with its page closed (Back, a notification
// opened, another chat), a small pill over everything brings it back: the
// call's clock and, while it watches, a dot.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';
import '../voice_call_page.dart' show showActiveCall;
import 'active_call.dart';

/// Put once in the home shell; draws nothing there (the pill is in the root overlay).
class CallReturnHost extends ConsumerStatefulWidget {
  const CallReturnHost({super.key});

  @override
  ConsumerState<CallReturnHost> createState() => _CallReturnHostState();
}

class _CallReturnHostState extends ConsumerState<CallReturnHost> {
  OverlayEntry? _entry;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _entry != null) return;
      _entry = OverlayEntry(builder: (_) => const _CallPill());
      Overlay.of(context, rootOverlay: true).insert(_entry!);
    });
  }

  @override
  void dispose() {
    _entry?.remove();
    _entry?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

class _CallPill extends ConsumerStatefulWidget {
  const _CallPill();

  @override
  ConsumerState<_CallPill> createState() => _CallPillState();
}

class _CallPillState extends ConsumerState<_CallPill> {
  ActiveCall? _call;
  Timer? _clock;

  void _follow(ActiveCall? call) {
    if (identical(call, _call)) return;
    _call?.removeListener(_changed);
    _call = call?..addListener(_changed);
    _clock?.cancel();
    _clock = call == null ? null : Timer.periodic(const Duration(seconds: 1), (_) => _changed());
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _call?.removeListener(_changed);
    _clock?.cancel();
    super.dispose();
  }

  static String _elapsed(DateTime? since) {
    if (since == null) return '';
    final d = DateTime.now().difference(since);
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return d.inHours > 0 ? '${d.inHours}:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final call = ref.watch(activeCallProvider);
    _follow(call);
    final shown = call != null && !call.ended && !call.onScreen;
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final watching = call?.vision.watch != null;
    final sharing = call?.vision.source != null;
    return Positioned(
      top: MediaQuery.viewPaddingOf(context).top + AppSpace.sm,
      right: AppSpace.md,
      child: IgnorePointer(
        ignoring: !shown,
        child: AnimatedOpacity(
          opacity: shown ? 1 : 0,
          duration: AppMotion.of(context, AppMotion.standard),
          child: Material(
            key: const ValueKey('call-return-pill'),
            color: const Color(0xFF16A34A),
            shape: const StadiumBorder(),
            elevation: 4,
            child: InkWell(
              customBorder: const StadiumBorder(),
              onTap: call == null
                  ? null
                  : () {
                      HapticFeedback.selectionClick();
                      unawaited(showActiveCall(context, call));
                    },
              child: Semantics(
                button: true,
                label: l10n.speechCallReturn,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(sharing ? AppIcons.shareImage : AppIcons.voice, size: 16, color: Colors.white),
                      const SizedBox(width: 6),
                      Text(
                        call?.since == null ? l10n.speechCallReturn : _elapsed(call?.since),
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: Colors.white,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                      if (watching) ...[
                        const SizedBox(width: 6),
                        Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(color: scheme.tertiaryContainer, shape: BoxShape.circle),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
