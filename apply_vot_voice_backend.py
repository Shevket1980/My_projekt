#!/usr/bin/env python3
from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit('Usage: python apply_vot_voice_backend.py /path/to/LibreTube')
root = Path(sys.argv[1]).resolve()
api = root / 'app/src/main/java/com/github/libretube/vot/VotApiClient.kt'
controller = root / 'app/src/main/java/com/github/libretube/vot/VotAudioController.kt'
for p in (api, controller):
    if not p.exists():
        raise SystemExit(f'Missing expected file: {p}')

s = api.read_text(encoding='utf-8')

def replace_once(text, old, new, name):
    if new in text:
        return text
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'{name} marker mismatch: {count}')
    return text.replace(old, new, 1)

marker = ''') {
    data class TranslationResult('''
replacement = ''') {
    enum class VoiceMode { STANDARD, LIVELY }

    data class TranslationResult('''
s = replace_once(s, marker, replacement, 'VoiceMode enum')

old = '''    data class TranslationResult(
        val audioUrl: String,
        val fallbackAudioUrls: List<String> = emptyList(),
        val detectedLanguage: String? = null,
    )'''
new = '''    data class TranslationResult(
        val audioUrl: String,
        val fallbackAudioUrls: List<String> = emptyList(),
        val detectedLanguage: String? = null,
        val requestedVoiceMode: VoiceMode = VoiceMode.STANDARD,
        val usedVoiceMode: VoiceMode = VoiceMode.STANDARD,
    )'''
s = replace_once(s, old, new, 'TranslationResult')

old = '''    data class TranslationProgress(
        val remainingSeconds: Int? = null,
        val delayed: Boolean = false,
        val serverMessage: String? = null,
    )'''
new = '''    data class TranslationProgress(
        val remainingSeconds: Int? = null,
        val delayed: Boolean = false,
        val serverMessage: String? = null,
        val voiceMode: VoiceMode = VoiceMode.STANDARD,
        val fallbackToStandard: Boolean = false,
    )'''
s = replace_once(s, old, new, 'TranslationProgress')

old = '''        targetLanguage: String = "ru",
        title: String = "",
        onProgress: (TranslationProgress) -> Unit = {},'''
new = '''        targetLanguage: String = "ru",
        title: String = "",
        voiceMode: VoiceMode = VoiceMode.STANDARD,
        oauthToken: String? = null,
        onProgress: (TranslationProgress) -> Unit = {},'''
s = replace_once(s, old, new, 'requestTranslation signature')

old = '''        var sentAudioFallback = false
        var lastMessage = ""
        var retryAttempt = 0
        var firstRequest = true

        onProgress(TranslationProgress())

        repeat(MAX_TRANSLATION_ATTEMPTS) {'''
new = '''        val requestedVoiceMode = voiceMode
        var activeVoiceMode = voiceMode
        var effectiveSourceLanguage = sourceLanguage
        var sentAudioFallback = false
        var lastMessage = ""
        var retryAttempt = 0
        var firstRequest = true
        var fellBackToStandard = false

        if (activeVoiceMode == VoiceMode.LIVELY && targetLanguage == "ru" && effectiveSourceLanguage == "auto") {
            effectiveSourceLanguage = detectLanguageFromTitle(title) ?: "auto"
        }
        if (activeVoiceMode == VoiceMode.LIVELY && (targetLanguage != "ru" || effectiveSourceLanguage == "auto")) {
            activeVoiceMode = VoiceMode.STANDARD
            fellBackToStandard = true
        }

        onProgress(
            TranslationProgress(
                voiceMode = activeVoiceMode,
                fallbackToStandard = fellBackToStandard,
            )
        )

        repeat(MAX_TRANSLATION_ATTEMPTS) {'''
s = replace_once(s, old, new, 'initial lively state')

old = '''        repeat(MAX_TRANSLATION_ATTEMPTS) {
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
            )'''
