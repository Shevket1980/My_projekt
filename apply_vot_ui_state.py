#!/usr/bin/env python3
from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit("Usage: python apply_vot_ui_state.py /path/to/LibreTube")

root = Path(sys.argv[1]).resolve()
kt = root / "app/src/main/java/com/github/libretube/ui/views/CustomExoPlayerView.kt"
if not kt.exists():
    raise SystemExit(f"CustomExoPlayerView.kt not found: {kt}")

text = kt.read_text(encoding="utf-8")

replacements = [
    (
        '''        binding.votToggle.alpha = 1f\n        Toast.makeText(context, R.string.vot_requesting_translation, Toast.LENGTH_LONG).show()''',
        '''        binding.votToggle.alpha = 1f\n        binding.votToggle.imageTintList = android.content.res.ColorStateList.valueOf(android.graphics.Color.WHITE)\n        Toast.makeText(context, R.string.vot_requesting_translation, Toast.LENGTH_LONG).show()''',
    ),
    (
        '''                binding.votToggle.alpha = 1f\n                Toast.makeText(context, R.string.vot_translation_enabled, Toast.LENGTH_SHORT).show()''',
        '''                binding.votToggle.alpha = 1f\n                binding.votToggle.imageTintList = android.content.res.ColorStateList.valueOf(android.graphics.Color.parseColor("#BB86FC"))\n                Toast.makeText(context, R.string.vot_translation_enabled, Toast.LENGTH_SHORT).show()''',
    ),
    (
        '''                binding.votToggle.alpha = 0.72f\n                if (error !is kotlinx.coroutines.CancellationException) {''',
        '''                binding.votToggle.alpha = 0.72f\n                binding.votToggle.imageTintList = android.content.res.ColorStateList.valueOf(android.graphics.Color.WHITE)\n                if (error !is kotlinx.coroutines.CancellationException) {''',
    ),
    (
        '''        binding.votToggle.alpha = 0.72f\n        if (showToast && wasActive) {''',
        '''        binding.votToggle.alpha = 0.72f\n        binding.votToggle.imageTintList = android.content.res.ColorStateList.valueOf(android.graphics.Color.WHITE)\n        if (showToast && wasActive) {''',
    ),
]

for old, new in replacements:
    if new in text:
        continue
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"Expected exactly one UI marker, found {count}: {old.splitlines()[0]}")
    text = text.replace(old, new, 1)

kt.write_text(text, encoding="utf-8")
print("VOT active-state UI applied: white when inactive/loading, purple when translation is active.")
