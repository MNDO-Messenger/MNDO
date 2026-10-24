package com.aisatconnect.aisat_connect

import android.app.Activity
import android.os.Build
import android.view.WindowManager
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "mndo/screen_security"
    private var methodChannel: MethodChannel? = null
    private var screenCaptureCallback: Activity.ScreenCaptureCallback? = null

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        methodChannel = channel

        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "setScreenSecurity" -> {
                    val enable = call.argument<Boolean>("enable") ?: true
                    setScreenSecurity(enable)
                    result.success(true)
                }
                "isScreenCaptureSupported" -> {
                    result.success(Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
                }
                else -> result.notImplemented()
            }
        }

        setupScreenCaptureCallback()
    }

    private fun setScreenSecurity(enable: Boolean) {
        runOnUiThread {
            if (enable) {
                window.setFlags(
                    WindowManager.LayoutParams.FLAG_SECURE,
                    WindowManager.LayoutParams.FLAG_SECURE
                )
            } else {
                window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
            }
        }
    }

    private fun setupScreenCaptureCallback() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            try {
                val callback = Activity.ScreenCaptureCallback {
                    runOnUiThread {
                        methodChannel?.invokeMethod("onScreenshotDetected", null)
                    }
                }
                screenCaptureCallback = callback
                registerScreenCaptureCallback(mainExecutor, callback)
            } catch (e: Throwable) {
                android.util.Log.w("MainActivity", "Failed to register screen capture callback: ${e.message}")
            }
        }
    }

    override fun onDestroy() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            try {
                screenCaptureCallback?.let {
                    unregisterScreenCaptureCallback(it)
                }
            } catch (e: Throwable) {
                android.util.Log.w("MainActivity", "Failed to unregister screen capture callback: ${e.message}")
            }
        }
        methodChannel?.setMethodCallHandler(null)
        methodChannel = null
        super.onDestroy()
    }
}
