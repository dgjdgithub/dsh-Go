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
import android.util.Base64
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.io.ByteArrayOutputStream

/**
 * 屏幕共享: MediaProjection based capture.
 *
 * Two modes:
 *  - captureOnce: one PNG frame, for the standalone 屏幕共享 page's one-shot preview.
 *  - startSharing(intervalMs) / stopSharing: continuous. A VirtualDisplay mirrors the
 *    screen to an ImageReader; a timer every [intervalMs] takes the newest frame,
 *    encodes it as JPEG and streams it as base64 over `dsh/screencap/frames`.
 *
 * The projection token is kept while granted. Android 14+ requires a fresh consent
 * per token (reusing a consumed token throws SecurityException), so we start it once
 * after onActivityResult and keep the VirtualDisplay alive.
 */
class ScreenCapturePlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler, PluginRegistry.ActivityResultListener {

    private var methods: MethodChannel? = null
    private var events: EventChannel? = null
    private var sink: EventChannel.EventSink? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var appContext: Context? = null
    private var pendingPermission: MethodChannel.Result? = null
    private var pendingCapture: MethodChannel.Result? = null
    private val main = Handler(android.os.Looper.getMainLooper())

    private var projection: MediaProjection? = null
    private var resultCode: Int = Activity.RESULT_CANCELED
    private var resultData: Intent? = null

    private var handlerThread: HandlerThread? = null
    private var handler: Handler? = null
    private var imageReader: ImageReader? = null
    private var virtualDisplay: VirtualDisplay? = null

