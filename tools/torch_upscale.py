"""ffmpeg -> PyTorch (ROCm/CUDA) super-resolution -> ffmpeg runner for spandrel models.

Same contract as tools/ncnn_upscale.py: decodes INPUT to raw BGR frames, upscales them
in batches with a PyTorch model (.pth/.safetensors, any architecture spandrel loads:
SPAN, ESRGAN, Compact, DAT, HAT, ...), scales the result to the exact output size (fixes
anamorphic DAR), and encodes a video-only intermediate. Audio/subtitles are NOT handled;
the caller muxes them. Exit code 0 only if every frame was written.

Fails fast (exit 2) when torch sees no GPU (torch.cuda.is_available() is False; ROCm
builds report AMD GPUs through the cuda API) or when the model's scale differs from
--scale.

Progress: every PROGRESS_INTERVAL_SEC (and once at the end) prints a key=value block on
stdout, flushed so it streams through the pipe:
    frame=<frames done>
    fps=<average frames/s since start>
    progress=continue|end
Invoke-ArmTool -ProgressHandler parses these (same shape as ffmpeg -progress).
"""
import argparse
import json
import queue
import subprocess
import sys
import threading
import time

PROGRESS_INTERVAL_SEC = 10


def report_progress(frames, started, state):
    elapsed = time.monotonic() - started
    fps = frames / elapsed if elapsed > 0 else 0.0
    print(f'frame={frames}\nfps={fps:.2f}\nprogress={state}', flush=True)


def probe(ffprobe, path):
    out = subprocess.run(
        [ffprobe, '-v', 'error', '-select_streams', 'v:0', '-show_entries',
         'stream=width,height,avg_frame_rate', '-of', 'json', path],
        capture_output=True, text=True, check=True).stdout
    s = json.loads(out)['streams'][0]
    num, den = s['avg_frame_rate'].split('/')
    return int(s['width']), int(s['height']), f'{num}/{den}'


class Upscaler:
    def __init__(self, torch, model_path, dtype):
        import spandrel
        self.torch = torch
        desc = spandrel.ModelLoader().load_from_file(model_path)
        self.scale = desc.scale
        self.dtype = torch.float16 if dtype == 'fp16' else torch.float32
        self.model = desc.model.eval().to('cuda')
        if self.dtype == torch.float16:
            self.model = self.model.half()

    def run(self, bgr_batch):
        """bgr_batch: uint8 ndarray (N,H,W,3) BGR -> uint8 ndarray (N,H*s,W*s,3) BGR."""
        torch = self.torch
        with torch.inference_mode():
            t = torch.from_numpy(bgr_batch).to('cuda')
            t = t.flip(-1).permute(0, 3, 1, 2).to(self.dtype).div_(255.0)  # RGB NCHW
            o = self.model(t).clamp_(0, 1).mul_(255.0).round_().to(torch.uint8)
            return o.permute(0, 2, 3, 1).flip(-1).contiguous().cpu().numpy()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--input', required=True)
    ap.add_argument('--output', required=True)
    ap.add_argument('--model', required=True, help='.pth/.safetensors file spandrel can load')
    ap.add_argument('--scale', type=int, default=2)
    ap.add_argument('--out-width', type=int, required=True)
    ap.add_argument('--out-height', type=int, required=True)
    ap.add_argument('--dtype', choices=['fp16', 'fp32'], default='fp16')
    ap.add_argument('--batch', type=int, default=4)
    ap.add_argument('--ffmpeg', default='ffmpeg')
    ap.add_argument('--ffprobe', default='ffprobe')
    ap.add_argument('--crf', default='12')
    ap.add_argument('--benchmark', action='store_true', help='discard output')
    a = ap.parse_args()

    import numpy as np
    import torch
    if not torch.cuda.is_available():
        print(f'torch_upscale: no GPU visible to torch {torch.__version__} '
              f'(torch.cuda.is_available() is False); check the AMD driver / ROCm install', file=sys.stderr)
        return 2
    if a.batch < 1:
        print('torch_upscale: --batch must be >= 1', file=sys.stderr)
        return 2

    w, h, fps = probe(a.ffprobe, a.input)
    frame_bytes = w * h * 3

    up = Upscaler(torch, a.model, a.dtype)
    if up.scale != a.scale:
        print(f'torch_upscale: model {a.model} is {up.scale}x but --scale is {a.scale}', file=sys.stderr)
        return 2
    # Warm-up (kernel selection / MIOpen find) so the first progress block is not skewed.
    up.run(np.zeros((a.batch, h, w, 3), np.uint8))
    torch.cuda.synchronize()

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
    started = time.monotonic()
    last_report = started
    try:
        done = False
        while not done:
            frames = []
            for _ in range(a.batch):
                buf = dec.stdout.read(frame_bytes)
                if len(buf) < frame_bytes:
                    done = True
                    break
                frames.append(np.frombuffer(buf, np.uint8).reshape(h, w, 3))
            if not frames:
                break
            out = up.run(np.stack(frames))
            for i in range(out.shape[0]):
                q.put(out[i].tobytes())
            n += len(frames)
            now = time.monotonic()
            if now - last_report >= PROGRESS_INTERVAL_SEC:
                report_progress(n, started, 'continue')
                last_report = now
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
    report_progress(n, started, 'end')
    if err or rc != 0 or drc != 0 or n == 0:
        print(f'torch_upscale: failed frames={n} enc={rc} dec={drc} err={err}', file=sys.stderr)
        return 1
    print(f'torch_upscale: {n} frames')
    return 0


if __name__ == '__main__':
    sys.exit(main())
