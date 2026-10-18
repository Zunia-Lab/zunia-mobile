package com.zuniawallet.zunia_mobile

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.PersistableBundle
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import android.util.Base64
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricManager.Authenticators.BIOMETRIC_STRONG
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * `zunia/security`: hardware-bound biometric unlock, basic root checks and
 * sensitive clipboard copies. Dart side: lib/security/biometric_vault.dart,
 * device_integrity.dart, clipboard_guard.dart.
 */
class ZuniaSecurity(private val activity: FragmentActivity) : MethodChannel.MethodCallHandler {
    private val vault = BiometricVault(activity)

    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, "zunia/security").setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "biometric.availability" -> result.success(vault.availability())
            "biometric.exists" -> result.success(vault.exists())
            "biometric.store" -> {
                val secret = call.argument<String>("secret")
                if (secret.isNullOrEmpty()) {
                    result.error("failed", "Nothing to store", null)
                } else {
                    vault.store(secret, Prompt.from(call), result)
                }
            }
            "biometric.read" -> vault.read(Prompt.from(call), result)
            "biometric.delete" -> {
                vault.delete()
                result.success(null)
            }
            "integrity.check" -> result.success(DeviceIntegrityCheck.run())
            "clipboard.copySensitive" -> {
                copySensitive(activity, call.argument<String>("text") ?: "")
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    /**
     * Android 13+ reads EXTRA_IS_SENSITIVE and keeps the text out of the copy
     * preview; earlier versions read the same key spelled out.
     */
    private fun copySensitive(context: Context, text: String) {
        val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        val clip = ClipData.newPlainText("", text)
        clip.description.extras = PersistableBundle().apply {
            if (Build.VERSION.SDK_INT >= 33) {
                putBoolean(ClipDescription.EXTRA_IS_SENSITIVE, true)
            } else {
                putBoolean("android.content.extra.IS_SENSITIVE", true)
            }
        }
        clipboard.setPrimaryClip(clip)
    }
}

/** Text of the system biometric prompt. */
class Prompt(val title: String, val subtitle: String?, val cancel: String) {
    companion object {
        fun from(call: MethodCall) = Prompt(
            title = call.argument<String>("title") ?: "Unlock Zunia",
            subtitle = call.argument<String>("subtitle"),
            cancel = call.argument<String>("cancel") ?: "Use password",
        )
    }
}

/**
 * The wallet password behind a key only a strong biometric releases.
 *
 * The key: AES-256-GCM in the Android Keystore (TEE, or StrongBox where the
 * Keystore picks it), `setUserAuthenticationRequired(true)` for every use
 * (`AUTH_BIOMETRIC_STRONG` with timeout 0 on Android 11+, validity -1 before),
 * `setInvalidatedByBiometricEnrollment(true)`. It never leaves the hardware;
 * a Cipher on it works only inside a successful `BiometricPrompt` given that
 * Cipher as its `CryptoObject`. A new fingerprint or face invalidates the key
 * for good (KeyPermanentlyInvalidatedException), and biometric unlock must be
 * set up again with the password. The ciphertext, useless without the key,
 * sits in app-private SharedPreferences, outside every backup (allowBackup
 * is false).
 */
private class BiometricVault(private val activity: FragmentActivity) {
    companion object {
        private const val ALIAS = "zunia.biometric-vault.v1"
        private const val PREFS = "zunia_biometric_vault"
        private const val BLOB = "secret"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
    }

