"""ffmpeg -> ncnn/Vulkan super-resolution -> ffmpeg runner for custom ncnn models.

Decodes INPUT to raw BGR frames, upscales each with an ncnn model (.param/.bin),
scales the result to the exact output size (fixes anamorphic DAR), and encodes a
video-only intermediate. Audio/subtitles are NOT handled; the caller muxes them.
Exit code 0 only if every frame was written.
"""
import argparse
import json
import subprocess
import sys
import threading
import queue

from upscale_ncnn_py import UPSCALE


def probe(ffprobe, path):
    out = subprocess.run(
        [ffprobe, '-v', 'error', '-select_streams', 'v:0', '-show_entries',
         'stream=width,height,avg_frame_rate', '-of', 'json', path],
        capture_output=True, text=True, check=True).stdout
    s = json.loads(out)['streams'][0]
    num, den = s['avg_frame_rate'].split('/')
    return int(s['width']), int(s['height']), f'{num}/{den}'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--input', required=True)
    ap.add_argument('--output', required=True)
    ap.add_argument('--param', required=True)
    ap.add_argument('--bin', required=True)
    ap.add_argument('--scale', type=int, default=2)
    ap.add_argument('--out-width', type=int, required=True)
    ap.add_argument('--out-height', type=int, required=True)
    ap.add_argument('--gpu', type=int, default=0)
    ap.add_argument('--ffmpeg', default='ffmpeg')
    ap.add_argument('--ffprobe', default='ffprobe')
    ap.add_argument('--crf', default='12')
    ap.add_argument('--benchmark', action='store_true', help='discard output')
    a = ap.parse_args()

    w, h, fps = probe(a.ffprobe, a.input)
    frame_bytes = w * h * 3

    up = UPSCALE(gpuid=a.gpu, model=-1, scale=a.scale)
    up._load(param_path=a.param, model_path=a.bin, scale=a.scale)

    dec = subprocess.Popen(
        [a.ffmpeg, '-v', 'error', '-i', a.input, '-map', '0:v:0', '-fps_mode', 'passthrough', '-f', 'rawvideo',
         '-pix_fmt', 'bgr24', '-'], stdout=subprocess.PIPE)
    if a.benchmark:
        enc = None
    else:
        enc = subprocess.Popen(
            [a.ffmpeg, '-v', 'error', '-y', '-f', 'rawvideo', '-pix_fmt', 'bgr24',
             '-s', f'{w * a.scale}x{h * a.scale}', '-r', fps, '-i', '-',
             '-vf', f'scale={a.out_width}:{a.out_height}:flags=lanczos,setsar=1',
             '-c:v', 'libx264', '-preset', 'veryfast', '-crf', a.crf, '-pix_fmt', 'yuv420p',
             a.output], stdin=subprocess.PIPE)

    q = queue.Queue(maxsize=8)
    err = []

    def writer():
        try:
            while True:
                item = q.get()
                if item is None:
                    break
                if enc is not None:
                    enc.stdin.write(item)
        except Exception as e:  # broken pipe etc.
            err.append(e)
            while q.get() is not None:
                pass

    t = threading.Thread(target=writer)
    t.start()
    n = 0
    try:
        while True:
            buf = dec.stdout.read(frame_bytes)
            if len(buf) < frame_bytes:
                break
            out = up.process_bytes(buf, w, h, 3)
            q.put(bytes(out))
            n += 1
    finally:
        q.put(None)
        t.join()
        dec.stdout.close()
        if enc is not None:
            enc.stdin.close()
            rc = enc.wait()
        else:
            rc = 0
        drc = dec.wait()
    if err or rc != 0 or drc != 0 or n == 0:
        print(f'ncnn_upscale: failed frames={n} enc={rc} dec={drc} err={err}', file=sys.stderr)
        return 1
    print(f'ncnn_upscale: {n} frames')
    return 0


if __name__ == '__main__':
    sys.exit(main())
