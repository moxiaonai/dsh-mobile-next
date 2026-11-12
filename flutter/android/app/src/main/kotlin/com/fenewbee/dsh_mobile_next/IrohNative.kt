package com.fenewbee.dsh_mobile_next

import android.content.Context

/** JNI binding to the upstream authenticated iroh byte carrier. */
internal object IrohNative {
    private var initialized = false
    @Synchronized fun initialize(context: Context) {
        if (initialized) return
        System.loadLibrary("dsh_mobile_iroh_android_transport")
        nativeInitialize(context.applicationContext)
        initialized = true
    }
    external fun nativeConnect(requestId: Long, peer: String, code: String,
        deviceName: String, dataDirectory: String, localPort: Int): String
    external fun nativeClose(requestId: Long)
    external fun nativeStatus(requestId: Long): String
    private external fun nativeInitialize(context: Context)
}