    private val prefs = activity.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun keyStore(): KeyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }

    fun availability(): Map<String, Any?> {
        val status = BiometricManager.from(activity).canAuthenticate(BIOMETRIC_STRONG)
        val reason = when (status) {
            BiometricManager.BIOMETRIC_SUCCESS -> null
            BiometricManager.BIOMETRIC_ERROR_NONE_ENROLLED -> "none_enrolled"
            BiometricManager.BIOMETRIC_ERROR_SECURITY_UPDATE_REQUIRED -> "unsupported"
            else -> "no_hardware"
        }
        return mapOf(
            "available" to (status == BiometricManager.BIOMETRIC_SUCCESS),
            "kind" to kind(),
            "reason" to reason,
        )
    }

    /** For labels only. A device with a fingerprint reader says fingerprint. */
    private fun kind(): String {
        val pm = activity.packageManager
        return when {
            pm.hasSystemFeature(PackageManager.FEATURE_FINGERPRINT) -> "fingerprint"
            Build.VERSION.SDK_INT >= 29 && pm.hasSystemFeature(PackageManager.FEATURE_FACE) -> "face"
            Build.VERSION.SDK_INT >= 29 && pm.hasSystemFeature(PackageManager.FEATURE_IRIS) -> "iris"
            else -> "biometric"
        }
    }

    fun exists(): Boolean = try {
        prefs.contains(BLOB) && keyStore().containsAlias(ALIAS)
    } catch (e: Exception) {
        false
    }

    fun store(secret: String, prompt: Prompt, result: MethodChannel.Result) {
        val cipher = try {
            delete()
            Cipher.getInstance(TRANSFORMATION).apply { init(Cipher.ENCRYPT_MODE, createKey()) }
        } catch (e: Exception) {
            result.error("unavailable", e.message, null)
            return
        }
        authenticate(prompt, cipher, result) { authorized ->
            val ciphertext = authorized.doFinal(secret.toByteArray(Charsets.UTF_8))
            val blob = Base64.encodeToString(authorized.iv, Base64.NO_WRAP) + ":" +
                Base64.encodeToString(ciphertext, Base64.NO_WRAP)
            check(prefs.edit().putString(BLOB, blob).commit()) { "Could not save" }
            null
        }
    }

    fun read(prompt: Prompt, result: MethodChannel.Result) {
        val blob = prefs.getString(BLOB, null)
        if (blob == null) {
            result.error("not_found", null, null)
            return
        }
        val parts = blob.split(":")
        val key = try {
            keyStore().getKey(ALIAS, null) as? SecretKey
        } catch (e: Exception) {
            null
        }
        if (parts.size != 2 || key == null) {
            delete()
            result.error("invalidated", null, null)
            return
        }
        val iv = Base64.decode(parts[0], Base64.NO_WRAP)
        val ciphertext = Base64.decode(parts[1], Base64.NO_WRAP)
        val cipher = try {
            Cipher.getInstance(TRANSFORMATION).apply {
                init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, iv))
            }
        } catch (e: KeyPermanentlyInvalidatedException) {
            // A face or fingerprint was added (or all were removed).
            delete()
            result.error("invalidated", e.message, null)
            return
        } catch (e: Exception) {
            result.error("failed", e.message, null)
            return
        }
        authenticate(prompt, cipher, result) { authorized ->
            String(authorized.doFinal(ciphertext), Charsets.UTF_8)
        }
    }

    fun delete() {
        prefs.edit().remove(BLOB).commit()
        try {
            keyStore().deleteEntry(ALIAS)
        } catch (e: Exception) {
            // Nothing to delete.
        }
    }

    private fun createKey(): SecretKey {
        val builder = KeyGenParameterSpec.Builder(
            ALIAS,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
        )
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .setUserAuthenticationRequired(true)
        if (Build.VERSION.SDK_INT >= 30) {
            builder.setUserAuthenticationParameters(0, KeyProperties.AUTH_BIOMETRIC_STRONG)
        } else {
            @Suppress("DEPRECATION")
            builder.setUserAuthenticationValidityDurationSeconds(-1)
        }
        if (Build.VERSION.SDK_INT >= 24) {
            builder.setInvalidatedByBiometricEnrollment(true)
        }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(builder.build())
        return generator.generateKey()
    }

    private fun authenticate(
        prompt: Prompt,
        cipher: Cipher,
        result: MethodChannel.Result,
        onAuthorized: (Cipher) -> Any?,
    ) {
        var answered = false
        val callback = object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(auth: BiometricPrompt.AuthenticationResult) {
                if (answered) return
                answered = true
                val authorized = auth.cryptoObject?.cipher
                if (authorized == null) {
                    result.error("failed", "No cipher", null)
                    return
                }
                try {
                    result.success(onAuthorized(authorized))
                } catch (e: Exception) {
                    result.error("failed", e.message, null)
                }
            }

            override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                if (answered) return
                answered = true
                result.error(codeFor(errorCode), errString.toString(), null)
            }

            // onAuthenticationFailed: a finger or face that did not match.
            // The prompt stays up and says so; nothing to answer yet.
        }
        val info = BiometricPrompt.PromptInfo.Builder()
            .setTitle(prompt.title)
            .apply { prompt.subtitle?.let { setSubtitle(it) } }
            .setNegativeButtonText(prompt.cancel)
            .setAllowedAuthenticators(BIOMETRIC_STRONG)
            .setConfirmationRequired(false)
            .build()
        BiometricPrompt(activity, ContextCompat.getMainExecutor(activity), callback)
            .authenticate(info, BiometricPrompt.CryptoObject(cipher))
    }

    private fun codeFor(errorCode: Int): String = when (errorCode) {
        BiometricPrompt.ERROR_USER_CANCELED,
        BiometricPrompt.ERROR_NEGATIVE_BUTTON,
        BiometricPrompt.ERROR_CANCELED -> "cancelled"
        BiometricPrompt.ERROR_LOCKOUT,
        BiometricPrompt.ERROR_LOCKOUT_PERMANENT -> "lockout"
        BiometricPrompt.ERROR_NO_BIOMETRICS,
        BiometricPrompt.ERROR_HW_NOT_PRESENT,
        BiometricPrompt.ERROR_HW_UNAVAILABLE -> "unavailable"
        else -> "failed"
    }
}

