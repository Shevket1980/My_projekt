#!/usr/bin/env python3
from pathlib import Path
import re
import sys

if len(sys.argv) != 2:
    raise SystemExit("Usage: python apply_vot_progress_r7.py /path/to/LibreTube")
root = Path(sys.argv[1]).resolve()
main = root / "app/src/main"
api = main / "java/com/github/libretube/vot/VotApiClient.kt"
controller = main / "java/com/github/libretube/vot/VotAudioController.kt"
player = main / "java/com/github/libretube/ui/views/CustomExoPlayerView.kt"
layout = main / "res/layout/exo_styled_player_control_view.xml"
strings_en = main / "res/values/vot_strings.xml"
strings_ru = main / "res/values-ru/vot_strings.xml"
for p in [api, controller, player, layout, strings_en, strings_ru]:
    if not p.exists():
        raise SystemExit(f"Missing expected file: {p}")

s = api.read_text(encoding="utf-8")
if "data class TranslationProgress(" not in s:
    old = '''    data class TranslationResult(\n        val audioUrl: String,\n        val fallbackAudioUrls: List<String> = emptyList(),\n        val detectedLanguage: String? = null,\n    )\n'''
    new = old + '''\n    data class TranslationProgress(\n        val remainingSeconds: Int? = null,\n        val delayed: Boolean = false,\n        val serverMessage: String? = null,\n    )\n'''
    if s.count(old) != 1: raise SystemExit("TranslationResult marker mismatch")
    s = s.replace(old, new, 1)
    old = '''        targetLanguage: String = "ru",\n        title: String = "",\n    ): TranslationResult = withContext(Dispatchers.IO) {'''
    new = '''        targetLanguage: String = "ru",\n        title: String = "",\n        onProgress: (TranslationProgress) -> Unit = {},\n    ): TranslationResult = withContext(Dispatchers.IO) {'''
    if s.count(old) != 1: raise SystemExit("requestTranslation signature mismatch")
    s = s.replace(old, new, 1)
    old = '''        var retryAttempt = 0\n        var firstRequest = true\n\n        repeat(MAX_TRANSLATION_ATTEMPTS) {'''
    new = '''        var retryAttempt = 0\n        var firstRequest = true\n\n        onProgress(TranslationProgress())\n\n        repeat(MAX_TRANSLATION_ATTEMPTS) {'''
    if s.count(old) != 1: raise SystemExit("initial progress marker mismatch")
    s = s.replace(old, new, 1)
    old = '''                    retryAttempt += 1\n                    delay(waitMs)\n                }\n\n                STATUS_AUDIO_REQUESTED -> {'''
    new = '''                    retryAttempt += 1\n                    delayWithProgress(\n                        waitMs = waitMs,\n                        serverRemainingSeconds = response.remainingTime,\n                        serverMessage = response.message,\n                        onProgress = onProgress,\n                    )\n                }\n\n                STATUS_AUDIO_REQUESTED -> {'''
    if s.count(old) != 1: raise SystemExit("waiting delay marker mismatch")
    s = s.replace(old, new, 1)
    old = '''                STATUS_AUDIO_REQUESTED -> {\n                    if (!sentAudioFallback && youtubeUrl.startsWith("https://youtu.be/")) {'''
    new = '''                STATUS_AUDIO_REQUESTED -> {\n                    onProgress(\n                        TranslationProgress(\n                            remainingSeconds = response.remainingTime.takeIf { it > 0 },\n                            serverMessage = response.message.takeIf { it.isNotBlank() },\n                        )\n                    )\n                    if (!sentAudioFallback && youtubeUrl.startsWith("https://youtu.be/")) {'''
    if s.count(old) != 1: raise SystemExit("audio requested marker mismatch")
    s = s.replace(old, new, 1)
    marker = '''    private fun getSession(): Session {'''
    helper = '''    private suspend fun delayWithProgress(\n        waitMs: Long,\n        serverRemainingSeconds: Int,\n        serverMessage: String,\n        onProgress: (TranslationProgress) -> Unit,\n    ) {\n        var elapsedMs = 0L\n        val knownEta = serverRemainingSeconds.takeIf { it > 0 }\n        while (elapsedMs < waitMs) {\n            val elapsedSeconds = (elapsedMs / 1000L).toInt()\n            val remaining = knownEta?.let { (it - elapsedSeconds).coerceAtLeast(0) }\n            onProgress(\n                TranslationProgress(\n                    remainingSeconds = remaining,\n                    delayed = knownEta != null && remaining == 0,\n                    serverMessage = serverMessage.takeIf { it.isNotBlank() },\n                )\n            )\n            val sliceMs = minOf(1000L, waitMs - elapsedMs)\n            delay(sliceMs)\n            elapsedMs += sliceMs\n        }\n    }\n\n'''
    if s.count(marker) != 1: raise SystemExit("getSession marker mismatch")
    s = s.replace(marker, helper + marker, 1)
    api.write_text(s, encoding="utf-8")

