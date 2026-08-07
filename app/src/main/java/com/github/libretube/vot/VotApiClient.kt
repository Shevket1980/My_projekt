package com.github.libretube.vot

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.net.URI
import java.security.SecureRandom
import java.util.concurrent.TimeUnit
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec
import kotlin.math.max

/**
 * Native Android client for the Yandex VOT protocol used by
 * FOSWLY/vot.js and ilyhalight/voice-over-translation.
 *
 * Android is not limited by browser CORS, so r5 tries the Yandex endpoint
 * directly first and only then falls back to public VOT workers.
 */
class VotApiClient(
    private val directHost: String = DEFAULT_DIRECT_HOST,
    private val workerHosts: List<String> = DEFAULT_WORKERS,
) {
    data class TranslationResult(
        val audioUrl: String,
        val fallbackAudioUrls: List<String> = emptyList(),
        val detectedLanguage: String? = null,
    )

    private data class Session(
        val uuid: String,
        val secretKey: String,
        val expiresAtSeconds: Long,
    )

    private val http = OkHttpClient.Builder()
        .connectTimeout(20, TimeUnit.SECONDS)
        .readTimeout(60, TimeUnit.SECONDS)
        .writeTimeout(60, TimeUnit.SECONDS)
        .build()

    @Volatile
    private var session: Session? = null

    suspend fun requestTranslation(
        youtubeUrl: String,
        durationSeconds: Double,
        sourceLanguage: String = "auto",
        targetLanguage: String = "ru",
        title: String = "",
    ): TranslationResult = withContext(Dispatchers.IO) {
        var sentAudioFallback = false
        var lastMessage = ""
        var retryAttempt = 0
        var firstRequest = true

        repeat(MAX_TRANSLATION_ATTEMPTS) {
            val activeSession = getSession()
            val body = VotProto.encodeTranslationRequest(
                url = youtubeUrl,
                firstRequest = firstRequest,
                duration = if (durationSeconds > 0.0) durationSeconds else DEFAULT_DURATION,
                language = sourceLanguage,
                responseLanguage = targetLanguage,
                videoTitle = title,
            )

            val responseBytes = requestBinary(
                path = PATH_TRANSLATE,
                body = body,
                method = "POST",
                extraHeaders = secureHeaders("Vtrans", activeSession, body, PATH_TRANSLATE),
            )
            val response = VotProto.decodeTranslationResponse(responseBytes)
            lastMessage = response.message

            when (response.status) {
                STATUS_FINISHED, STATUS_PART_CONTENT -> {
                    if (response.url.isBlank()) {
                        error("VOT returned a finished status without an audio URL")
                    }
                    return@withContext TranslationResult(
                        audioUrl = response.url,
                        fallbackAudioUrls = buildAudioProxyUrls(response.url),
                        detectedLanguage = response.language.takeIf { it.isNotBlank() },
                    )
                }

                STATUS_WAITING, STATUS_LONG_WAITING -> {
                    firstRequest = false
                    val waitMs = if (retryAttempt > 0) {
                        RETRY_INTERVAL_MS
                    } else {
                        val seconds = response.remainingTime.takeIf { it > 0 }
                        when {
                            seconds == null -> RETRY_INTERVAL_MS
                            seconds <= MAX_INITIAL_WAIT_SEC -> max(5, seconds) * 1000L
                            else -> LONG_WAIT_MS
                        }
                    }
                    retryAttempt += 1
                    delay(waitMs)
                }

                STATUS_AUDIO_REQUESTED -> {
                    if (!sentAudioFallback && youtubeUrl.startsWith("https://youtu.be/")) {
                        requestAudioFallback(youtubeUrl, response.translationId)
                        sentAudioFallback = true
                        firstRequest = true
                    } else {
                        error("VOT requires source-audio upload for this video")
                    }
                }

                STATUS_SESSION_REQUIRED -> error("VOT requires Yandex authorization for this video")
                STATUS_FAILED -> error(response.message.ifBlank { "Yandex could not translate this video" })
                else -> error(
                    buildString {
                        append("Unknown VOT status: ").append(response.status)
                        if (response.message.isNotBlank()) append(" (").append(response.message).append(')')
                    }
                )
            }
        }

        error(lastMessage.ifBlank { "Timed out waiting for voice-over translation" })
    }

    private fun getSession(): Session {
        val now = System.currentTimeMillis() / 1000L
        session?.takeIf { it.expiresAtSeconds > now + 10 }?.let { return it }

        val uuid = randomUuid32()
        val body = VotProto.encodeSessionRequest(uuid, "video-translation")
        val responseBytes = requestBinary(
            path = PATH_SESSION,
            body = body,
            method = "POST",
            extraHeaders = mapOf("Vtrans-Signature" to hmacSha256Hex(body)),
        )
        val response = VotProto.decodeSessionResponse(responseBytes)

        return Session(
            uuid = uuid,
            secretKey = response.secretKey,
            expiresAtSeconds = now + response.expires,
        ).also { session = it }
    }

    private fun requestFailedAudio(videoUrl: String) {
        val actualYandexBody = JSONObject()
            .put("video_url", videoUrl)
            .toString()

        val response = requestJson(
            path = PATH_FAIL_AUDIO,
            jsonBody = actualYandexBody,
            method = "PUT",
        )
        val json = JSONObject(response.toString(Charsets.UTF_8))
        if (json.optInt("status", 0) != 1) {
            error("VOT failed-audio fallback was rejected")
        }
    }

    private fun requestAudioFallback(videoUrl: String, translationId: String) {
        require(translationId.isNotBlank()) { "VOT audio fallback did not include translationId" }
        requestFailedAudio(videoUrl)

        val activeSession = getSession()
        val body = VotProto.encodeAudioRequest(
            translationId = translationId,
            url = videoUrl,
            fileId = AUDIO_FALLBACK_FILE_ID,
        )
        requestBinary(
            path = PATH_AUDIO,
            body = body,
            method = "PUT",
            extraHeaders = secureHeaders("Vtrans", activeSession, body, PATH_AUDIO),
        )
    }

    private fun requestBinary(
        path: String,
        body: ByteArray,
        method: String,
        extraHeaders: Map<String, String>,
    ): ByteArray {
        val yandexHeaders = baseHeaders().toMutableMap().apply { putAll(extraHeaders) }
        var lastError: Throwable? = null

        try {
            return executeDirectBinary(path, body, method, yandexHeaders)
        } catch (error: Throwable) {
            lastError = error
        }

        for (worker in workerHosts.distinct()) {
            try {
                return executeWorkerBinary(worker, path, body, method, yandexHeaders)
            } catch (error: Throwable) {
                lastError = error
            }
        }

        throw IllegalStateException(
            "VOT network request failed: ${lastError?.message ?: "no available endpoint"}",
            lastError,
        )
    }

    private fun requestJson(
        path: String,
        jsonBody: String,
        method: String,
    ): ByteArray {
        val yandexHeaders = baseHeaders().toMutableMap().apply {
            this["Accept"] = "application/json"
            this["Content-Type"] = "application/json"
        }
        var lastError: Throwable? = null

        try {
            return executeDirectJson(path, jsonBody, method, yandexHeaders)
        } catch (error: Throwable) {
            lastError = error
        }

        for (worker in workerHosts.distinct()) {
            try {
                return executeWorkerJson(worker, path, jsonBody, method, yandexHeaders)
            } catch (error: Throwable) {
                lastError = error
            }
        }

        throw IllegalStateException(
            "VOT JSON request failed: ${lastError?.message ?: "no available endpoint"}",
            lastError,
        )
    }

    private fun executeDirectBinary(
        path: String,
        body: ByteArray,
        method: String,
        headers: Map<String, String>,
    ): ByteArray {
        val mediaType = PROTOBUF_MEDIA_TYPE.toMediaType()
        val builder = Request.Builder()
            .url("https://$directHost$path")
            .method(method, body.toRequestBody(mediaType))
        headers.forEach { (name, value) -> builder.header(name, value) }
        return execute(builder.build(), "direct Yandex")
    }

    private fun executeDirectJson(
        path: String,
        jsonBody: String,
        method: String,
        headers: Map<String, String>,
    ): ByteArray {
        val mediaType = JSON_MEDIA_TYPE.toMediaType()
        val builder = Request.Builder()
            .url("https://$directHost$path")
            .method(method, jsonBody.toRequestBody(mediaType))
        headers.forEach { (name, value) -> builder.header(name, value) }
        return execute(builder.build(), "direct Yandex")
    }

    private fun executeWorkerBinary(
        worker: String,
        path: String,
        body: ByteArray,
        method: String,
        yandexHeaders: Map<String, String>,
    ): ByteArray {
        val bodyArray = JSONArray()
        body.forEach { bodyArray.put(it.toInt() and 0xff) }
        val wrapper = JSONObject()
            .put("headers", JSONObject(yandexHeaders))
            .put("body", bodyArray)
            .toString()
        return executeWorker(worker, path, wrapper, method, expectJson = false)
    }

    private fun executeWorkerJson(
        worker: String,
        path: String,
        jsonBody: String,
        method: String,
        yandexHeaders: Map<String, String>,
    ): ByteArray {
        val wrapper = JSONObject()
            .put("headers", JSONObject(yandexHeaders))
            .put("body", jsonBody)
            .toString()
        return executeWorker(worker, path, wrapper, method, expectJson = true)
    }

    private fun executeWorker(
        worker: String,
        path: String,
        wrapperJson: String,
        method: String,
        expectJson: Boolean,
    ): ByteArray {
        val mediaType = JSON_MEDIA_TYPE.toMediaType()
        val request = Request.Builder()
            .url("https://$worker$path")
            .method(method, wrapperJson.toRequestBody(mediaType))
            .header("Accept", if (expectJson) "application/json" else PROTOBUF_MEDIA_TYPE)
            .header("Content-Type", JSON_MEDIA_TYPE)
            .build()
        return execute(request, "worker $worker")
    }

    private fun execute(request: Request, label: String): ByteArray {
        http.newCall(request).execute().use { response ->
            val bytes = response.body?.bytes() ?: ByteArray(0)
            if (response.code != 200) {
                val yandexStatus = response.header("X-Yandex-Status")
                val detail = bytes.toString(Charsets.UTF_8).take(180)
                error(
                    buildString {
                        append(label).append(" HTTP ").append(response.code)
                        if (!yandexStatus.isNullOrBlank()) append(" / ").append(yandexStatus)
                        if (detail.isNotBlank()) append(": ").append(detail)
                    }
                )
            }
            if (bytes.isEmpty()) {
                val yandexStatus = response.header("X-Yandex-Status")
                error(
                    buildString {
                        append(label).append(" returned an empty response")
                        if (!yandexStatus.isNullOrBlank()) append(" / ").append(yandexStatus)
                    }
                )
            }
            return bytes
        }
    }

    private fun secureHeaders(
        secType: String,
        session: Session,
        body: ByteArray,
        path: String,
    ): Map<String, String> {
        val token = "${session.uuid}:$path:$COMPONENT_VERSION"
        val tokenSign = hmacSha256Hex(token.toByteArray(Charsets.UTF_8))
        return mapOf(
            "$secType-Signature" to hmacSha256Hex(body),
            "Sec-$secType-Sk" to session.secretKey,
            "Sec-$secType-Token" to "$tokenSign:$token",
        )
    }

    private fun baseHeaders(): Map<String, String> = mapOf(
        "User-Agent" to USER_AGENT,
        "Accept" to PROTOBUF_MEDIA_TYPE,
        "Accept-Language" to "en",
        "Content-Type" to PROTOBUF_MEDIA_TYPE,
        "Pragma" to "no-cache",
        "Cache-Control" to "no-cache",
        "sec-ch-ua" to SEC_CH_UA,
        "sec-ch-ua-full-version-list" to SEC_CH_UA_FULL_VERSION_LIST,
        "Sec-Fetch-Mode" to "no-cors",
    )

    private fun hmacSha256Hex(data: ByteArray): String {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(HMAC_KEY.toByteArray(Charsets.UTF_8), "HmacSHA256"))
        return mac.doFinal(data).joinToString("") { "%02x".format(it.toInt() and 0xff) }
    }

    private fun randomUuid32(): String {
        val random = SecureRandom()
        val alphabet = "0123456789ABCDEF"
        return buildString(32) {
            repeat(32) { append(alphabet[random.nextInt(16)]) }
        }
    }

    private fun buildAudioProxyUrls(url: String): List<String> {
        return runCatching {
            val uri = URI(url)
            if (uri.host != "vtrans.s3-private.mds.yandex.net") return emptyList()
            val marker = "/tts/prod/"
            val path = uri.rawPath ?: return emptyList()
            val index = path.indexOf(marker)
            if (index < 0) return emptyList()
            val fileName = path.substring(index + marker.length)
            AUDIO_PROXY_WORKERS.distinct().map { worker ->
                buildString {
                    append("https://")
                    append(worker)
                    append("/video-translation/audio-proxy/")
                    append(fileName)
                    uri.rawQuery?.let { append('?').append(it) }
                }
            }
        }.getOrElse { emptyList() }
    }

    companion object {
        private const val DEFAULT_DIRECT_HOST = "api.browser.yandex.ru"
        private val DEFAULT_WORKERS = listOf(
            "vot-worker.eu.cc",
            "vot-worker.vtrans.eu.cc",
            "vot-worker.toil.cc",
            "vot.deno.dev",
            "vot-new.toil-dump.workers.dev",
        )
        private val AUDIO_PROXY_WORKERS = listOf(
            "vot-worker.eu.cc",
            "vot-worker.vtrans.eu.cc",
            "vot-worker.toil.cc",
            "vot.deno.dev",
        )

        private const val PROTOBUF_MEDIA_TYPE = "application/x-protobuf"
        private const val JSON_MEDIA_TYPE = "application/json; charset=utf-8"
        private const val USER_AGENT =
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 YaBrowser/26.6.0.0 Safari/537.36"
        private const val COMPONENT_VERSION = "26.6.4.760"
        private const val HMAC_KEY = "bt8xH3VOlb4mqf0nqAibnDOoiPlXsisf"
        private const val DEFAULT_DURATION = 310.0

        private const val PATH_SESSION = "/session/create"
        private const val PATH_TRANSLATE = "/video-translation/translate"
        private const val PATH_FAIL_AUDIO = "/video-translation/fail-audio-js"
        private const val PATH_AUDIO = "/video-translation/audio"
        private const val AUDIO_FALLBACK_FILE_ID =
            "web_api_get_all_generating_urls_data_from_iframe"

        private const val SEC_CH_UA =
            "\"Chromium\";v=\"148\", \"YaBrowser\";v=\"26.6\", \"Not?A_Brand\";v=\"99\", \"Yowser\";v=\"2.5\""
        private const val SEC_CH_UA_FULL_VERSION_LIST =
            "\"Chromium\";v=\"148.0.7778.760\", \"YaBrowser\";v=\"26.6.4.760\", \"Not?A_Brand\";v=\"99.0.0.0\", \"Yowser\";v=\"2.5\""

        private const val STATUS_FAILED = 0
        private const val STATUS_FINISHED = 1
        private const val STATUS_WAITING = 2
        private const val STATUS_LONG_WAITING = 3
        private const val STATUS_PART_CONTENT = 5
        private const val STATUS_AUDIO_REQUESTED = 6
        private const val STATUS_SESSION_REQUIRED = 7

        private const val MAX_INITIAL_WAIT_SEC = 180
        private const val LONG_WAIT_MS = 120_000L
        private const val RETRY_INTERVAL_MS = 30_000L
        private const val MAX_TRANSLATION_ATTEMPTS = 40
    }
}
