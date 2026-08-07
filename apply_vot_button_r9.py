#!/usr/bin/env python3
from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit("Usage: python apply_vot_button_r9.py /path/to/LibreTube")

root = Path(sys.argv[1]).resolve()
layout = root / "app/src/main/res/layout/exo_styled_player_control_view.xml"
player = root / "app/src/main/java/com/github/libretube/ui/views/CustomExoPlayerView.kt"
for path in (layout, player):
    if not path.exists():
        raise SystemExit(f"Expected LibreTube file not found: {path}")

xml = layout.read_text(encoding="utf-8")

top_button = '''                <ImageButton
                    android:id="@+id/vot_toggle"
                    style="@style/PlayerControlTop"
                    android:layout_marginEnd="2dp"
                    android:alpha="0.72"
                    android:src="@drawable/ic_vot_translate"
                    android:tooltipText="@string/vot_voice_translation"
                    app:tint="@android:color/white" />
'''

bottom_button = '''                <ImageButton
                    android:id="@+id/vot_toggle"
                    style="@style/PlayerControlBottom"
                    android:layout_marginEnd="4dp"
                    android:alpha="0.85"
                    android:src="@drawable/ic_vot_translate"
                    android:tooltipText="@string/vot_voice_translation"
                    android:visibility="visible"
                    app:tint="@android:color/white" />

'''

fullscreen_marker = '''                <ImageButton
                    android:id="@+id/fullscreen"
                    style="@style/PlayerControlBottom"'''

# r5-r8 placed VOT in the crowded top-right row. On some devices that row can
# clip controls. r9 moves the same binding into the stable bottom controls row.
if top_button in xml:
    xml = xml.replace(top_button, "", 1)

if 'android:id="@+id/vot_toggle"' not in xml:
    if xml.count(fullscreen_marker) != 1:
        raise SystemExit("Fullscreen button marker mismatch")
    xml = xml.replace(fullscreen_marker, bottom_button + fullscreen_marker, 1)

if xml.count('android:id="@+id/vot_toggle"') != 1:
    raise SystemExit("Expected exactly one vot_toggle after r9 relocation")
if 'style="@style/PlayerControlBottom"' not in xml[xml.find('android:id="@+id/vot_toggle"') - 160:xml.find('android:id="@+id/vot_toggle"') + 500]:
    raise SystemExit("vot_toggle was not moved to bottom controls")

layout.write_text(xml, encoding="utf-8")

kt = player.read_text(encoding="utf-8")
visibility_code = '''        binding.votToggle.isVisible = true
        binding.votToggle.bringToFront()
'''
fullscreen_click = '''        binding.fullscreen.setOnClickListener { playerCallback.toggleFullscreen() }
'''
if visibility_code not in kt:
    if kt.count(fullscreen_click) != 1:
        raise SystemExit("Fullscreen click marker mismatch")
    kt = kt.replace(fullscreen_click, fullscreen_click + visibility_code, 1)
player.write_text(kt, encoding="utf-8")

print("LibreTube VOT r9 button fix applied: translation button moved beside fullscreen and forced visible.")