/**
 * Basic root checks. Each one is easy for a determined attacker to hide (Magisk
 * DenyList does exactly that), so a clean result is reported as "no obvious
 * sign", never as safe.
 */
private object DeviceIntegrityCheck {
    private val suPaths = listOf(
        "/system/bin/su", "/system/xbin/su", "/sbin/su", "/su/bin/su",
        "/system/sd/xbin/su", "/system/bin/failsafe/su", "/data/local/su",
        "/data/local/bin/su", "/data/local/xbin/su", "/cache/su", "/dev/su",
        "/system/app/Superuser.apk", "/system/app/SuperSU.apk",
    )
    private val rootManagerPaths = listOf(
        "/sbin/.magisk", "/data/adb/magisk", "/data/adb/modules", "/data/adb/ksu",
        "/data/adb/ap", "/cache/.disable_magisk", "/dev/.magisk.unblock",
    )

    fun run(): Map<String, Any?> {
        val signals = mutableListOf<String>()
        for (path in suPaths) if (File(path).exists()) signals.add("su binary at $path")
        for (path in rootManagerPaths) if (File(path).exists()) signals.add("root manager files at $path")
        if (Build.TAGS?.contains("test-keys") == true) signals.add("system build signed with test-keys")
        val emulator = isEmulator()
        // Emulator images are debuggable by design; that is not a compromise.
        if (!emulator && property("ro.debuggable") == "1") signals.add("ro.debuggable is 1")
        if (property("ro.secure") == "0") signals.add("ro.secure is 0")
        return mapOf(
            "compromised" to signals.isNotEmpty(),
            "signals" to signals,
            "emulator" to emulator,
        )
    }

    private fun isEmulator(): Boolean =
        Build.FINGERPRINT.startsWith("generic") ||
            Build.FINGERPRINT.contains("emulator") ||
            Build.MODEL.contains("Emulator") ||
            Build.MODEL.contains("Android SDK built for") ||
            Build.HARDWARE.contains("goldfish") ||
            Build.HARDWARE.contains("ranchu") ||
            Build.PRODUCT.contains("sdk_gphone")

    private fun property(name: String): String? = try {
        val process = ProcessBuilder("getprop", name).redirectErrorStream(true).start()
        process.inputStream.bufferedReader().use { it.readLine()?.trim() }.also { process.destroy() }
    } catch (e: Exception) {
        null
    }
}