new = '''        repeat(MAX_TRANSLATION_ATTEMPTS) {
            val useLivelyVoice = activeVoiceMode == VoiceMode.LIVELY
            val activeSession = getSession()
            val body = VotProto.encodeTranslationRequest(
                url = youtubeUrl,
                firstRequest = firstRequest,
                duration = if (durationSeconds > 0.0) durationSeconds else DEFAULT_DURATION,
                language = effectiveSourceLanguage,
                responseLanguage = targetLanguage,
                videoTitle = title,
                useLivelyVoice = useLivelyVoice,
            )

            val headers = secureHeaders("Vtrans", activeSession, body, PATH_TRANSLATE).toMutableMap()
            if (useLivelyVoice && !oauthToken.isNullOrBlank()) {
                headers["Authorization"] = "OAuth $oauthToken"
            }

            val responseBytes = requestBinary(
                path = PATH_TRANSLATE,
                body = body,
                method = "POST",
                extraHeaders = headers,
            )'''
s = replace_once(s, old, new, 'translation request')

old = '''                    return@withContext TranslationResult(
                        audioUrl = response.url,
                        fallbackAudioUrls = buildAudioProxyUrls(response.url),
                        detectedLanguage = response.language.takeIf { it.isNotBlank() },
                    )'''
new = '''                    val usedVoiceMode = if (response.isLivelyVoice) VoiceMode.LIVELY else VoiceMode.STANDARD
                    return@withContext TranslationResult(
                        audioUrl = response.url,
                        fallbackAudioUrls = buildAudioProxyUrls(response.url),
                        detectedLanguage = response.language.takeIf { it.isNotBlank() },
                        requestedVoiceMode = requestedVoiceMode,
                        usedVoiceMode = usedVoiceMode,
                    )'''
s = replace_once(s, old, new, 'finished result')

old = '''                        serverRemainingSeconds = response.remainingTime,
                        serverMessage = response.message,
                        onProgress = onProgress,'''
new = '''                        serverRemainingSeconds = response.remainingTime,
                        serverMessage = response.message,
                        voiceMode = activeVoiceMode,
                        fallbackToStandard = fellBackToStandard,
                        onProgress = onProgress,'''
s = replace_once(s, old, new, 'waiting progress args')

old = '''                        TranslationProgress(
                            remainingSeconds = response.remainingTime.takeIf { it > 0 },
                            serverMessage = response.message.takeIf { it.isNotBlank() },
                        )'''
new = '''                        TranslationProgress(
                            remainingSeconds = response.remainingTime.takeIf { it > 0 },
                            serverMessage = response.message.takeIf { it.isNotBlank() },
                            voiceMode = activeVoiceMode,
                            fallbackToStandard = fellBackToStandard,
                        )'''
s = replace_once(s, old, new, 'audio requested progress')

old = '''                STATUS_SESSION_REQUIRED -> error("VOT requires Yandex authorization for this video")
                STATUS_FAILED -> error(response.message.ifBlank { "Yandex could not translate this video" })'''
new = '''                STATUS_SESSION_REQUIRED -> {
                    if (activeVoiceMode == VoiceMode.LIVELY) {
                        activeVoiceMode = VoiceMode.STANDARD
                        fellBackToStandard = true
                        firstRequest = true
                        retryAttempt = 0
                        sentAudioFallback = false
                        onProgress(
                            TranslationProgress(
                                voiceMode = VoiceMode.STANDARD,
                                fallbackToStandard = true,
                                serverMessage = response.message.takeIf { it.isNotBlank() },
                            )
                        )
                    } else {
                        error("VOT requires Yandex authorization for this video")
                    }
                }

                STATUS_FAILED -> {
                    if (activeVoiceMode == VoiceMode.LIVELY && isLivelyUnavailableMessage(response.message)) {
                        activeVoiceMode = VoiceMode.STANDARD
                        fellBackToStandard = true
                        firstRequest = true
                        retryAttempt = 0
                        sentAudioFallback = false
                        onProgress(
                            TranslationProgress(
                                voiceMode = VoiceMode.STANDARD,
                                fallbackToStandard = true,
                                serverMessage = response.message.takeIf { it.isNotBlank() },
                            )
                        )
                    } else {
                        error(response.message.ifBlank { "Yandex could not translate this video" })
                    }
                }'''
