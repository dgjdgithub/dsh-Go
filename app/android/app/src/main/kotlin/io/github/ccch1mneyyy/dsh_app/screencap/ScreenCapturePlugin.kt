package io.github.ccch1mneyyy.dsh_app.screencap

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.util.DisplayMetrics
import android.view.WindowManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/**
 * 屏幕共享: MediaProjection capture for a voice call (and the standalone 屏幕共享 page).
 *
 * Doubao streams ~6 fps video to a cloud VLM that decides on its own when to speak. Here the
 * model is asked per request, so frames are thinned at the source instead:
 *  - a tick every [intervalMs] takes the newest image (a VirtualDisplay produces none while the
 *    screen is still, so "no image" already means "unchanged");
 *  - [FrameGate] compares a 64×36 luma grid with the last frame sent and only lets a visibly
 *    changed frame through, plus a heartbeat so the Dart side always has a recent one;
 *  - a frame goes to Dart as `{ts, jpeg, change, width, height, source}` (raw bytes, no base64).
 *
 * The projection token is single-use (Android 14+): one consent per sharing session, released on
 * [stopSharing]. Rotation is followed by resizing the VirtualDisplay to the new real size.
 */
class ScreenCapturePlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler, PluginRegistry.ActivityResultListener {

    private var methods: MethodChannel? = null
    private var events: EventChannel? = null
    private var sink: EventChannel.EventSink? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var appContext: Context? = null
    private var pendingPermission: MethodChannel.Result? = null
    private val main = Handler(Looper.getMainLooper())

    private var projection: MediaProjection? = null
    private var handlerThread: HandlerThread? = null
    private var handler: Handler? = null
    private var imageReader: ImageReader? = null
    private var virtualDisplay: VirtualDisplay? = null
    private var width = 0
    private var height = 0

