# Bundled ncnn models

`setup.ps1` (`Install-ArmBundledNcnnModel`) copies these into `NcnnModelDir` after checking
the SHA256 values below. The `liveaction` engine (`UpscaleLiveAction = 'liveaction'`) runs them
through `tools/ncnn_upscale.py`.

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
