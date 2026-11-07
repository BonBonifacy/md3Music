# Synthetic audio fixtures

The files in this folder are generated test signals, not commercial recordings.

Commands (FFmpeg):

```
ffmpeg -f lavfi -i sine=frequency=440:duration=0.25 -c:a libmp3lame tone.mp3
ffmpeg -f lavfi -i sine=frequency=440:duration=0.25 -c:a flac tone.flac
ffmpeg -f lavfi -i color=c=blue:s=32x32 -frames:v 1 cover.png
```