    @Volatile private var sharing = false
    private var intervalMs = 1000L
    private var maxDim = MAX_FRAME_DIM
    private val gate = FrameGate()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        methods = MethodChannel(binding.binaryMessenger, "dsh/screencap").also { it.setMethodCallHandler(this) }
        events = EventChannel(binding.binaryMessenger, "dsh/screencap/frames").also { it.setStreamHandler(this) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methods?.setMethodCallHandler(null); methods = null
        events?.setStreamHandler(null); events = null
        stopSharing()
        appContext = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivity() {
        activityBinding?.removeActivityResultListener(this)
        activityBinding = null
    }

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) { sink = events }
    override fun onCancel(arguments: Any?) { sink = null }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isSharing" -> result.success(sharing)
            "startSharing" -> {
                intervalMs = ((call.argument<Int>("intervalMs") ?: 1000).toLong()).coerceIn(250L, 10000L)
                maxDim = (call.argument<Int>("maxDim") ?: MAX_FRAME_DIM).coerceIn(480, 2048)
                startSharing(result)
            }
            "stopSharing" -> { stopSharing(); result.success(null) }
            else -> result.notImplemented()
        }
    }

    // ---- Consent ----

    private fun startSharing(result: MethodChannel.Result) {
        if (sharing) { result.success(true); return }
        val activity = activityBinding?.activity
        if (activity == null) { result.error("no_activity", "屏幕共享需要在应用界面内发起", null); return }
        if (pendingPermission != null) { result.error("busy", "正在等待屏幕共享授权", null); return }
        val mgr = activity.getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        pendingPermission = result
        activity.startActivityForResult(mgr.createScreenCaptureIntent(), REQ_PROJECTION)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQ_PROJECTION) return false
        val pending = pendingPermission ?: return true
        pendingPermission = null
        val context = appContext
        if (resultCode != Activity.RESULT_OK || data == null || context == null) {
            pending.success(false)
            return true
        }
        // The mediaProjection foreground service comes first: from targetSdk 34 on,
        // getMediaProjection() throws without it, and it keeps capture alive in the background.
        runCatching { ScreenShareService.start(context) }
        val mgr = context.getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        val p = runCatching { mgr.getMediaProjection(resultCode, data) }.getOrNull()
        if (p == null) {
            ScreenShareService.stop(context)
            pending.error("projection_failed", "无法开始屏幕共享", null)
            return true
        }
        p.registerCallback(object : MediaProjection.Callback() {
            override fun onStop() {
                if (!sharing) return
                stopSharing()
                // Lock screen, the system's "stop sharing" chip, another app taking over.
                sink?.error("projection_stopped", "屏幕共享已被系统停止", null)
            }
        }, main)
        projection = p
        if (!beginCapture(context, p)) {
            stopSharing()
            pending.error("display_failed", "无法创建屏幕采集", null)
            return true
        }
        pending.success(true)
        return true
    }

    // ---- Capture ----

    private fun realSize(context: Context): Triple<Int, Int, Int> {
        val wm = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
        val metrics = DisplayMetrics()
        @Suppress("DEPRECATION")
        wm.defaultDisplay.getRealMetrics(metrics)
        return Triple(metrics.widthPixels, metrics.heightPixels, metrics.densityDpi)
    }

    private fun beginCapture(context: Context, p: MediaProjection): Boolean {
        val (w, h, dpi) = realSize(context)
        val t = HandlerThread("dsh-screencap").also { it.start() }
        handlerThread = t
        val threadHandler = Handler(t.looper)
        handler = threadHandler
        val reader = ImageReader.newInstance(w, h, PixelFormat.RGBA_8888, 2)
        imageReader = reader
        width = w; height = h
        virtualDisplay = runCatching {
            p.createVirtualDisplay(
                "dsh-screencap", w, h, dpi,
                DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
                reader.surface, null, threadHandler,
            )
        }.getOrNull() ?: return false
        sharing = true
        gate.reset()
        threadHandler.post(tick)
        return true
    }

    /** The screen turned: the display follows the new real size with a fresh reader. */
    private fun followRotation() {
        val context = appContext ?: return
        val (w, h, dpi) = realSize(context)
        if (w == width && h == height) return
        val display = virtualDisplay ?: return
        val reader = ImageReader.newInstance(w, h, PixelFormat.RGBA_8888, 2)
        display.resize(w, h, dpi)
        display.surface = reader.surface
        imageReader?.close()
        imageReader = reader
        width = w; height = h
        gate.reset()
    }

    private val tick = object : Runnable {
        override fun run() {
            if (!sharing) return
            runCatching { followRotation() }
            val reader = imageReader
            val img = if (reader == null) null else runCatching { reader.acquireLatestImage() }.getOrNull()
            if (img != null) {
                var bmp: Bitmap? = null
                try {
                    val full = FrameBitmaps.fromImage(img, reader!!.width, reader.height)
                    bmp = full
                    val now = System.currentTimeMillis()
                    val change = gate.offer(full, now)
                    if (change != null) {
                        val scaled = FrameBitmaps.downscale(full, maxDim)
                        val jpeg = FrameBitmaps.jpeg(scaled, JPEG_QUALITY)
                        val frame = mapOf(
                            "ts" to now, "jpeg" to jpeg, "change" to change,
                            "width" to scaled.width, "height" to scaled.height, "source" to "screen",
                        )
                        if (scaled !== full) scaled.recycle()
                        main.post { if (sharing) sink?.success(frame) }
                    }
                } catch (_: Exception) {
                } finally {
                    bmp?.recycle()
                    img.close()
                }
            } else {
                gate.idle(System.currentTimeMillis())?.let { beat -> main.post { if (sharing) sink?.success(beat) } }
            }
            handler?.postDelayed(this, intervalMs)
        }
    }

    private fun stopSharing() {
        val wasSharing = sharing || projection != null
        sharing = false
        handler?.removeCallbacksAndMessages(null)
        runCatching { virtualDisplay?.release() }; virtualDisplay = null
        runCatching { imageReader?.close() }; imageReader = null
        val p = projection; projection = null
        runCatching { p?.stop() }
        val t = handlerThread; handlerThread = null; handler = null
        runCatching { t?.quitSafely() }
        if (wasSharing) appContext?.let { ScreenShareService.stop(it) }
    }

    companion object {
        private const val REQ_PROJECTION = 0x5c01
        private const val MAX_FRAME_DIM = 1024
        private const val JPEG_QUALITY = 60
    }
}

/**
 * Lets a frame through when it visibly differs from the last one sent (mean luma difference on a
 * 64×36 grid), or as a heartbeat. Returns the change (0..1) for a frame to send, else null.
 * The same measure as the companion's screen trigger (phone/a11y/CompanionScreenChange.kt).
 */
internal class FrameGate(
    private val threshold: Double = 0.03,
    private val heartbeatMs: Long = 8000,
) {
    private var previous: ByteArray? = null
    private var sentAt = Long.MIN_VALUE

    fun reset() { previous = null; sentAt = Long.MIN_VALUE }

    fun offer(bitmap: Bitmap, now: Long): Double? {
        val grid = FrameBitmaps.grid(bitmap)
        val old = previous
        val change = if (old == null) 1.0 else FrameBitmaps.difference(old, grid)
        val beat = sentAt == Long.MIN_VALUE || now - sentAt >= heartbeatMs
        if (change < threshold && !beat) return null
        previous = grid
        sentAt = now
        return change
    }

    /** No new image (a still screen): a heartbeat marker only; Dart keeps its last frame. */
    fun idle(now: Long): Map<String, Any>? {
        if (sentAt == Long.MIN_VALUE || now - sentAt < heartbeatMs) return null
        sentAt = now
        return mapOf("ts" to now, "still" to true, "source" to "screen")
    }
}
