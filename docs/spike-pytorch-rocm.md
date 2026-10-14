# Spike: PyTorch/ROCm (Windows) vs ncnn/Vulkan for upscaling

Self-contained brief for a fresh Claude Code session. Time box: about 1 hour of work. Output: a results note and a go/no-go recommendation. No changes to `src/` or `tools/` on `main` unless step 6 is approved.

## Question

Can AMD's official Windows PyTorch ROCm wheels run our SPAN upscale on the RX 7800 XT (gfx1101) faster than, or with better model reach than, the current ncnn/Vulkan runner `tools/ncnn_upscale.py` (about 13.5 fps for `liveaction-x2` on 720x480 per the bakeoff in memory `project_liveaction_bakeoff_amf`)?

## Background (verified 2026-10-13)

- REAL Video Enhancer's ROCm backend is Linux-only (ROCm 6.2). It is not usable here and has no CLI. Do not use it.
- AMD's Windows matrix lists gfx1101 with ROCm 7.2.1, PyTorch 2.9.1, Python 3.12, Windows 11. Its product list names the RX 7700, not the 7800 XT, so detection must be tested. AMD calls Windows PyTorch a preview.
  - Matrix: https://rocm.docs.amd.com/projects/radeon-ryzen/en/latest/docs/compatibility/compatibilityrad/windows/windows_compatibility.html
  - Install guide (wheel URLs on repo.radeon.com): https://rocm.docs.amd.com/projects/radeon-ryzen/en/docs-7.2.1/docs/install/installryz/windows/install-pytorch.html
- The checkpoint to test is 2xLiveActionV1_SPAN (CC BY-NC-SA 4.0), source and SHA256 in `tools/models/README.md`. `tools/convert_span_ncnn.py` already loads it via spandrel (0.4.2), so reuse its loading code.
- Current runner contract: `tools/ncnn_upscale.py` pipes ffmpeg raw BGR24 → model → ffmpeg `libx264` intermediate, prints `frame=/fps=/progress=` blocks every 10 s, and supports `--benchmark` (discard output). Any torch runner must keep that interface.

## Ground rules

- Work in a throwaway worktree or scratch dir outside the repo tree, for example `C:\dev\wrm-torch-spike`. Use a NEW venv with Python 3.12. Never touch the existing ncnn venv or `C:\rips`.
- Use `pwsh` 7+. Follow `CLAUDE.md` in the repo root.
- Don't run while the upscale worker is mid-job (GPU contention skews fps): check `Get-ScheduledTask wrm-upscaler` and `C:\rips\upscale-queue`, and stop the task for the test only if the queue is idle. Restart it afterwards.
- The AMD wheel hosts and any model downloads are external. Download only from the URLs in the AMD install guide. Verify the SHA256 of the checkpoint against `tools/models/README.md` before use.
- Quality is judged by eye, so the user must confirm it (V2). Speed and detection are measurable (V1).

## Steps and pass/fail criteria

1. **Install.** Create the venv with Python 3.12 and install `torch`, `torchvision`, `torchaudio` using the exact wheel URLs on the AMD install guide page (fetch it for current URLs), plus `spandrel==0.4.2`, `numpy`.
   Pass: `python -c "import torch; print(torch.__version__, torch.version.hip, torch.cuda.is_available(), torch.cuda.get_device_name(0))"` prints `True` and the Radeon name. Record the output.
   Fail: not detected. Update the Adrenalin driver and retry once; if still failing, stop and report NO-GO (record the error).
2. **Smoke test.** Load the checkpoint with spandrel (as in `tools/convert_span_ncnn.py`), run one 720x480 frame in fp32 and fp16 on the GPU.
   Pass: no crash, output shape 1440x960, fp16 vs fp32 max abs diff small (report it).
3. **Correctness vs ncnn.** For one frame, compare the torch output to the ncnn runner output (`tools/ncnn_upscale.py` on a 1-frame clip, or `upscale_ncnn_py` directly). Report max/mean abs diff and PSNR. Expect fp32 near-identical (convert script logged 1.3e-6 vs PyTorch).
4. **Speed.** Write `torch_upscale.py` in the scratch dir as a copy of `tools/ncnn_upscale.py` with only the inference swapped (keep args, progress output, `--benchmark`). Try these variants on the same 240-frame clip (720x480, 10 s at 24 fps cut from a Cast Away NAS rip; see `tools/bench/samples.example.psd1` for Source paths and `docs/upscaler-spike-2026-10.md` for the method):
   - fp32
   - fp16 (`model.half()`)
   - fp16 + `channels_last`
   - batch size 1 vs 4 frames, if memory allows
   Run `--benchmark` three times per variant; report median model-only fps, peak VRAM (`rocm-smi`-equivalent, or `torch.cuda.max_memory_allocated`), and the ncnn baseline measured in the same session (do not reuse the old 13.5 number).
   Pass for "faster": at least 1.3x ncnn median fps. Otherwise speed is a wash.
5. **Stability.** Run the best variant for 15 minutes of continuous frames (loop the clip or use a longer sample). Check for GPU hangs, driver resets (Event Viewer → Display/amdkmdag), memory growth, or a crash. Pass: no errors and flat VRAM.
6. **Model reach (optional, only if steps 1-5 pass).** Try one heavier model that ncnn handles badly (for example a DAT or HAT x2 from OpenModelDB, via spandrel). Report fps and whether it fits 16 GB. Note its license. Do not bundle anything.
7. **Visual check (user).** Encode a 10 s output from the best torch variant and the ncnn runner from the same clip, and put both in `C:\dev\wrm-torch-spike\out\` for the user to compare. Ask the user for a verdict. Do not claim quality equivalence yourself.

## Deliverable

Write `docs/spike-pytorch-rocm-results.md` containing: commands run, the outputs quoted verbatim for steps 1, 3, 4 (table: variant, median fps, VRAM), step 5 outcome, any failures, install size on disk (`du` of the venv), and a recommendation:

- **GO:** torch engine worth adding. Then outline the change: new engine in `$script:ArmNcnnEngineModels`' sibling map, `Invoke-ArmTool` tool name `torch`, `setup.ps1` install step (Python 3.12 venv, multi-GB, pinned wheel URLs), `SPEC.md` config schema, `config.example.psd1` keys, stubs in `tests/stubs/`, Pester tests. Do not implement without user approval.
- **NO-GO:** state why (not detected, unstable, not faster, install burden outweighs gain).

Be explicit about anything skipped. Do not open a PR for the spike itself; if committing the results note, do it on a branch off `main` and ask first.

## Cleanup

Restart `wrm-upscaler` if you stopped it. Leave the scratch dir for the user to inspect; list its size in the results note.
