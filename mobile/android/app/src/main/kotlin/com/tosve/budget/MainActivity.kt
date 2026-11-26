package com.tosve.budget

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.os.Handler
import android.os.Looper
import androidx.exifinterface.media.ExifInterface
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        ReceiptOcr.attach(flutterEngine)
    }
}

/**
 * Reads the text on a receipt photo with Google's ML Kit text reader. The model is inside the
 * app, so it works offline and is free. Returns pieces of text with their box (0..1, measured
 * from the top-left) and slope; the Dart side (TextLines + ReceiptParser) turns them into
 * receipt lines exactly like the web app does. Channel "budget/ocr", method "read"
 * {path, rotation: 0/90/180/270}.
 */
object ReceiptOcr {
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val recognizer by lazy { TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS) }

    fun attach(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, "budget/ocr").setMethodCallHandler { call, result ->
            if (call.method != "read") return@setMethodCallHandler result.notImplemented()
            val path = call.argument<String>("path")
            val rotation = call.argument<Int>("rotation") ?: 0
            if (path == null) return@setMethodCallHandler result.error("no_image", "No photo given.", null)
            worker.execute {
                val bitmap = try {
                    load(path, rotation)
                } catch (e: Exception) {
                    null
                }
                if (bitmap == null) {
                    main.post { result.error("no_image", "The photo could not be opened.", null) }
                    return@execute
                }
                val w = bitmap.width.toDouble()
                val h = bitmap.height.toDouble()
                recognizer.process(InputImage.fromBitmap(bitmap, 0))
                    .addOnSuccessListener { text ->
                        val pieces = ArrayList<Map<String, Any>>()
                        for (block in text.textBlocks) {
                            for (line in block.lines) {
                                val box = line.boundingBox ?: continue
                                val corners = line.cornerPoints
                                var slope = 0.0
                                if (corners != null && corners.size >= 2) {
                                    // Top-left to top-right corner, in the same 0..1 units as the box.
                                    val dx = (corners[1].x - corners[0].x) / w
                                    val dy = (corners[1].y - corners[0].y) / h
                                    if (dx > 0) slope = dy / dx
                                }
                                pieces.add(
                                    mapOf(
                                        "text" to line.text,
                                        "minX" to box.left / w,
                                        "minY" to box.top / h,
                                        "maxX" to box.right / w,
                                        "maxY" to box.bottom / h,
                                        "slope" to slope,
                                        "aspect" to w / h,
                                    ),
                                )
                            }
                        }
                        result.success(pieces)
                    }
                    .addOnFailureListener { e -> result.error("ocr_failed", e.message, null) }
            }
        }
    }

    /** The photo upright (as the camera saved it), then turned clockwise by [rotation] degrees. */
    private fun load(path: String, rotation: Int): Bitmap? {
        val bitmap = BitmapFactory.decodeFile(path) ?: return null
        val exif = when (ExifInterface(path).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)) {
            ExifInterface.ORIENTATION_ROTATE_90 -> 90
            ExifInterface.ORIENTATION_ROTATE_180 -> 180
            ExifInterface.ORIENTATION_ROTATE_270 -> 270
            else -> 0
        }
        val degrees = (exif + rotation) % 360
        if (degrees == 0) return bitmap
        val m = Matrix().apply { postRotate(degrees.toFloat()) }
        return Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, m, true)
    }
}
