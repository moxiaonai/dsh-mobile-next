package com.fenewbee.dsh_mobile_next

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import android.util.Base64
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.security.cert.TrustAnchor
import java.security.cert.PKIXParameters
import java.security.cert.CertPathValidator
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicLong

class MainActivity : FlutterActivity() {
    private val workers = Executors.newCachedThreadPool()
    private val owner = AtomicLong(0)

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dsh_mobile/iroh")
            .setMethodCallHandler { call, result ->
                val id = call.argument<Number>("requestId")?.toLong() ?: 0
                if (id <= 0) { result.error("invalid_argument", "Invalid transport owner", null); return@setMethodCallHandler }
                try {
                    IrohNative.initialize(applicationContext)
                    when (call.method) {
                        "connect" -> {
                            owner.set(id)
                            val peer = call.argument<String>("endpointId") ?: ""
                            val code = call.argument<String>("code") ?: ""
                            val port = call.argument<Number>("localPort")?.toInt() ?: 0
                            workers.execute {
                                try {
                                    val metadata = JSONObject(IrohNative.nativeConnect(id, peer, code,
                                        "DSH Flutter Android", java.io.File(filesDir, "iroh").absolutePath, port))
                                    val map = mapOf("peerId" to metadata.getString("peerId"),
                                        "localPort" to metadata.getInt("localPort"))
                                    runOnUiThread { result.success(map) }
                                } catch (_: Throwable) {
                                    runOnUiThread { result.error("connection_failed", "iroh connection failed or cancelled", null) }
                                }
                            }
                        }
                        "close" -> { IrohNative.nativeClose(id); owner.compareAndSet(id, 0); result.success(null) }
                        "verifyCertificate" -> {
                            val host = call.argument<String>("host") ?: ""
                            val der = call.argument<ByteArray>("certificate")
                            val ca = call.argument<String>("caCertificate")
                            val verified = runCatching {
                                require(owner.get() == id && der != null && der.size <= 16384 && ca != null && ca.length <= 2048)
                                val factory = CertificateFactory.getInstance("X.509")
                                val leaf = factory.generateCertificate(der!!.inputStream()) as X509Certificate
                                val root = factory.generateCertificate(Base64.decode(ca, Base64.NO_WRAP).inputStream()) as X509Certificate
                                root.checkValidity(); leaf.checkValidity()
                                require(root.basicConstraints >= 0 && root.subjectX500Principal == root.issuerX500Principal)
                                root.verify(root.publicKey)
                                val parameters = PKIXParameters(setOf(TrustAnchor(root, null)))
                                parameters.isRevocationEnabled = false // private offline CA has no CRL service
                                CertPathValidator.getInstance("PKIX").validate(factory.generateCertPath(listOf(leaf)), parameters)
                                // Exact DNS SAN only; no CN fallback or wildcard authority.
                                require(leaf.subjectAlternativeNames?.any { san -> san[0] == 2 && san[1] == host } == true)
                                require(leaf.extendedKeyUsage?.contains("1.3.6.1.5.5.7.3.1") != false)
                                require(owner.get() == id && IrohNative.nativeStatus(id) == "ready")
                                true
                            }.getOrDefault(false)
                            result.success(verified)
                        }
                        "status" -> result.success(IrohNative.nativeStatus(id))
                        else -> result.notImplemented()
                    }
                } catch (_: Throwable) {
                    result.error("native_unavailable", "Build the Android iroh native library for this ABI", null)
                }
            }
    }

    override fun onDestroy() {
        val id = owner.getAndSet(0)
        if (id > 0) runCatching { IrohNative.nativeClose(id) }
        workers.shutdown()
        super.onDestroy()
    }
}
