#!/usr/bin/env python3
from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit("Usage: python apply_vot_voice_modes.py /path/to/LibreTube")

root = Path(sys.argv[1]).resolve()
kt = root / "app/src/main/java/com/github/libretube/ui/views/CustomExoPlayerView.kt"
callback = root / "app/src/main/java/com/github/libretube/ui/interfaces/CustomPlayerCallback.kt"
fragment = root / "app/src/main/java/com/github/libretube/ui/fragments/PlayerFragment.kt"
for path in (kt, callback, fragment):
    if not path.exists():
        raise SystemExit(f"Expected LibreTube file not found: {path}")

# Expose the current title so VOT can use the same metadata-based language detection
# approach as the original extension before requesting lively voices.
cb = callback.read_text(encoding="utf-8")
if "fun getVideoTitle(): String" not in cb:
    marker = "    fun getVideoId(): String\n"
    if cb.count(marker) != 1:
        raise SystemExit("CustomPlayerCallback getVideoId marker mismatch")
    cb = cb.replace(marker, marker + "    fun getVideoTitle(): String\n", 1)
callback.write_text(cb, encoding="utf-8")

pf = fragment.read_text(encoding="utf-8")
if "override fun getVideoTitle(): String" not in pf:
    marker = '''    override fun getVideoId(): String {
        return videoId
    }
'''
    addition = marker + '''
    override fun getVideoTitle(): String {
        return _binding?.titleTextView?.text?.toString().orEmpty()
    }
'''
    if pf.count(marker) != 1:
        raise SystemExit("PlayerFragment getVideoId marker mismatch")
    pf = pf.replace(marker, addition, 1)
fragment.write_text(pf, encoding="utf-8")

text = kt.read_text(encoding="utf-8")
old_progress = '''    private fun showVotProgress(progress: com.github.libretube.vot.VotApiClient.TranslationProgress) {
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
'''
new_progress = '''    private fun showVotProgress(progress: com.github.libretube.vot.VotApiClient.TranslationProgress) {
        binding.votStatus.visibility = android.view.View.VISIBLE
        val lively = progress.voiceMode == com.github.libretube.vot.VotApiClient.VoiceMode.LIVELY
        binding.votStatus.text = when {
            progress.delayed -> context.getString(R.string.vot_translation_delayed)
            progress.remainingSeconds != null && progress.remainingSeconds > 0 -> context.getString(
                if (lively) R.string.vot_translation_eta_lively else R.string.vot_translation_eta_standard,
                formatVotEta(progress.remainingSeconds),
            )
            else -> context.getString(
                if (lively) R.string.vot_processing_lively else R.string.vot_processing_standard,
            )
        }
    }
'''
if new_progress not in text:
    if text.count(old_progress) != 1:
        raise SystemExit("showVotProgress marker mismatch")
    text = text.replace(old_progress, new_progress, 1)

start = text.find("    private fun toggleVotTranslation(player: Player) {")
stop = text.find("    private fun stopVotTranslation(showToast: Boolean) {", start)
if start < 0 or stop < 0:
    raise SystemExit("VOT toggle/stop helper markers not found")
if "private fun showVotVoiceModeDialog(player: Player)" not in text:
    replacement = r'''    private fun toggleVotTranslation(player: Player) {
        if (votJob?.isActive == true || votAudioController?.isActive == true) {
            stopVotTranslation(showToast = true)
            return
        }

        if (playerCallback.isVideoLive()) {
            Toast.makeText(context, R.string.vot_live_not_supported, Toast.LENGTH_SHORT).show()
            return
        }

        showVotVoiceModeDialog(player)
    }

    private fun showVotVoiceModeDialog(player: Player) {
        val preferences = context.getSharedPreferences("libretube_vot", android.content.Context.MODE_PRIVATE)
        var livelySelected = preferences.getBoolean("lively_voice", false)
        val items = arrayOf(
            context.getString(R.string.vot_standard_voices_title) + "\n" + context.getString(R.string.vot_standard_voices_subtitle),
            context.getString(R.string.vot_lively_voices_title) + "\n" + context.getString(R.string.vot_lively_voices_subtitle),
        )

        androidx.appcompat.app.AlertDialog.Builder(context)
            .setTitle(R.string.vot_voice_mode_title)
            .setSingleChoiceItems(items, if (livelySelected) 1 else 0) { _, which ->
                livelySelected = which == 1
            }
            .setPositiveButton(R.string.vot_start_translation) { _, _ ->
                preferences.edit().putBoolean("lively_voice", livelySelected).apply()
                startVotTranslation(player, livelySelected)
            }
            .setNegativeButton(android.R.string.cancel, null)
            .show()
    }

    private fun startVotTranslation(player: Player, useLivelyVoice: Boolean) {
        val controller = VotAudioController(context, player)
        votAudioController = controller
        binding.votToggle.alpha = 1f
        binding.votToggle.imageTintList = android.content.res.ColorStateList.valueOf(android.graphics.Color.WHITE)
        Toast.makeText(context, R.string.vot_requesting_translation, Toast.LENGTH_SHORT).show()
        binding.votStatus.visibility = android.view.View.VISIBLE
        binding.votStatus.setText(
            if (useLivelyVoice) R.string.vot_processing_lively else R.string.vot_processing_standard,
        )

        val durationSeconds = player.duration
            .takeIf { it > 0 && it != C.TIME_UNSET }
            ?.div(1000.0)
            ?: 310.0

        votJob = viewLifecycleOwner?.lifecycleScope?.launch {
            runCatching {
                controller.enable(
                    videoId = playerCallback.getVideoId(),
                    durationSeconds = durationSeconds,
                    sourceLanguage = "auto",
                    targetLanguage = "ru",
                    title = playerCallback.getVideoTitle(),
                    voiceMode = if (useLivelyVoice) {
                        com.github.libretube.vot.VotApiClient.VoiceMode.LIVELY
                    } else {
                        com.github.libretube.vot.VotApiClient.VoiceMode.STANDARD
                    },
                    onProgress = { progress ->
                        if (votAudioController === controller) showVotProgress(progress)
                    },
                )
            }.onSuccess { result ->
                votJob = null
                hideVotProgress()
                binding.votToggle.alpha = 1f
                binding.votToggle.imageTintList = android.content.res.ColorStateList.valueOf(android.graphics.Color.parseColor("#BB86FC"))
                val message = when {
                    result.usedVoiceMode == com.github.libretube.vot.VotApiClient.VoiceMode.LIVELY -> R.string.vot_lively_enabled
                    result.requestedVoiceMode == com.github.libretube.vot.VotApiClient.VoiceMode.LIVELY -> R.string.vot_lively_fallback
                    else -> R.string.vot_standard_enabled
                }
                Toast.makeText(context, message, Toast.LENGTH_LONG).show()
            }.onFailure { error ->
                votJob = null
                hideVotProgress()
                controller.release()
                if (votAudioController === controller) votAudioController = null
                binding.votToggle.alpha = 0.72f
                binding.votToggle.imageTintList = android.content.res.ColorStateList.valueOf(android.graphics.Color.WHITE)
                if (error !is kotlinx.coroutines.CancellationException) {
                    Toast.makeText(
                        context,
                        context.getString(R.string.vot_translation_failed, error.message ?: "unknown error"),
                        Toast.LENGTH_LONG,
                    ).show()
                }
            }
        }
    }

'''
    text = text[:start] + replacement + text[stop:]

kt.write_text(text, encoding="utf-8")
print("VOT voice modes applied: standard/lively selector with server-truth result reporting.")
