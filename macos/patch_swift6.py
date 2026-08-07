#!/usr/bin/env python3
from pathlib import Path

path = Path("macos/Sources/PlayerWindowController.swift")
text = path.read_text(encoding="utf-8")

old_timer = '''    private func startSyncTimer() {
        syncTimer?.invalidate()
        syncTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.synchronizeAudio()
            }
        }
        if let syncTimer {
            RunLoop.main.add(syncTimer, forMode: .common)
        }
    }
'''
new_timer = '''    private func startSyncTimer() {
        syncTimer?.invalidate()
        syncTimer = Timer.scheduledTimer(
            timeInterval: 0.5,
            target: self,
            selector: #selector(syncTimerFired),
            userInfo: nil,
            repeats: true
        )
        if let syncTimer {
            RunLoop.main.add(syncTimer, forMode: .common)
        }
    }

    @objc private func syncTimerFired() {
        Task { @MainActor [weak self] in
            await self?.synchronizeAudio()
        }
    }
'''
if old_timer not in text:
    raise SystemExit("Swift 6 timer compatibility marker not found")
text = text.replace(old_timer, new_timer, 1)

old_seek = '''                player.seek(
                    to: CMTime(seconds: max(0, state.currentTime), preferredTimescale: 600),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero
                )
'''
new_seek = '''                await player.seek(
                    to: CMTime(seconds: max(0, state.currentTime), preferredTimescale: 600),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero
                )
'''
if old_seek not in text:
    raise SystemExit("Swift 6 AVPlayer seek compatibility marker not found")
text = text.replace(old_seek, new_seek, 1)

path.write_text(text, encoding="utf-8")
print("Applied Swift 6 compatibility patch")
