"""Convert a PyTorch super-resolution checkpoint (.pth) to the ncnn model the runner loads.

Reproduces tools/models/liveaction-x2.{param,bin} from 2xLiveActionV1_SPAN_490000.pth.
Not used at runtime and not installed by setup.ps1; run it by hand on any machine:

    python -m venv conv
    conv/bin/pip install torch spandrel==0.4.2 pnnx==20260526 ncnn numpy
    conv/bin/python -I tools/convert_span_ncnn.py 2xLiveActionV1_SPAN_490000.pth tools/models/liveaction-x2

Steps: load with spandrel (any architecture it knows), export with pnnx using a dynamic
H x W input, rename the pnnx blobs in0/out0 to data/output (the names the shipped
OpenProteus model uses, which tools/ncnn_upscale.py is known to work with), then run
the ncnn model on CPU at DVD sizes and compare against PyTorch.
"""
import argparse
import os
import re
import shutil
import sys
import tempfile

import numpy as np
import torch
import spandrel
import pnnx
import ncnn


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('pth')
    ap.add_argument('out_base', help='output path without extension; writes <out_base>.param/.bin')
    ap.add_argument('--tolerance', type=float, default=1e-4, help='max abs difference vs PyTorch')
    a = ap.parse_args()

    desc = spandrel.ModelLoader().load_from_file(a.pth)
    print(f'{desc.architecture.name} x{desc.scale} {desc.input_channels}->{desc.output_channels}')
    if desc.input_channels != 3 or desc.output_channels != 3:
        print('only RGB -> RGB models are supported by the runner', file=sys.stderr)
        return 1
    model = desc.model.eval()

    with tempfile.TemporaryDirectory() as work:
        base = os.path.join(work, 'model')
        # Two input shapes => pnnx marks H and W dynamic.
        pnnx.export(model, base + '.pt', (torch.rand(1, 3, 64, 64),), (torch.rand(1, 3, 120, 96),), fp16=False)
        param_text = open(base + '.ncnn.param', encoding='ascii').read()
        param_text = re.sub(r'\bin0\b', 'data', param_text)
        param_text = re.sub(r'\bout0\b', 'output', param_text)
        os.makedirs(os.path.dirname(os.path.abspath(a.out_base)), exist_ok=True)
        with open(a.out_base + '.param', 'w', encoding='ascii', newline='\n') as f:
            f.write(param_text)
        shutil.copyfile(base + '.ncnn.bin', a.out_base + '.bin')

    net = ncnn.Net()
    net.opt.use_vulkan_compute = False
    net.opt.use_fp16_storage = False
    net.opt.use_fp16_arithmetic = False
    net.opt.use_fp16_packed = False
    if net.load_param(a.out_base + '.param') != 0 or net.load_model(a.out_base + '.bin') != 0:
        print('ncnn could not load the converted model', file=sys.stderr)
        return 1

    rng = np.random.default_rng(0)
    worst = 0.0
    for h, w in [(480, 720), (576, 720), (67, 93)]:
        ramp = np.linspace(0, 0.7, w, dtype=np.float32)[None, None, :]
        x = np.clip(rng.random((3, h, w)).astype(np.float32) * 0.3 + ramp, 0, 1)
        with torch.no_grad():
            ref = model(torch.from_numpy(x)[None]).numpy()[0]
        ex = net.create_extractor()
        ex.input('data', ncnn.Mat(x))
        _, out = ex.extract('output')
        out = np.array(out)
        if out.shape != ref.shape:
            print(f'{h}x{w}: shape {out.shape} != {ref.shape}', file=sys.stderr)
            return 1
        diff = float(np.abs(out - ref).max())
        worst = max(worst, diff)
        print(f'{h}x{w}: max abs diff {diff:.2e}')
    if worst > a.tolerance:
        print(f'max abs diff {worst:.2e} exceeds {a.tolerance:.0e}', file=sys.stderr)
        return 1
    print(f'wrote {a.out_base}.param / .bin')
    return 0


if __name__ == '__main__':
    sys.exit(main())
