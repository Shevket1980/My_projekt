package com.github.libretube.vot

import android.content.Context
import android.os.Handler
import android.os.Looper
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeout
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlin.math.abs

/** Plays VOT's translated audio as a second, synchronized audio track. */
class VotAudioController(
    context: Context,
    private val mainPlayer: Player,
    private val api: VotApiClient = VotApiClient(),
) {
    private val appContext = context.applicationContext
    private val handler = Handler(Looper.getMainLooper())
    private var translatedPlayer: ExoPlayer? = null
    private var originalVolume: Float? = null

    var isActive: Boolean = false
        private set

    private val mainListener = object : Player.Listener {
        override fun onIsPlayingChanged(isPlaying: Boolean) {
            syncPlayState()
        }

        override fun onPositionDiscontinuity(
            oldPosition: Player.PositionInfo,
            newPosition: Player.PositionInfo,
            reason: Int,
        ) {
            translatedPlayer?.seekTo(mainPlayer.currentPosition.coerceAtLeast(0L))
        }

        override fun onPlaybackParametersChanged(playbackParameters: PlaybackParameters) {
            translatedPlayer?.playbackParameters = playbackParameters
        }
    }

    private val driftSync = object : Runnable {
        override fun run() {
            val translated = translatedPlayer ?: return
            if (translated.playbackState == Player.STATE_READY) {
                val drift = translated.currentPosition - mainPlayer.currentPosition
                if (abs(drift) > MAX_ALLOWED_DRIFT_MS) {
                    translated.seekTo(mainPlayer.currentPosition.coerceAtLeast(0L))
                }
            }
            handler.postDelayed(this, SYNC_INTERVAL_MS)
        }
    }

    suspend fun enable(
        videoId: String,
        durationSeconds: Double,
        sourceLanguage: String = "auto",
        targetLanguage: String = "ru",
    ): VotApiClient.TranslationResult {
        release()

        val result = api.requestTranslation(
            youtubeUrl = "https://youtu.be/$videoId",
            durationSeconds = durationSeconds,
            sourceLanguage = sourceLanguage,
            targetLanguage = targetLanguage,
        )
        currentCoroutineContext().ensureActive()

        val translated = prepareResultAudio(result)
        currentCoroutineContext().ensureActive()

        translatedPlayer = translated
        originalVolume = mainPlayer.volume
        mainPlayer.volume = (mainPlayer.volume * ORIGINAL_AUDIO_DUCKING).coerceIn(0f, 1f)
        mainPlayer.addListener(mainListener)
        isActive = true

        translated.seekTo(mainPlayer.currentPosition.coerceAtLeast(0L))
        translated.playbackParameters = mainPlayer.playbackParameters
        syncPlayState()

        handler.removeCallbacks(driftSync)
        handler.post(driftSync)
        return result
    }

    fun release() {
        handler.removeCallbacks(driftSync)
        mainPlayer.removeListener(mainListener)
        translatedPlayer?.release()
        translatedPlayer = null
        originalVolume?.let { mainPlayer.volume = it }
        originalVolume = null
        isActive = false
    }

    private suspend fun prepareResultAudio(result: VotApiClient.TranslationResult): ExoPlayer {
        val candidates = (listOf(result.audioUrl) + result.fallbackAudioUrls).distinct()
        var lastError: Throwable? = null

        for (audioUrl in candidates) {
            try {
                return withTimeout(AUDIO_PREPARE_TIMEOUT_MS) {
                    prepareTranslatedPlayer(audioUrl)
                }
            } catch (error: TimeoutCancellationException) {
                lastError = error
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                lastError = error
            }
            currentCoroutineContext().ensureActive()
        }

        throw IllegalStateException("Translated audio could not be loaded", lastError)
    }

    private suspend fun prepareTranslatedPlayer(audioUrl: String): ExoPlayer =
        suspendCancellableCoroutine { continuation ->
            val translated = ExoPlayer.Builder(appContext).build()
            val attributes = AudioAttributes.Builder()
                .setUsage(C.USAGE_MEDIA)
                .setContentType(C.AUDIO_CONTENT_TYPE_SPEECH)
                .build()

            var completed = false
            lateinit var listener: Player.Listener

            fun finishWithError(error: Throwable) {
                if (completed) return
                completed = true
                translated.removeListener(listener)
                translated.release()
                if (continuation.isActive) continuation.resumeWithException(error)
            }

            listener = object : Player.Listener {
                override fun onPlaybackStateChanged(playbackState: Int) {
                    if (playbackState == Player.STATE_READY && !completed) {
                        completed = true
                        translated.removeListener(this)
                        if (continuation.isActive) continuation.resume(translated) else translated.release()
                    }
                }

                override fun onPlayerError(error: PlaybackException) {
                    finishWithError(error)
                }
            }

            continuation.invokeOnCancellation {
                if (!completed) {
                    completed = true
                    translated.removeListener(listener)
                    translated.release()
                }
            }

            try {
                translated.setAudioAttributes(attributes, false)
                translated.volume = 1f
                translated.setMediaItem(MediaItem.fromUri(audioUrl))
                translated.addListener(listener)
                translated.prepare()
            } catch (error: Throwable) {
                finishWithError(error)
            }
        }

    private fun syncPlayState() {
        val translated = translatedPlayer ?: return
        if (mainPlayer.isPlaying) translated.play() else translated.pause()
    }

    companion object {
        private const val ORIGINAL_AUDIO_DUCKING = 0.28f
        private const val SYNC_INTERVAL_MS = 500L
        private const val MAX_ALLOWED_DRIFT_MS = 220L
        private const val AUDIO_PREPARE_TIMEOUT_MS = 25_000L
    }
}
