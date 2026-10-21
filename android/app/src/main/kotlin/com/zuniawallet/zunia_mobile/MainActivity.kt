package com.zuniawallet.zunia_mobile

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.HapticFeedbackConstants
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * FlutterFragmentActivity: BiometricPrompt (ZuniaSecurity) needs a FragmentActivity.
 *
 * FLAG_SECURE: handled via MethodChannel `com.zuniawallet.zunia_mobile/secure`
 * method `setFlagSecure` with argument `enabled: Boolean`. When true, sets
 * WindowManager.LayoutParams.FLAG_SECURE so the window is excluded from
 * screenshots and the app switcher thumbnail.
 */
class MainActivity : FlutterFragmentActivity() {
    private val secureChannel = "com.zuniawallet.zunia_mobile/secure"
    private val hapticsChannel = "zunia/haptics"
    private val settingsChannel = "zunia/settings"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        ZuniaSecurity(this).register(flutterEngine.dartExecutor.binaryMessenger)
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
        // The scanner sends the user here when camera access was refused;
        // url_launcher cannot open this page, it only sends VIEW intents.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, settingsChannel)
            .setMethodCallHandler { call, result ->
                if (call.method == "openAppSettings") {
                    val intent = Intent(
                        Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                        Uri.fromParts("package", packageName, null),
                    ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    startActivity(intent)
                    result.success(null)
                } else {
                    result.notImplemented()
                }
            }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Android 12+: Flutter's first frame already shows the splash mark on the
        // same pixels (values-v31/styles.xml), so hand over at once. The default
        // exit (a fade while the window slides up) would make the mark jump.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            splashScreen.setOnExitAnimationListener { view -> view.remove() }
        }
        // Recents shows a blank card instead of a screenshot of balances and
        // addresses. Screenshots by the user stay possible (receive codes);
        // phrase and password screens add FLAG_SECURE on top.
        if (Build.VERSION.SDK_INT >= 33) {
            setRecentsScreenshotEnabled(false)
        }
    }
}