s = controller.read_text(encoding="utf-8")
if "requestGeneration: Long" not in s:
    old = '''    private var translatedPlayer: ExoPlayer? = null\n    private var originalVolume: Float? = null\n'''
    new = '''    private var translatedPlayer: ExoPlayer? = null\n    private var originalVolume: Float? = null\n    private var requestGeneration: Long = 0L\n'''
    if s.count(old) != 1: raise SystemExit("controller field marker mismatch")
    s = s.replace(old, new, 1)
    old = '''        sourceLanguage: String = "auto",\n        targetLanguage: String = "ru",\n    ): VotApiClient.TranslationResult {'''
    new = '''        sourceLanguage: String = "auto",\n        targetLanguage: String = "ru",\n        onProgress: (VotApiClient.TranslationProgress) -> Unit = {},\n    ): VotApiClient.TranslationResult {'''
    if s.count(old) != 1: raise SystemExit("controller enable signature mismatch")
    s = s.replace(old, new, 1)
    old = '''        release()\n\n        val result = api.requestTranslation('''
    new = '''        release()\n        val progressGeneration = requestGeneration\n\n        val result = api.requestTranslation('''
    if s.count(old) != 1: raise SystemExit("controller generation marker mismatch")
    s = s.replace(old, new, 1)
    old = '''            sourceLanguage = sourceLanguage,\n            targetLanguage = targetLanguage,\n        )'''
    new = '''            sourceLanguage = sourceLanguage,\n            targetLanguage = targetLanguage,\n            onProgress = { progress ->\n                handler.post {\n                    if (progressGeneration == requestGeneration) onProgress(progress)\n                }\n            },\n        )'''
    if s.count(old) != 1: raise SystemExit("controller API marker mismatch")
    s = s.replace(old, new, 1)
    old = '''    fun release() {\n        handler.removeCallbacks(driftSync)'''
    new = '''    fun release() {\n        requestGeneration += 1\n        handler.removeCallbacks(driftSync)'''
    if s.count(old) != 1: raise SystemExit("controller release marker mismatch")
    s = s.replace(old, new, 1)
    controller.write_text(s, encoding="utf-8")

layout_text = layout.read_text(encoding="utf-8")
if '@+id/vot_status' not in layout_text:
    pattern = re.compile(r'(?m)^(        </LinearLayout>)\s*\n(    </LinearLayout>)\s*\n(    <LinearLayout\n        android:id="@id/exo_center_controls")')
    status = '''        <TextView\n            android:id="@+id/vot_status"\n            android:layout_width="wrap_content"\n            android:layout_height="wrap_content"\n            android:layout_gravity="end"\n            android:layout_marginEnd="8dp"\n            android:layout_marginTop="2dp"\n            android:background="#B3000000"\n            android:ellipsize="end"\n            android:maxLines="1"\n            android:paddingHorizontal="8dp"\n            android:paddingVertical="4dp"\n            android:textColor="@android:color/white"\n            android:textSize="13sp"\n            android:visibility="gone" />\n'''
    def repl(m): return m.group(1) + "\n\n" + status + "\n" + m.group(2) + "\n\n" + m.group(3)
    layout_text, count = pattern.subn(repl, layout_text, count=1)
    if count != 1: raise SystemExit(f"top bar insertion mismatch: {count}")
    layout.write_text(layout_text, encoding="utf-8")

