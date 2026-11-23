package io.github.ccch1mneyyy.dsh_app.screencap

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.Matrix
import android.media.Image
import java.io.ByteArrayOutputStream
import kotlin.math.abs

/** Bitmap helpers shared by the screen and camera capture. */
internal object FrameBitmaps {
    const val GRID_W = 64
    const val GRID_H = 36

    /** An RGBA_8888 [Image] (ImageReader) as a bitmap of [width]×[height], row padding cropped. */
    fun fromImage(image: Image, width: Int, height: Int): Bitmap {
        val plane = image.planes[0]
        val paddedWidth = plane.rowStride / plane.pixelStride
        val bmp = Bitmap.createBitmap(paddedWidth, height, Bitmap.Config.ARGB_8888)
        bmp.copyPixelsFromBuffer(plane.buffer)
        if (paddedWidth == width) return bmp
        val cropped = Bitmap.createBitmap(bmp, 0, 0, width, height)
        bmp.recycle()
        return cropped
    }

    /** [src] scaled so its longer side is at most [maxDim]; [src] itself when small enough. */
    fun downscale(src: Bitmap, maxDim: Int): Bitmap {
        val longer = maxOf(src.width, src.height)
        if (longer <= maxDim) return src
        val ratio = maxDim.toFloat() / longer
        val w = (src.width * ratio).toInt().coerceAtLeast(1)
        val h = (src.height * ratio).toInt().coerceAtLeast(1)
        return Bitmap.createScaledBitmap(src, w, h, true)
    }

    /** [src] turned upright by [degrees] (and mirrored for a front camera); [src] when unchanged. */
    fun upright(src: Bitmap, degrees: Int, mirror: Boolean): Bitmap {
        if (degrees % 360 == 0 && !mirror) return src
        val m = Matrix()
        if (mirror) m.postScale(-1f, 1f)
        m.postRotate(degrees.toFloat())
        return Bitmap.createBitmap(src, 0, 0, src.width, src.height, m, true)
    }

    fun jpeg(bitmap: Bitmap, quality: Int): ByteArray {
        val out = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.JPEG, quality, out)
        return out.toByteArray()
    }

    fun grid(bitmap: Bitmap): ByteArray {
        val small = Bitmap.createScaledBitmap(bitmap, GRID_W, GRID_H, true)
        val pixels = IntArray(GRID_W * GRID_H)
        small.getPixels(pixels, 0, GRID_W, 0, 0, GRID_W, GRID_H)
        if (small !== bitmap) small.recycle()
        return ByteArray(pixels.size) { i ->
            val c = pixels[i]
            ((77 * Color.red(c) + 150 * Color.green(c) + 29 * Color.blue(c)) shr 8).toByte()
        }
    }

    /** Mean absolute luma difference of two grids, 0..1. */
    fun difference(a: ByteArray, b: ByteArray): Double {
        var sum = 0L
        for (i in a.indices) sum += abs((a[i].toInt() and 255) - (b[i].toInt() and 255))
        return sum.toDouble() / (a.size * 255.0)
    }
}