s = replace_once(s, old, new, 'lively fallback statuses')

marker = '''    private suspend fun delayWithProgress('''
helpers = '''    private fun isLivelyUnavailableMessage(message: String): Boolean {
        val normalized = message.lowercase()
        return normalized.contains("обычная озвучка") ||
            normalized.contains("lively") ||
            normalized.contains("жив") ||
            normalized.contains("authorization") ||
            normalized.contains("авториз")
    }

    private fun detectLanguageFromTitle(title: String): String? {
        val text = title.trim()
        if (text.length < MIN_DETECT_TEXT_LENGTH) return null
        return runCatching {
            val encoded = java.net.URLEncoder.encode(text, Charsets.UTF_8.name())
            val request = Request.Builder()
                .url("$DETECT_API_URL/detect?text=$encoded&service=yandexbrowser")
                .get()
                .build()
            http.newCall(request).execute().use { response ->
                if (!response.isSuccessful) return@use null
                val json = JSONObject(response.body?.string().orEmpty())
                json.optString("lang").takeIf { it.isNotBlank() && it != "auto" }
            }
        }.getOrNull()
    }

'''
if helpers not in s:
    if s.count(marker) != 1:
        raise SystemExit(f'lively helper insertion marker mismatch: {s.count(marker)}')
    s = s.replace(marker, helpers + marker, 1)

old = '''    private suspend fun delayWithProgress(
        waitMs: Long,
        serverRemainingSeconds: Int,
        serverMessage: String,
        onProgress: (TranslationProgress) -> Unit,
    )'''
new = '''    private suspend fun delayWithProgress(
        waitMs: Long,
        serverRemainingSeconds: Int,
        serverMessage: String,
        voiceMode: VoiceMode,
        fallbackToStandard: Boolean,
        onProgress: (TranslationProgress) -> Unit,
    )'''
s = replace_once(s, old, new, 'delayWithProgress signature')

old = '''                TranslationProgress(
                    remainingSeconds = remaining,
                    delayed = knownEta != null && remaining == 0,
                    serverMessage = serverMessage.takeIf { it.isNotBlank() },
                )'''
new = '''                TranslationProgress(
                    remainingSeconds = remaining,
                    delayed = knownEta != null && remaining == 0,
                    serverMessage = serverMessage.takeIf { it.isNotBlank() },
                    voiceMode = voiceMode,
                    fallbackToStandard = fallbackToStandard,
                )'''
s = replace_once(s, old, new, 'countdown progress')

old = '''        private const val DEFAULT_DURATION = 310.0

        private const val PATH_SESSION'''
new = '''        private const val DEFAULT_DURATION = 310.0
        private const val MIN_DETECT_TEXT_LENGTH = 35
        private const val DETECT_API_URL = "https://translate-backend.transly.eu.cc/v2"

        private const val PATH_SESSION'''
s = replace_once(s, old, new, 'lively constants')
api.write_text(s, encoding='utf-8')

s = controller.read_text(encoding='utf-8')
old = '''        sourceLanguage: String = "auto",
        targetLanguage: String = "ru",
        onProgress: (VotApiClient.TranslationProgress) -> Unit = {},'''
new = '''        sourceLanguage: String = "auto",
        targetLanguage: String = "ru",
        title: String = "",
        voiceMode: VotApiClient.VoiceMode = VotApiClient.VoiceMode.STANDARD,
        oauthToken: String? = null,
        onProgress: (VotApiClient.TranslationProgress) -> Unit = {},'''
s = replace_once(s, old, new, 'controller signature')

old = '''            sourceLanguage = sourceLanguage,
            targetLanguage = targetLanguage,
            onProgress = { progress ->'''
new = '''            sourceLanguage = sourceLanguage,
            targetLanguage = targetLanguage,
            title = title,
            voiceMode = voiceMode,
            oauthToken = oauthToken,
            onProgress = { progress ->'''
s = replace_once(s, old, new, 'controller request args')
controller.write_text(s, encoding='utf-8')

print('VOT r8 backend applied: standard/lively protocol, server truth, fallback, title language detection.')
