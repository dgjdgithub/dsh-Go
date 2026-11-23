package io.github.ccch1mneyyy.dsh_app.screencap

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.os.Handler
import android.os.Looper
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.util.concurrent.Executors

/**
 * 通话里开摄像头: CameraX analysis frames for a voice call, the camera twin of
 * [ScreenCapturePlugin] (same `{ts, jpeg, change, width, height, source}` frames).
 *
 * Bound to the activity's lifecycle: the camera pauses by itself when the app goes to the
 * background (no camera foreground service) and resumes when it comes back.
 *
 * Two rates: preview frames ([previewMs], small) keep the call page's little window moving;
 * every [sampleMs] one of them is also marked `keep` for the call's frame ring. A hand-held
 * camera never holds still, so no change gate here — the Dart watcher paces model calls.
 */
class CameraCapturePlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler, EventChannel.StreamHandler,
    PluginRegistry.RequestPermissionsResultListener {
    private var methods: MethodChannel? = null
    private var events: EventChannel? = null
    private var sink: EventChannel.EventSink? = null
    private var appContext: Context? = null
    private var activity: ActivityPluginBinding? = null
    private val main = Handler(Looper.getMainLooper())
    private val analyzer = Executors.newSingleThreadExecutor()

    private var provider: ProcessCameraProvider? = null
    private var analysis: ImageAnalysis? = null
    @Volatile private var running = false
    private var front = false
    private var previewMs = 250L
    private var sampleMs = 1000L
    private var lastPreview = 0L
    private var lastKeep = 0L
    private var previous: ByteArray? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        methods = MethodChannel(binding.binaryMessenger, "dsh/camcap").also { it.setMethodCallHandler(this) }
        events = EventChannel(binding.binaryMessenger, "dsh/camcap/frames").also { it.setStreamHandler(this) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        stop()
        methods?.setMethodCallHandler(null); methods = null
        events?.setStreamHandler(null); events = null
        appContext = null
        analyzer.shutdown()
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding
        binding.addRequestPermissionsResultListener(this)
    }
    override fun onDetachedFromActivity() {
        stop()
        activity?.removeRequestPermissionsResultListener(this)
        activity = null
    }
    override fun onDetachedFromActivityForConfigChanges() {
        activity?.removeRequestPermissionsResultListener(this)
        activity = null
    }
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)

    private var pendingPermission: MethodChannel.Result? = null

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray): Boolean {
        if (requestCode != REQ_CAMERA) return false
        val pending = pendingPermission ?: return true
        pendingPermission = null
        pending.success(grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED)
        return true
    }

    private fun requestPermission(result: MethodChannel.Result) {
        val context = appContext
        if (context != null && ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
            result.success(true); return
        }
        val host = activity?.activity
        if (host == null) { result.success(false); return }
        if (pendingPermission != null) { result.error("busy", "正在等待相机授权", null); return }
        pendingPermission = result
        ActivityCompat.requestPermissions(host, arrayOf(Manifest.permission.CAMERA), REQ_CAMERA)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) { sink = events }
    override fun onCancel(arguments: Any?) { sink = null }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> {
                front = call.argument<Boolean>("front") ?: false
                sampleMs = ((call.argument<Int>("sampleMs") ?: 1000).toLong()).coerceIn(250L, 10000L)
                start(result)
            }
            "switchCamera" -> {
                front = !front
                if (running) bind() else Unit
                result.success(front)
            }
            "requestPermission" -> requestPermission(result)
            "stop" -> { stop(); result.success(null) }
            else -> result.notImplemented()
        }
    }

    private fun start(result: MethodChannel.Result) {
        val context = appContext
        if (context == null || activity?.activity !is LifecycleOwner) {
            result.error("no_activity", "摄像头需要在应用界面内打开", null); return
        }
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
            result.error("permission", "没有相机权限", null); return
        }
        val future = ProcessCameraProvider.getInstance(context)
        future.addListener({
            provider = runCatching { future.get() }.getOrNull()
            if (provider == null) { result.error("unavailable", "相机不可用", null); return@addListener }
            running = true
            previous = null
            if (bind()) result.success(true) else { running = false; result.error("bind_failed", "无法打开相机", null) }
        }, ContextCompat.getMainExecutor(context))
    }

    private fun bind(): Boolean {
        val owner = activity?.activity as? LifecycleOwner ?: return false
        val p = provider ?: return false
        p.unbindAll()
        val a = ImageAnalysis.Builder()
            .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
            .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_RGBA_8888)
            .build()
        a.setAnalyzer(analyzer) { image -> analyze(image) }
        analysis = a
        val selector = if (front) CameraSelector.DEFAULT_FRONT_CAMERA else CameraSelector.DEFAULT_BACK_CAMERA
        return runCatching { p.bindToLifecycle(owner, selector, a); true }.getOrDefault(false)
    }

    private fun analyze(image: ImageProxy) {
        try {
            if (!running) return
            val now = System.currentTimeMillis()
            if (now - lastPreview < previewMs) return
            lastPreview = now
            val keep = now - lastKeep >= sampleMs
            val raw = image.toBitmap()
            val upright = FrameBitmaps.upright(raw, image.imageInfo.rotationDegrees, mirror = front)
            val dim = if (keep) MAX_KEEP_DIM else MAX_PREVIEW_DIM
            val scaled = FrameBitmaps.downscale(upright, dim)
            var change = 0.0
            if (keep) {
                lastKeep = now
                val grid = FrameBitmaps.grid(scaled)
                change = previous?.let { FrameBitmaps.difference(it, grid) } ?: 1.0
                previous = grid
            }
            val jpeg = FrameBitmaps.jpeg(scaled, if (keep) 65 else 50)
            val frame = mapOf(
                "ts" to now, "jpeg" to jpeg, "change" to change, "keep" to keep,
                "width" to scaled.width, "height" to scaled.height, "source" to "camera",
            )
            recycle(raw, upright, scaled)
            main.post { if (running) sink?.success(frame) }
        } catch (_: Exception) {
        } finally {
            image.close()
        }
    }

    private fun recycle(vararg bitmaps: Bitmap) {
        bitmaps.distinct().forEach { runCatching { it.recycle() } }
    }

    private fun stop() {
        running = false
        val p = provider
        main.post { runCatching { p?.unbindAll() } }
        analysis?.clearAnalyzer()
        analysis = null
        previous = null
    }

    companion object {
        private const val REQ_CAMERA = 0x5c02
        private const val MAX_PREVIEW_DIM = 480
        private const val MAX_KEEP_DIM = 1024
    }
}
