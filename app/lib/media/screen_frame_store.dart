import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../share_code/guest_fs.dart';

/// 通话里的画面, for the engine's look_at_screen / watch_screen tools
/// (runtime/bridge/dsh-go-bridge/lib/screen-tool.js): the newest kept frame
/// and what is shared, under DSH home in the engine's own filesystem (no
/// shared-storage permission needed). A remote host has none of this: its
/// tools say nothing is shared.
class ScreenFrameStore {
  ScreenFrameStore._();

  static const _dir = '${GuestFs.dshHome}/dsh-go/vision';

  static Future<Directory?>? _root;

  static Future<Directory?> _folder() => _root ??= () async {
    final fs = await GuestFs.local();
    if (fs == null) return null;
    final dir = fs.dir(_dir);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }();

  static Future<void> write(Uint8List jpeg) async {
    try {
      final dir = await _folder();
      if (dir == null) return;
      final tmp = File('${dir.path}/latest.tmp');
      await tmp.writeAsBytes(jpeg, flush: true);
      await tmp.rename('${dir.path}/latest.jpg');
    } catch (_) {
      // The tool reports no frame when writing fails.
    }
  }

  /// [source] null: nothing shared. [judge]: a vision model is set up for watching.
  static Future<void> status({required String? source, required bool judge}) async {
    try {
      final dir = await _folder();
      if (dir == null) return;
      final tmp = File('${dir.path}/status.tmp');
      await tmp.writeAsString(jsonEncode({
        'sharing': source != null,
        'source': source,
        'judge': judge,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      }), flush: true);
      await tmp.rename('${dir.path}/status.json');
      if (source == null) {
        final latest = File('${dir.path}/latest.jpg');
        if (latest.existsSync()) await latest.delete();
      }
    } catch (_) {}
  }
}
