---
name: youtube-transcriber
description: Transcribe YouTube videos using yt-dlp subtitle extraction, Amazon Transcribe, or local Whisper ASR. Use when user wants to transcribe a YouTube video or extract a video transcript.
---

# YouTube Video Transcriber

## When to Use
- User provides a YouTube URL and wants a transcript
- User asks to transcribe a video
- User needs captions/subtitles extracted from a video

## Method Priority

### 1. yt-dlp Subtitle Extraction (Fastest, Free)
```bash
yt-dlp --write-auto-sub --sub-lang en --skip-download --sub-format vtt \
  -o "transcript" "VIDEO_URL"
```
- Works from residential IPs, blocked from cloud IPs
- If blocked: use `--cookies /path/to/cookies.txt`
- Export cookies: `yt-dlp --cookies-from-browser chrome --cookies cookies.txt`

### 2. Amazon Transcribe (Cloud-native, $0.024/min)
```python
import boto3

s3 = boto3.client('s3')
transcribe = boto3.client('transcribe', region_name='us-west-2')

# Upload audio to S3
s3.upload_file('audio.mp3', 'amzn-s3-demo-bucket', 'transcribe/audio.mp3')

# Start transcription
transcribe.start_transcription_job(
    TranscriptionJobName='gtc-keynote',
    Media={'MediaFileUri': 's3://amzn-s3-demo-bucket/transcribe/audio.mp3'},
    MediaFormat='mp3',
    LanguageCode='en-US',
    Settings={'ShowSpeakerLabels': True, 'MaxSpeakerLabels': 5}
)
```
Cost: ~$3.50 for a 2.5hr video

### 3. Local Whisper ASR (Free, requires GPU or fast CPU)
```bash
# faster-whisper (CPU-optimized)
pip install faster-whisper
python3 -c "
from faster_whisper import WhisperModel
model = WhisperModel('large-v3', device='cpu', compute_type='int8')
segments, info = model.transcribe('audio.mp3', beam_size=5)
for segment in segments:
    print(f'[{segment.start:.2f}s -> {segment.end:.2f}s] {segment.text}')
"
```

### 4. Powerful ASR Models (GPU required)
- **Qwen3-ASR** (1.7B): Highest accuracy for technical content
- **NVIDIA Canary-Qwen** (2.5B): Best formatting
- **WhisperX**: Best for speaker diarization

## Audio Download

If subtitles aren't available, download audio first:
```bash
# From residential IP:
yt-dlp -f "bestaudio" -x --audio-format mp3 -o "audio.%(ext)s" "VIDEO_URL"

# Then SCP to cloud:
scp audio.mp3 ubuntu@host:/path/to/
```

## Cloud IP Workaround

YouTube blocks cloud IPs. Options:
1. Download from local machine, SCP to cloud
2. Use `--cookies` flag with exported browser cookies
3. Use Amazon Transcribe (upload audio to S3, no YouTube needed)

## Output Format

```markdown
# [Video Title]

**Duration:** HH:MM:SS
**URL:** [url]
**Transcribed:** YYYY-MM-DD

## Transcript
[Full text with timestamps]
```

<!-- imported on 2026-10-31 by tools/import-skills.py from a native Claude Code instance's skill library; the source site's names, ids, hosts and paths are scrubbed to <placeholders>; its other files were not copied -->
