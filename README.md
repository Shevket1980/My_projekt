# LibreTube VOT

LibreTube v31.4 with native voice-over translation integration based on the protocol used by ilyhalight/voice-over-translation.

The Android player gets a **Voice translation** button. It requests a Russian voice-over track, plays it in a second Media3/ExoPlayer instance, ducks the original audio, and keeps both players synchronized during pause, seek and playback-speed changes.

This repository contains the integration patch, not a redistributed LibreTube source tree. GitHub Actions checks out the official `libre-tube/LibreTube` tag `v31.4`, applies the patch and builds the debug APK.

Build artifact: `LibreTube-VOT-v31.4-debug.apk`.
