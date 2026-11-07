"""Native ABI/readback smoke test. Generates only synthetic audio, no account/network required.

python scripts/tools/verify_download_tags.py --dll PATH --output DIRECTORY --ffmpeg PATH
"""
import argparse
import ctypes
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--dll', required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--ffmpeg', default='ffmpeg')
    parser.add_argument('--cover', type=Path)
    parser.add_argument('--cover-width', type=int, default=32)
    parser.add_argument('--cover-height', type=int, default=32)
    args = parser.parse_args()
    root = args.output.resolve()
    root.mkdir(parents=True, exist_ok=True)
    lib = ctypes.CDLL(str(Path(args.dll).resolve()))
    lib.md3_tag_writer_open.argtypes = [ctypes.c_char_p]
    lib.md3_tag_writer_open.restype = ctypes.c_uint64
    lib.md3_tag_writer_close.argtypes = [ctypes.c_uint64]
    lib.md3_tag_writer_free_json.argtypes = [ctypes.c_void_p]
    for symbol in ('write', 'inspect'):
        fn = getattr(lib, 'md3_tag_writer_' + symbol)
        fn.argtypes = [ctypes.c_uint64, ctypes.c_char_p]
        fn.restype = ctypes.c_void_p
    lib.md3_tag_writer_capabilities.argtypes = [ctypes.c_uint64]
    lib.md3_tag_writer_capabilities.restype = ctypes.c_void_p

    def result(pointer):
        assert pointer
        try:
            return json.loads(ctypes.string_at(pointer))
        finally:
            lib.md3_tag_writer_free_json(pointer)

    def ffmpeg(*params):
        return subprocess.check_output([args.ffmpeg, '-hide_banner', '-loglevel', 'error', *map(str, params)])

    def audio_hash(path):
        return ffmpeg('-i', path, '-map', '0:a:0', '-f', 'hash', '-hash', 'sha256', '-').decode().strip()

    cover = args.cover or Path(__file__).resolve().parents[2] / 'kugou_api_server/rust/tests/fixtures/audio_tags/cover.png'
    text = ('[00:00.000]<00:00.000>内嵌逐字测试<00:00.900>\n'
            '[00:01.000]<00:01.000>你<00:02.000>好<00:03.000><00:04.000>世<00:05.000>界<00:06.000>\n'
            '[00:07.000]<00:07.000>a=b <00:08.000>末<00:09.000>字<00:10.000>\n'
            '[00:11.000]')
    report = {}
    handle = lib.md3_tag_writer_open(str(root).encode())
    assert handle
    try:
        capabilities = result(lib.md3_tag_writer_capabilities(handle))
        assert capabilities['schemaVersion'] == 1
        report['capabilities'] = capabilities
        for index, extension in enumerate(('mp3', 'flac')):
            job = f'12345678-1234-1234-1234-{index:012d}'
            source = root / f'{job}.source'
            ffmpeg('-y', '-f', 'lavfi', '-i', 'sine=frequency=440:duration=12', '-af', 'volume=0.01',
                   '-metadata', 'comment=remove this source comment',
                   '-c:a', 'libmp3lame' if extension == 'mp3' else 'flac', '-f', extension, source)
            original = hashlib.sha256(source.read_bytes()).hexdigest()
            shutil.copyfile(cover, root / f'{job}.cover')
            payload = {'schemaVersion': 1, 'jobId': job, 'fields': {
                'title': '逐字测试', 'artists': ['测试歌手'], 'album': '合成测试专辑',
                'trackNumber': 1, 'date': '2026-11-07', 'genres': ['Test'],
                'composers': ['测试作曲'], 'lyricists': ['测试作词'],
                'cover': {'width': args.cover_width, 'height': args.cover_height, 'sha256': hashlib.sha256(cover.read_bytes()).hexdigest()},
                'lyrics': {'format': 'eslyric_enhanced', 'wordTimed': True, 'text': text},
            }}
            inspection = result(lib.md3_tag_writer_inspect(handle, job.encode()))
            assert inspection['ok'] and 11900 <= inspection['durationMs'] <= 12200, inspection
            assert inspection['hasComments'] is True, inspection
            written = result(lib.md3_tag_writer_write(handle, json.dumps(payload, ensure_ascii=False).encode()))
            assert written['ok'], written
            assert written['commentFree'] is True, written
            tagged = root / f'{job}.tagged'
            assert hashlib.sha256(source.read_bytes()).hexdigest() == original
            assert audio_hash(source) == audio_hash(tagged), 'Decoded audio changed'
            probe = Path(args.ffmpeg).with_name('ffprobe.exe' if Path(args.ffmpeg).suffix == '.exe' else 'ffprobe')
            tags = json.loads(subprocess.check_output([str(probe), '-v', 'error', '-show_entries', 'format_tags', '-of', 'json', str(tagged)]))['format'].get('tags', {})
            assert not any(key.lower() in ('comment', 'description') for key in tags), tags
            final = root / f'测试歌手-逐字测试.{extension}'
            shutil.copyfile(tagged, final)
            report[extension] = {'inspect': inspection, 'write': written, 'decodedAudioUnchanged': True, 'commentFreeReadback': True, 'file': str(final)}
        # Lifecycle/invalid-handle errors use the same allocator/free path as successful requests.
        for _ in range(1000):
            assert result(lib.md3_tag_writer_write(0, b'{}'))['errorCode'] == 'invalid_handle'
        assert result(lib.md3_tag_writer_write(handle, b'{broken'))['ok'] is False
        assert result(lib.md3_tag_writer_inspect(handle, b'../outside'))['ok'] is False
        report['invalidInputCalls'] = 1002
    finally:
        lib.md3_tag_writer_close(handle)
    assert result(lib.md3_tag_writer_capabilities(handle))['errorCode'] == 'invalid_handle'
    (root / 'verification.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps({'ok': True, 'formats': ['mp3', 'flac'], 'decodedAudioUnchanged': True, 'ffiErrorCalls': 1002}, ensure_ascii=False))


if __name__ == '__main__':
    main()
