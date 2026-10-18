package com.zuniawallet.zunia_mobile

import android.os.Build
import android.os.Bundle
import android.view.HapticFeedbackConstants
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * FlutterFragmentActivity is required for local_auth.
 *
 * FLAG_SECURE: handled via MethodChannel `com.zuniawallet.zunia_mobile/secure`
 * method `setFlagSecure` with argument `enabled: Boolean`. When true, sets
 * WindowManager.LayoutParams.FLAG_SECURE so the window is excluded from
 * screenshots and the app switcher thumbnail.
 */
class MainActivity : FlutterFragmentActivity() {
    private val secureChannel = "com.zuniawallet.zunia_mobile/secure"
    private val hapticsChannel = "zunia/haptics"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, secureChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setFlagSecure" -> {
                        val enabled = call.argument<Boolean>("enabled") ?: false
                        if (enabled) {
                            window.setFlags(
                                WindowManager.LayoutParams.FLAG_SECURE,
                                WindowManager.LayoutParams.FLAG_SECURE,
                            )
                        } else {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        // Android 11+ has dedicated confirm/reject feedback; older releases get
        // the closest system constant rather than a raw vibration.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, hapticsChannel)
            .setMethodCallHandler { call, result ->
                val view = window.decorView
                val constant = when (call.method) {
                    "success" -> if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R)
                        HapticFeedbackConstants.CONFIRM else HapticFeedbackConstants.VIRTUAL_KEY
                    "warning" -> HapticFeedbackConstants.KEYBOARD_TAP
                    "error" -> if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R)
                        HapticFeedbackConstants.REJECT else HapticFeedbackConstants.LONG_PRESS
                    else -> null
                }
                if (constant == null) {
                    result.notImplemented()
                } else {
                    view.performHapticFeedback(constant)
                    result.success(null)
                }
            }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
    }
}
