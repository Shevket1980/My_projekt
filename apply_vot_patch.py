#!/usr/bin/env python3
from pathlib import Path
import shutil
import sys

HERE = Path(__file__).resolve().parent
if len(sys.argv) != 2:
    raise SystemExit("Usage: python apply_vot_patch.py /path/to/LibreTube")

root = Path(sys.argv[1]).resolve()
main = root / "app/src/main"
if not main.exists():
    raise SystemExit(f"Not a LibreTube source tree: {root}")

layout = main / "res/layout/exo_styled_player_control_view.xml"
kt = main / "java/com/github/libretube/ui/views/CustomExoPlayerView.kt"
if not layout.exists() or not kt.exists():
    raise SystemExit("Expected LibreTube player source files were not found")

layout_text = layout.read_text(encoding="utf-8")
text = kt.read_text(encoding="utf-8")

queue_marker = '''                <ImageButton\n                    android:id="@+id/queue_toggle"'''
imports_marker = 'import androidx.lifecycle.findViewTreeLifecycleOwner\n'
android_import_marker = 'import android.widget.TextView\n'
field_marker = '    private var chaptersBottomSheet: ChaptersBottomSheet? = null\n'
click_marker = '''        val updateSbImageResource = {\n'''
listener_marker = '''            override fun onIsPlayingChanged(isPlaying: Boolean) {\n                super.onIsPlayingChanged(isPlaying)\n                keepScreenOn = isPlaying\n            }\n'''
set_player_marker = '''    override fun setPlayer(player: Player?) {
        // ensure that the below listeners are only
        // initialized one single time to the same player
        if (player == this.player) return

        super.setPlayer(player)
'''
helper_marker = '    private fun syncQueueButtons() {\n'

already_patched = 'private fun toggleVotTranslation(player: Player)' in text
if not already_patched:
    missing = []
    for name, marker in [
        ("queue_toggle", queue_marker),
        ("lifecycle import", imports_marker),
        ("android imports", android_import_marker),
        ("chaptersBottomSheet field", field_marker),
        ("SponsorBlock setup", click_marker),
        ("Player.Listener", listener_marker),
        ("v31.4 setPlayer", set_player_marker),
        ("syncQueueButtons", helper_marker),
    ]:
        haystack = layout_text if name == "queue_toggle" else text
        if marker not in haystack:
            missing.append(name)
    if missing:
        raise SystemExit("LibreTube source does not match expected v31.4 player architecture. Missing: " + ", ".join(missing))

if '@+id/vot_toggle' not in layout_text:
    button = '''                <ImageButton
                    android:id="@+id/vot_toggle"
                    style="@style/PlayerControlTop"
                    android:layout_marginEnd="2dp"
                    android:alpha="0.72"
                    android:src="@drawable/ic_vot_translate"
                    android:tooltipText="@string/vot_voice_translation"
                    app:tint="@android:color/white" />
'''
    layout_text = layout_text.replace(queue_marker, button + queue_marker, 1)

if 'import android.widget.Toast\n' not in text:
    text = text.replace(android_import_marker, android_import_marker + 'import android.widget.Toast\n', 1)

extra_imports = '''import androidx.lifecycle.lifecycleScope
import com.github.libretube.vot.VotAudioController
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
'''
if 'import com.github.libretube.vot.VotAudioController\n' not in text:
    text = text.replace(imports_marker, imports_marker + extra_imports, 1)

fields = '''    private var votAudioController: VotAudioController? = null
    private var votJob: Job? = null
'''
if 'private var votAudioController:' not in text:
    text = text.replace(field_marker, field_marker + fields, 1)

click_code = '''        binding.votToggle.setOnClickListener {
            val currentPlayer = player ?: return@setOnClickListener
            toggleVotTranslation(currentPlayer)
        }

'''
if 'toggleVotTranslation(currentPlayer)' not in text:
    text = text.replace(click_marker, click_code + click_marker, 1)

listener_extra = listener_marker + '''
            override fun onMediaItemTransition(mediaItem: androidx.media3.common.MediaItem?, reason: Int) {
                super.onMediaItemTransition(mediaItem, reason)
                stopVotTranslation(showToast = false)
            }
'''
if 'override fun onMediaItemTransition' not in text:
    text = text.replace(listener_marker, listener_extra, 1)

set_player_replacement = '''    override fun setPlayer(player: Player?) {
        // ensure that the below listeners are only
        // initialized one single time to the same player
        if (player == this.player) return

        if (this.player != null) stopVotTranslation(showToast = false)
        super.setPlayer(player)
'''
if 'if (this.player != null) stopVotTranslation(showToast = false)' not in text:
    text = text.replace(set_player_marker, set_player_replacement, 1)

helpers = r'''    private fun toggleVotTranslation(player: Player) {
        if (votJob?.isActive == true || votAudioController?.isActive == true) {
            stopVotTranslation(showToast = true)
            return
        }

        if (playerCallback.isVideoLive()) {
            Toast.makeText(context, R.string.vot_live_not_supported, Toast.LENGTH_SHORT).show()
            return
        }

        val controller = VotAudioController(context, player)
        votAudioController = controller
        binding.votToggle.alpha = 1f
        Toast.makeText(context, R.string.vot_requesting_translation, Toast.LENGTH_LONG).show()

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
                )
            }.onSuccess {
                votJob = null
                binding.votToggle.alpha = 1f
                Toast.makeText(context, R.string.vot_translation_enabled, Toast.LENGTH_SHORT).show()
            }.onFailure { error ->
                votJob = null
                controller.release()
                if (votAudioController === controller) votAudioController = null
                binding.votToggle.alpha = 0.72f
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

    private fun stopVotTranslation(showToast: Boolean) {
        val wasActive = votJob?.isActive == true || votAudioController?.isActive == true
        votJob?.cancel()
        votJob = null
        votAudioController?.release()
        votAudioController = null
        binding.votToggle.alpha = 0.72f
        if (showToast && wasActive) {
            Toast.makeText(context, R.string.vot_translation_disabled, Toast.LENGTH_SHORT).show()
        }
    }

'''
if 'private fun toggleVotTranslation(player: Player)' not in text:
    text = text.replace(helper_marker, helpers + helper_marker, 1)

layout.write_text(layout_text, encoding="utf-8")
kt.write_text(text, encoding="utf-8")

for rel in [
    "app/src/main/java/com/github/libretube/vot/VotApiClient.kt",
    "app/src/main/java/com/github/libretube/vot/VotAudioController.kt",
    "app/src/main/java/com/github/libretube/vot/VotProto.kt",
    "app/src/main/res/drawable/ic_vot_translate.xml",
    "app/src/main/res/values/vot_strings.xml",
    "app/src/main/res/values-ru/vot_strings.xml",
]:
    src = HERE / rel
    dst = root / rel
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)

print("LibreTube v31.4 VOT patch applied successfully.")
