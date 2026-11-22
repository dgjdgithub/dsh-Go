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
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.io.ByteArrayOutputStream

/**
 * 屏幕共享 / 截屏: MediaProjection based capture.
 *
 * Flow (Dart side drives it):
 *  1. requestPermission  -> system consent dialog (onActivityResult code REQ_PROJECTION)
 *  2. captureOnce        -> grabs the current screen as a PNG and returns it as base64
 *
 * The projection is kept alive between captures while granted; startCapture() is only called
 * once per projection token (Android 14+ requires a fresh consent per token, and reusing a
 * consumed token throws SecurityException).
 */
class ScreenCapturePlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler,
    PluginRegistry.ActivityResultListener {

    private var channel: MethodChannel? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var appContext: Context? = null
    private var pendingPermission: MethodChannel.Result? = null
    private var pendingCapture: MethodChannel.Result? = null

    private var projection: MediaProjection? = null
    private var resultCode: Int = Activity.RESULT_CANCELED
    private var resultData: Intent? = null

    private var handlerThread: HandlerThread? = null
    private var handler: Handler? = null
    private var imageReader: ImageReader? = null
    private var virtualDisplay: VirtualDisplay? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "dsh/screencap").also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        appContext = null
        stopProjection()
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

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "hasPermission" -> result.success(projection != null)
            "requestPermission" -> requestPermission(result)
            "captureOnce" -> captureOnce(result)
            "release" -> { stopProjection(); result.success(null) }
            else -> result.notImplemented()
        }
    }

    private fun requestPermission(result: MethodChannel.Result) {
        val activity = activityBinding?.activity
        if (activity == null) {
            result.error("no_activity", "屏幕共享需要在应用界面内发起", null)
            return
        }
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
            ensureProjection()
            pending?.success(true)
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
            override fun onStop() { stopProjection() }
        }, Handler(android.os.Looper.getMainLooper()))
        projection = p
        return p
    }

    private fun captureOnce(result: MethodChannel.Result) {
        val context = appContext
        val activity = activityBinding?.activity
        if (context == null || activity == null) {
            result.error("no_activity", "截屏需要在应用界面内发起", null)
            return
        }
        val proj = ensureProjection()
        if (proj == null) {
            result.error("no_permission", "尚未授予屏幕共享权限，请先调用 requestPermission", null)
            return
        }
        if (pendingCapture != null) {
            result.error("busy", "上一次截屏尚未完成", null)
            return
        }
        pendingCapture = result

        val metrics = context.resources.displayMetrics
        val width = metrics.widthPixels
        val height = metrics.heightPixels
        val density = metrics.densityDpi

        startThreadIfNeeded()
        val threadHandler = handler!!

        // Fresh reader per capture so we never read a stale buffer.
        imageReader?.close()
        val reader = ImageReader.newInstance(width, height, PixelFormat.RGBA_8888, 2)
        imageReader = reader

        reader.setOnImageAvailableListener({ r ->
            val image = r.acquireLatestImage() ?: return@setOnImageAvailableListener
            try {
                val plane = image.planes[0]
                val rowPadding = plane.rowStride - plane.pixelStride * width
                val paddedWidth = plane.rowStride / plane.pixelStride
                val bmp = Bitmap.createBitmap(paddedWidth, height, Bitmap.Config.ARGB_8888)
                bmp.copyPixelsFromBuffer(plane.buffer)
                // Trim the row-stride padding on the right edge.
                val cropped = if (rowPadding > 0)
                    Bitmap.createBitmap(bmp, 0, 0, width, height)
                else bmp
                val bytes = ByteArrayOutputStream()
                cropped.compress(Bitmap.CompressFormat.PNG, 100, bytes)
                val b64 = Base64.encodeToString(bytes.toByteArray(), Base64.NO_WRAP)
                deliverCapture(b64)
                if (cropped !== bmp) bmp.recycle()
                cropped.recycle()
            } catch (e: Exception) {
                failCapture("capture_failed", e.message)
            } finally {
                image.close()
            }
        }, threadHandler)

        try {
            if (virtualDisplay == null) {
                virtualDisplay = proj.createVirtualDisplay(
                    "dsh-screencap",
                    width, height, density,
                    DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
                    reader.surface, null, threadHandler,
                )
            } else {
                virtualDisplay?.surface = reader.surface
            }
        } catch (e: SecurityException) {
            // Token consumed (Android 14+ requires a new consent each start). Reset and report.
            stopProjection()
            failCapture("need_reconsent", "屏幕共享令牌已失效，需要重新授权")
        } catch (e: Exception) {
            failCapture("display_failed", e.message)
        }
    }

    private fun deliverCapture(base64: String) {
        val r = pendingCapture ?: return
        pendingCapture = null
        Handler(android.os.Looper.getMainLooper()).post { r.success(base64) }
    }

    private fun failCapture(code: String, msg: String?) {
        val r = pendingCapture ?: return
        pendingCapture = null
        Handler(android.os.Looper.getMainLooper()).post { r.error(code, msg, null) }
    }

    private fun startThreadIfNeeded() {
        if (handlerThread != null) return
        val t = HandlerThread("dsh-screencap").also { it.start() }
        handlerThread = t
        handler = Handler(t.looper)
    }

    private fun stopProjection() {
        runCatching { virtualDisplay?.release() }
        virtualDisplay = null
        runCatching { imageReader?.close() }
        imageReader = null
        runCatching { projection?.stop() }
        projection = null
        val t = handlerThread
        handlerThread = null
        handler = null
        runCatching { t?.quitSafely() }
    }

    companion object {
        private const val REQ_PROJECTION = 0x5c01
    }
}
