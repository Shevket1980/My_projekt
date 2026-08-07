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

class VotApiClient(
    private val workerHost: String = DEFAULT_WORKER,
) {
    data class TranslationResult(
        val audioUrl: String,
        val fallbackAudioUrl: String? = null,
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

        repeat(MAX_TRANSLATION_ATTEMPTS) {
            val activeSession = getSession()
            val body = VotProto.encodeTranslationRequest(
                url = youtubeUrl,
                firstRequest = true,
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
                    if (response.url.isBlank()) error("VOT returned a finished status without an audio URL")
                    return@withContext TranslationResult(
                        audioUrl = response.url,
                        fallbackAudioUrl = buildAudioProxyUrl(response.url),
                        detectedLanguage = response.language.takeIf { it.isNotBlank() },
                    )
                }

                STATUS_WAITING, STATUS_LONG_WAITING -> {
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
                    } else {
                        error("VOT requires source-audio upload for this video; native upload is not implemented")
                    }
                }

                STATUS_SESSION_REQUIRED -> error("VOT requires Yandex authorization for this video")
                STATUS_FAILED -> error(response.message.ifBlank { "Yandex could not translate this video" })
                else -> error("Unknown VOT status: ${response.status}")
            }
        }

        error(lastMessage.ifBlank { "Timed out waiting for voice-over translation" })
    }

    private fun getSession(): Session {
        val now = System.currentTimeMillis() / 1000L
        session?.takeIf { it.expiresAtSeconds > now + 10 }?.let { return it }

        val uuid = randomUuid32()
        val body = VotProto.encodeSessionRequest(uuid, "video-translation")
        val response = VotProto.decodeSessionResponse(
            requestBinary(
                path = PATH_SESSION,
                body = body,
                method = "POST",
                extraHeaders = mapOf("Vtrans-Signature" to hmacSha256Hex(body)),
            )
        )

        return Session(
            uuid = uuid,
            secretKey = response.secretKey,
            expiresAtSeconds = now + response.expires,
        ).also { session = it }
    }

    private fun requestFailedAudio(videoUrl: String) {
        val actualYandexBody = JSONObject().put("video_url", videoUrl).toString()
        val nestedHeaders = baseHeaders().toMutableMap().apply {
            this["Accept"] = "application/json"
            this["Content-Type"] = "application/json"
        }
        val wrapper = JSONObject()
            .put("headers", JSONObject(nestedHeaders))
            .put("body", actualYandexBody)
            .toString()
        val response = executeWorker(PATH_FAIL_AUDIO, wrapper, "PUT", expectBinary = false)
        val json = JSONObject(response.toString(Charsets.UTF_8))
        if (json.optInt("status", 0) != 1) error("VOT failed-audio fallback was rejected")
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
        val headers = baseHeaders().toMutableMap().apply { putAll(extraHeaders) }
        val bodyArray = JSONArray()
        body.forEach { bodyArray.put(it.toInt() and 0xff) }
        val wrapper = JSONObject()
            .put("headers", JSONObject(headers))
            .put("body", bodyArray)
            .toString()
        return executeWorker(path, wrapper, method, expectBinary = true)
    }

    private fun executeWorker(
        path: String,
        wrapperJson: String,
        method: String,
        expectBinary: Boolean,
    ): ByteArray {
        val mediaType = "application/json; charset=utf-8".toMediaType()
        val request = Request.Builder()
            .url("https://$workerHost$path")
            .method(method, wrapperJson.toRequestBody(mediaType))
            .header("Accept", if (expectBinary) "application/x-protobuf" else "application/json")
            .header("Content-Type", "application/json")
            .build()
        http.newCall(request).execute().use { response ->
            val bytes = response.body?.bytes() ?: ByteArray(0)
            if (!response.isSuccessful) {
                error("VOT worker HTTP ${response.code}: ${bytes.toString(Charsets.UTF_8).take(200)}")
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
        "Accept" to "application/x-protobuf",
        "Accept-Language" to "en",
        "Content-Type" to "application/x-protobuf",
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
        return buildString(32) { repeat(32) { append(alphabet[random.nextInt(16)]) } }
    }

    private fun buildAudioProxyUrl(url: String): String? {
        return runCatching {
            val uri = URI(url)
            if (uri.host != "vtrans.s3-private.mds.yandex.net") return null
            val marker = "/tts/prod/"
            val path = uri.rawPath ?: return null
            val index = path.indexOf(marker)
            if (index < 0) return null
            val fileName = path.substring(index + marker.length)
            buildString {
                append("https://")
                append(AUDIO_PROXY_WORKER)
                append("/video-translation/audio-proxy/")
                append(fileName)
                uri.rawQuery?.let { append('?').append(it) }
            }
        }.getOrNull()
    }

    companion object {
        private const val DEFAULT_WORKER = "vot-worker.toil.cc"
        private const val AUDIO_PROXY_WORKER = "vot-worker.eu.cc"
        private const val USER_AGENT =
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 YaBrowser/26.6.0.0 Safari/537.36"
        private const val COMPONENT_VERSION = "26.6.4.760"
        private const val HMAC_KEY = "bt8xH3VOlb4mqf0nqAibnDOoiPlXsisf"
        private const val DEFAULT_DURATION = 310.0
        private const val PATH_SESSION = "/session/create"
        private const val PATH_TRANSLATE = "/video-translation/translate"
        private const val PATH_FAIL_AUDIO = "/video-translation/fail-audio-js"
        private const val PATH_AUDIO = "/video-translation/audio"
        private const val AUDIO_FALLBACK_FILE_ID = "web_api_get_all_generating_urls_data_from_iframe"
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
