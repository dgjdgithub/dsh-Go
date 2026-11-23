import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

/// 屏幕帧落盘：引擎里的 look_at_screen 工具读这个文件。
///
/// Writes the newest JPEG into the app's external files directory
/// (`.../files/screen/latest.jpg`), which needs no "all files" permission and
/// is visible inside the Linux guest as
/// `/sdcard/Android/data/<package>/files/screen/latest.jpg`.
class ScreenFrameStore {
  ScreenFrameStore._();

  static Directory? _dir;

  static Future<void> write(Uint8List bytes) async {
    try {
      final dir = _dir ??= await () async {
        final root = await getExternalStorageDirectory();
        if (root == null) return null;
        final d = Directory('${root.path}/screen');
        if (!await d.exists()) await d.create(recursive: true);
        return d;
      }();
      if (dir == null) return;
      final tmp = File('${dir.path}/latest.tmp');
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename('${dir.path}/latest.jpg');
    } catch (_) {
      // The tool simply reports no frame when writing fails.
    }
  }
}
