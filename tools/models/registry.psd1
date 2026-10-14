# Upscale model registry: engine name -> model. An engine listed here can be selected with
# UpscaleLiveAction / UpscaleAnimation. anime4k and realesrgan are built-in video2x engines
# and are not listed. Read by Get-ArmUpscaleModelRegistry (src/Upscale-Video.ps1) and
# Install-ArmRegistryModels (setup.ps1). See tools/models/README.md "Adding a model".
#
# Fields:
#   Backend   'ncnn'  (tools/ncnn_upscale.py; Files = one .param + one .bin with the same base name)
#             'torch' (tools/torch_upscale.py; Files = one .pth/.safetensors that spandrel loads;
#                      installed only by setup.ps1 -WithTorch)
#   Files     file names inside the backend's model dir (NcnnModelDir / TorchModelDir)
#   Scale     the model's native scale factor (the runner then resizes to UpscaleHeight)
#   License   free text, shown in tools/models/README.md
#   Bundled   @{ <file> = '<sha256>' }: the files are committed in tools/models/, setup copies them
#   Source    @{ Url; Sha256; Archive = 'tar.gz' }: setup downloads Url and checks Sha256; for
#             an archive, each Files entry is the first member with the same extension
#   (exactly one of Bundled / Source)
@{
    openproteus = @{
        Backend = 'ncnn'
        Files   = @('openproteus-x2.param', 'openproteus-x2.bin')
        Scale   = 2
        License = 'none declared upstream (personal use)'
        Source  = @{
            Url     = 'https://github.com/TNTwise/real-video-enhancer-models/releases/download/models/2x_OpenProteus_Compact_i2_70K.tar.gz'
            Sha256  = '0d96689273650613726ebae4482cdc56943f46e819f99109054d0ca325d6a7c7'
            Archive = 'tar.gz'
        }
    }
    liveaction  = @{
        Backend = 'ncnn'
        Files   = @('liveaction-x2.param', 'liveaction-x2.bin')
        Scale   = 2
        License = 'CC BY-NC-SA 4.0'
        Bundled = @{
            'liveaction-x2.param' = '2b0a04ad8519d2bc526227e7fedde9b7ebe7bce2f42476ad73c3431c49928bdc'
            'liveaction-x2.bin'   = '5395811c56e60f39e42d9a3587fba1fa7af07a3aed1dfca26ae38e580d3b6f27'
        }
    }
    'liveaction-torch' = @{
        Backend = 'torch'
        Files   = @('2xLiveActionV1_SPAN_490000.pth')
        Scale   = 2
        License = 'CC BY-NC-SA 4.0'
        Bundled = @{
            '2xLiveActionV1_SPAN_490000.pth' = '8b166c75831ea7f694d9058ee9c8df8148af8cc1d2b57e69e6581b15cab572f7'
        }
    }
}