    private var sharing = false
    private var intervalMs = 3000L
    private var latestJpeg: ByteArray? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        methods = MethodChannel(binding.binaryMessenger, "dsh/screencap").also { it.setMethodCallHandler(this) }
        events = EventChannel(binding.binaryMessenger, "dsh/screencap/frames").also { it.setStreamHandler(this) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methods?.setMethodCallHandler(null); methods = null
        events?.setStreamHandler(null); events = null
        appContext = null
        stopSharing()
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

    // ---- EventChannel ----
    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) { sink = events }
    override fun onCancel(arguments: Any?) { sink = null }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "hasPermission" -> result.success(projection != null)
            "requestPermission" -> requestPermission(result)
            "captureOnce" -> captureOnce(result)
            "startSharing" -> {
                intervalMs = ((call.argument<Int>("intervalMs") ?: 3000).toLong()).coerceIn(500L, 60000L)
                startSharing(result)
            }
            "stopSharing" -> { stopSharing(); result.success(null) }
            "release" -> { stopSharing(); result.success(null) }
            else -> result.notImplemented()
        }
    }

    private fun requestPermission(result: MethodChannel.Result) {
        val activity = activityBinding?.activity
        if (activity == null) { result.error("no_activity", "屏幕共享需要在应用界面内发起", null); return }
        if (projection != null) { result.success(true); return }
        val mgr = activity.getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        pendingPermission = result
        activity.startActivityForResult(mgr.createScreenCaptureIntent(), REQ_PROJECTION)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQ_PROJECTION) return false
        val pending = pendingPermission
        pendingPermission = null
        if (resultCode == Activity.RESULT_OK && data != null) {
            this.resultCode = resultCode
            this.resultData = data
            pending?.success(ensureProjection() != null)
        } else {
            pending?.success(false)
        }
        return true
    }

    private fun ensureProjection(): MediaProjection? {
        if (projection != null) return projection
        val context = appContext ?: return null
        val data = resultData ?: return null
        val mgr = context.getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        val p = mgr.getMediaProjection(resultCode, data) ?: return null
        p.registerCallback(object : MediaProjection.Callback() {
            override fun onStop() { stopSharing() }
        }, main)
        projection = p
        return p
    }

    // ---- Continuous sharing ----

    private fun startSharing(result: MethodChannel.Result) {
        val context = appContext
        val activity = activityBinding?.activity
        if (context == null || activity == null) { result.error("no_activity", "截屏需要在应用界面内发起", null); return }
        val proj = ensureProjection()
        if (proj == null) { result.error("no_permission", "尚未授予屏幕共享权限，请先 requestPermission", null); return }
        if (sharing) { result.success(null); return }

        val metrics = context.resources.displayMetrics
        val width = metrics.widthPixels
        val height = metrics.heightPixels
        val density = metrics.densityDpi

        startThreadIfNeeded()
        val threadHandler = handler!!

        imageReader?.close()
        val reader = ImageReader.newInstance(width, height, PixelFormat.RGBA_8888, 3)
        imageReader = reader

        try {
            virtualDisplay = proj.createVirtualDisplay(
                "dsh-screencap", width, height, density,
                DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
                reader.surface, null, threadHandler,
            )
        } catch (e: SecurityException) {
            stopSharing()
            result.error("need_reconsent", "屏幕共享令牌失效，需要重新授权", null)
            return
        } catch (e: Exception) {
            stopSharing()
            result.error("display_failed", e.message, null)
            return
        }

        sharing = true
        latestJpeg = null
        threadHandler.post(frameTick)
        result.success(null)
    }

    private val frameTick = object : Runnable {
        override fun run() {
            if (!sharing) return
            val reader = imageReader
            if (reader != null) {
                val img = try { reader.acquireLatestImage() } catch (_: Exception) { null }
                if (img != null) {
                    try {
                        latestJpeg = toJpeg(img, reader.width, reader.height)
                    } catch (_: Exception) {
                    } finally {
                        img.close()
                    }
                }
            }
            val bytes = latestJpeg
            if (bytes != null) {
                val b64 = Base64.encodeToString(bytes, Base64.NO_WRAP)
                main.post { sink?.success(b64) }
            }
            handler?.postDelayed(this, intervalMs)
        }
    }

    private fun toJpeg(image: android.media.Image, width: Int, height: Int): ByteArray {
        val plane = image.planes[0]
        val rowStride = plane.rowStride
        val pixelStride = plane.pixelStride
        val paddedWidth = rowStride / pixelStride
        val bmp = Bitmap.createBitmap(paddedWidth, height, Bitmap.Config.ARGB_8888)
        bmp.copyPixelsFromBuffer(plane.buffer)
        val cropped = if (paddedWidth != width) Bitmap.createBitmap(bmp, 0, 0, width, height) else bmp
        val out = ByteArrayOutputStream()
        cropped.compress(Bitmap.CompressFormat.JPEG, 70, out)
        if (cropped !== bmp) cropped.recycle()
        bmp.recycle()
        return out.toByteArray()
    }

    // ---- One-shot PNG ----

    private fun captureOnce(result: MethodChannel.Result) {
        val context = appContext
        if (context == null) { result.error("no_activity", "截屏需要在应用界面内发起", null); return }
        val proj = ensureProjection()
        if (proj == null) { result.error("no_permission", "尚未授予屏幕共享权限，请先 requestPermission", null); return }
        if (pendingCapture != null) { result.error("busy", "上一次截屏尚未完成", null); return }
        pendingCapture = result

        val metrics = context.resources.displayMetrics
        val width = metrics.widthPixels
        val height = metrics.heightPixels

        startThreadIfNeeded()
        val threadHandler = handler!!
        imageReader?.close()
        val reader = ImageReader.newInstance(width, height, PixelFormat.RGBA_8888, 2)
        imageReader = reader
        reader.setOnImageAvailableListener({ r ->
            val image = r.acquireLatestImage() ?: return@setOnImageAvailableListener
            try {
                val png = toPng(image, width, height)
                val b64 = Base64.encodeToString(png, Base64.NO_WRAP)
                deliverCapture(b64)
            } catch (e: Exception) {
                failCapture("capture_failed", e.message)
            } finally {
                image.close()
            }
        }, threadHandler)

        try {
            if (virtualDisplay == null) {
                virtualDisplay = proj.createVirtualDisplay(
                    "dsh-screencap", width, height, metrics.densityDpi,
                    DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
                    reader.surface, null, threadHandler,
                )
            } else {
                virtualDisplay?.surface = reader.surface
            }
        } catch (e: SecurityException) {
            stopSharing()
            failCapture("need_reconsent", "屏幕共享令牌已失效，需要重新授权")
        } catch (e: Exception) {
            failCapture("display_failed", e.message)
        }
    }

    private fun toPng(image: android.media.Image, width: Int, height: Int): ByteArray {
        val plane = image.planes[0]
        val paddedWidth = plane.rowStride / plane.pixelStride
        val bmp = Bitmap.createBitmap(paddedWidth, height, Bitmap.Config.ARGB_8888)
        bmp.copyPixelsFromBuffer(plane.buffer)
        val cropped = if (paddedWidth != width) Bitmap.createBitmap(bmp, 0, 0, width, height) else bmp
        val out = ByteArrayOutputStream()
        cropped.compress(Bitmap.CompressFormat.PNG, 100, out)
        if (cropped !== bmp) cropped.recycle()
        bmp.recycle()
        return out.toByteArray()
    }

    private fun deliverCapture(base64: String) {
        val r = pendingCapture ?: return
        pendingCapture = null
        main.post { r.success(base64) }
    }

    private fun failCapture(code: String, msg: String?) {
        val r = pendingCapture ?: return
        pendingCapture = null
        main.post { r.error(code, msg, null) }
    }

    private fun startThreadIfNeeded() {
        if (handlerThread != null) return
        val t = HandlerThread("dsh-screencap").also { it.start() }
        handlerThread = t
        handler = Handler(t.looper)
    }

    private fun stopSharing() {
        sharing = false
        handler?.removeCallbacksAndMessages(null)
        runCatching { virtualDisplay?.release() }; virtualDisplay = null
        runCatching { imageReader?.close() }; imageReader = null
        runCatching { projection?.stop() }; projection = null
        latestJpeg = null
        val t = handlerThread; handlerThread = null; handler = null
        runCatching { t?.quitSafely() }
    }

    companion object { private const val REQ_PROJECTION = 0x5c01 }
}
