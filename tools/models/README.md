# Upscale models

`registry.psd1` lists every model-file upscale engine: its backend, files, native scale,
license, and where setup gets the files (`Bundled` here, or a pinned `Source` download).
`setup.ps1` (`Install-ArmRegistryModels`) installs each entry into the backend's model dir
(`NcnnModelDir` for ncnn, `TorchModelDir` for torch) after checking the SHA256 values. Select an
engine by its registry name, e.g. `UpscaleLiveAction = 'liveaction'`. ncnn engines run through
`tools/ncnn_upscale.py`. torch engines run through `tools/torch_upscale.py` (PyTorch on AMD ROCm),
which `setup.ps1 -WithTorch` installs; their models are installed only with that switch.

## Adding a model

For a model on an existing backend (`ncnn` or `torch`), no code changes are needed:

1. Add an entry to `registry.psd1`. The fields are documented at the top of that file. An ncnn
   entry needs exactly one `.param` and one `.bin` with the same base name. A torch entry needs
   exactly one `.pth` or `.safetensors` that [spandrel](https://github.com/chaiNNer-org/spandrel)
   can load (SPAN, ESRGAN, Compact, DAT, HAT, SwinIR and more). That is usually the file
   OpenModelDB links to, with no conversion.
2. Supply the files in one of two ways:
   - **Bundled:** commit them here, add them to `.gitattributes` (`-text` or `binary`), and pin
     each SHA256 under `Bundled`.
   - **Source:** give a downloadable `Url` (a release asset, not a `/tree/` page), its `Sha256`,
     and `Archive = 'tar.gz'` if it is an archive.
3. Add a section below with the source, license and checksums.
4. Run `setup.ps1` (it installs only what is missing), then set `UpscaleLiveAction` or
   `UpscaleAnimation` to the new name.

A model you do not want in the repo can go in `<NcnnModelDir>\registry.local.psd1` instead.
That file has the same format. Its entries add to the repo ones or replace them, and the
upscaler reads it at plan time. Copy the files into the model dir yourself (setup reads only the
repo registry). An invalid entry is skipped, and the upscale log shows a WARN naming it.

## liveaction-x2 (`liveaction-x2.param`, `liveaction-x2.bin`)

- **Model:** 2xLiveActionV1_SPAN by jcj83429. It is a 2x SPAN model (48 channels) trained to fix
  compression artifacts, chroma subsampling, softness from repeated scaling, oversharpening halos
  and bad-deinterlacing jaggies in live-action video. It does not denoise, so grain is kept.
- **Source:** `2xLiveActionV1_SPAN_490000.pth` from
  <https://github.com/jcj83429/upscaling/tree/9332e7d5b07747ff347e5abdc43f8144364de9f7/2xLiveActionV1_SPAN>
  (SHA256 `8b166c75831ea7f694d9058ee9c8df8148af8cc1d2b57e69e6581b15cab572f7`). Also listed on
  [OpenModelDB](https://openmodeldb.info/models/2x-LiveActionV1-SPAN).
- **License:** [CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/), as declared by
  the author. This ncnn conversion is a derivative and carries the same license: attribution
  above, non-commercial use only, and share-alike.
- **Conversion:** `tools/convert_span_ncnn.py` (spandrel 0.4.2, pnnx 20260526, torch 2.14.1). It
  exports fp32 weights with a dynamic input size, renames the blobs to `data` / `output`, and
  checks the ncnn output against PyTorch. At 720x480, 720x576 and 93x67 the largest difference
  was 1.3e-6.

| File | Bytes | SHA256 |
|---|---|---|
| `liveaction-x2.param` | 5839 | `2b0a04ad8519d2bc526227e7fedde9b7ebe7bce2f42476ad73c3431c49928bdc` |
| `liveaction-x2.bin` | 1642888 | `5395811c56e60f39e42d9a3587fba1fa7af07a3aed1dfca26ae38e580d3b6f27` |

`.gitattributes` marks these files `-text` so Git never rewrites their line endings, which
would change the checksums.

## liveaction-torch (`2xLiveActionV1_SPAN_490000.pth`)

The original PyTorch checkpoint of the model above, unchanged (same source, SHA256 and
CC BY-NC-SA 4.0 license; attribution above). The `liveaction-torch` engine loads it with spandrel
in `tools/torch_upscale.py`. On an RX 7800 XT it ran at about 57 fps (fp16, batch 4), against
17.6 fps for the ncnn conversion (`docs/spike-pytorch-rocm-results.md`).

| File | Bytes | SHA256 |
|---|---|---|
| `2xLiveActionV1_SPAN_490000.pth` | 8947821 | `8b166c75831ea7f694d9058ee9c8df8148af8cc1d2b57e69e6581b15cab572f7` |

## openproteus-x2 (downloaded, not bundled)

2x_OpenProteus_Compact_i2_70K, from the TNTwise real-video-enhancer-models release (URL and
SHA256 in `registry.psd1`). No license is declared upstream, so it is for personal use only.