s = player.read_text(encoding="utf-8")
if "private fun showVotProgress(" not in s:
    marker = '    private fun toggleVotTranslation(player: Player) {'
    helpers = r'''    private fun showVotProgress(progress: com.github.libretube.vot.VotApiClient.TranslationProgress) {
        binding.votStatus.visibility = android.view.View.VISIBLE
        binding.votStatus.text = when {
            progress.delayed -> context.getString(R.string.vot_translation_delayed)
            progress.remainingSeconds != null && progress.remainingSeconds > 0 -> context.getString(
                R.string.vot_translation_eta,
                formatVotEta(progress.remainingSeconds),
            )
            else -> context.getString(R.string.vot_translation_processing)
        }
    }

    private fun hideVotProgress() {
        binding.votStatus.visibility = android.view.View.GONE
        binding.votStatus.text = ""
    }

    private fun formatVotEta(totalSeconds: Int): String {
        val safeSeconds = totalSeconds.coerceAtLeast(0)
        val hours = safeSeconds / 3600
        val minutes = (safeSeconds % 3600) / 60
        val seconds = safeSeconds % 60
        val secondsText = seconds.toString().padStart(2, '0')
        return if (hours > 0) {
            val minutesText = minutes.toString().padStart(2, '0')
            "$hours:$minutesText:$secondsText"
        } else {
            "$minutes:$secondsText"
        }
    }

'''
    if s.count(marker) != 1: raise SystemExit("player toggle marker mismatch")
    s = s.replace(marker, helpers + marker, 1)
    old = '''        Toast.makeText(context, R.string.vot_requesting_translation, Toast.LENGTH_LONG).show()\n\n        val durationSeconds = player.duration'''
    new = '''        Toast.makeText(context, R.string.vot_requesting_translation, Toast.LENGTH_SHORT).show()\n        binding.votStatus.visibility = android.view.View.VISIBLE\n        binding.votStatus.setText(R.string.vot_translation_processing)\n\n        val durationSeconds = player.duration'''
    if s.count(old) != 1: raise SystemExit("requesting toast marker mismatch")
    s = s.replace(old, new, 1)
    old = '''                    sourceLanguage = "auto",\n                    targetLanguage = "ru",\n                )'''
    new = '''                    sourceLanguage = "auto",\n                    targetLanguage = "ru",\n                    onProgress = { progress ->\n                        if (votAudioController === controller) showVotProgress(progress)\n                    },\n                )'''
    if s.count(old) != 1: raise SystemExit("enable call marker mismatch")
    s = s.replace(old, new, 1)
    old = '''            }.onSuccess {\n                votJob = null\n                binding.votToggle.alpha = 1f'''
    new = '''            }.onSuccess {\n                votJob = null\n                hideVotProgress()\n                binding.votToggle.alpha = 1f'''
    if s.count(old) != 1: raise SystemExit("success marker mismatch")
    s = s.replace(old, new, 1)
    old = '''            }.onFailure { error ->\n                votJob = null\n                controller.release()'''
    new = '''            }.onFailure { error ->\n                votJob = null\n                hideVotProgress()\n                controller.release()'''
    if s.count(old) != 1: raise SystemExit("failure marker mismatch")
    s = s.replace(old, new, 1)
    old = '''        votAudioController?.release()\n        votAudioController = null\n        binding.votToggle.alpha = 0.72f'''
    new = '''        votAudioController?.release()\n        votAudioController = null\n        hideVotProgress()\n        binding.votToggle.alpha = 0.72f'''
    if s.count(old) != 1: raise SystemExit("stop marker mismatch")
    s = s.replace(old, new, 1)
    player.write_text(s, encoding="utf-8")

strings_ru.write_text('''<?xml version="1.0" encoding="utf-8"?>\n<resources>\n    <string name="vot_voice_translation">Голосовой перевод</string>\n    <string name="vot_requesting_translation">Запрашиваю голосовой перевод…</string>\n    <string name="vot_translation_processing">Видео переводится…</string>\n    <string name="vot_translation_eta">Видео переводится • Осталось %1$s</string>\n    <string name="vot_translation_delayed">Видео переводится • Перевод немного задерживается</string>\n    <string name="vot_translation_enabled">Голосовой перевод включён</string>\n    <string name="vot_translation_disabled">Голосовой перевод выключен</string>\n    <string name="vot_translation_failed">Ошибка голосового перевода: %1$s</string>\n    <string name="vot_live_not_supported">Перевод прямых эфиров в этой сборке пока не включён</string>\n</resources>\n''', encoding='utf-8')
strings_en.write_text('''<?xml version="1.0" encoding="utf-8"?>\n<resources>\n    <string name="vot_voice_translation">Voice translation</string>\n    <string name="vot_requesting_translation">Requesting voice translation…</string>\n    <string name="vot_translation_processing">Video is being translated…</string>\n    <string name="vot_translation_eta">Video is being translated • %1$s remaining</string>\n    <string name="vot_translation_delayed">Video is being translated • Translation is slightly delayed</string>\n    <string name="vot_translation_enabled">Voice translation enabled</string>\n    <string name="vot_translation_disabled">Voice translation disabled</string>\n    <string name="vot_translation_failed">Voice translation failed: %1$s</string>\n    <string name="vot_live_not_supported">Voice translation for live streams is not enabled in this build</string>\n</resources>\n''', encoding='utf-8')

print("LibreTube VOT r7 progress applied: live server ETA countdown + delayed state.")
