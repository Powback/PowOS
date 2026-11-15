#include <jni.h>
#include <stdint.h>
#include <stddef.h>
#include "powstream_client_core.h"

_Static_assert(PS_ABI_VERSION == 1, "ABI mismatch");
_Static_assert(sizeof(PsConfig) == 56 && sizeof(PsAu) == 56 && sizeof(PsStats) == 48,
               "ARM64 natural ABI layout required");
_Static_assert(offsetof(PsAu, len) == 48, "AU layout mismatch");
#define JNI(name) Java_andro_marchy_stream_PowStreamCore_##name
#define UNUSED (void)cls

JNIEXPORT jlong JNICALL JNI(openNative)(JNIEnv *env, jclass cls, jstring url,
                                        jstring token, jbyteArray pin) {
    UNUSED;
    if (!url || !token || !pin || (*env)->GetArrayLength(env, pin) != 32) return 0;
    PsConfig config = {.abi_version = PS_ABI_VERSION};
    config.endpoint_url = (*env)->GetStringUTFChars(env, url, NULL);
    if (!config.endpoint_url) return 0;
    config.token = (*env)->GetStringUTFChars(env, token, NULL);
    if (!config.token) {
        (*env)->ReleaseStringUTFChars(env, url, config.endpoint_url);
        return 0;
    }
    (*env)->GetByteArrayRegion(env, pin, 0, 32, (jbyte *)config.cert_sha256);
    PsHandle *h = NULL;
    int rc = (*env)->ExceptionCheck(env) ? PS_INVALID : ps_open(&config, &h);
    (*env)->ReleaseStringUTFChars(env, token, config.token);
    (*env)->ReleaseStringUTFChars(env, url, config.endpoint_url);
    return rc == PS_OK ? (jlong)(intptr_t)h : 0;
}

JNIEXPORT jint JNICALL JNI(pollNative)(JNIEnv *env, jclass cls, jlong handle,
                                       jobject buffer, jlongArray meta) {
    UNUSED;
    if (!handle || !buffer || !meta || (*env)->GetArrayLength(env, meta) < 6) return PS_INVALID;
    void *dst = (*env)->GetDirectBufferAddress(env, buffer);
    jlong cap = (*env)->GetDirectBufferCapacity(env, buffer);
    if (!dst || cap <= 0) return PS_INVALID;
    PsAu au = {0};
    int rc = ps_poll_au((PsHandle *)(intptr_t)handle, dst, (size_t)cap, &au);
    if (rc == PS_OK || rc == PS_BUFFER_SMALL) {
        jlong values[] = {(jlong)au.len, au.frame_id, au.width, au.height, au.flags, (jlong)au.received_ns};
        (*env)->SetLongArrayRegion(env, meta, 0, 6, values);
    }
    return rc;
}

JNIEXPORT jint JNICALL JNI(stateNative)(JNIEnv *env, jclass cls, jlong handle) {
    (void)env; UNUSED;
    if (!handle) return PS_CLOSED;
    PsStats stats = {0};
    int rc = ps_stats((PsHandle *)(intptr_t)handle, &stats);
    return rc == PS_OK ? (jint)stats.state : rc;
}

JNIEXPORT jint JNICALL JNI(closeNative)(JNIEnv *env, jclass cls, jlong handle) {
    (void)env; UNUSED;
    return ps_close((PsHandle *)(intptr_t)handle);
}
