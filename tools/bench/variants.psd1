# Benchmark variants (checked in). Each runs over every selected sample.
# Encode.Codec: libx265 (Crf, Preset) | hevc_amf (Qp = CQP, Quality speed|balanced|quality, PixFmt yuv420p|p010le).
# Config: overrides merged onto Get-ArmConfig for this variant (e.g. UpscaleLiveAction).
# PlanOverride.Filter: replaces the deinterlace/IVTC chain on the plan (#30 filter comparisons).
# Rejected until their issues land: Pipeline = 'streamed' (#28), Concurrency > 1 (#27).
@{
    Variants = @(
        @{ Name = 'x265-slow-crf16';    ContentType = 'LiveAction'; Encode = @{ Codec = 'libx265'; Crf = 16; Preset = 'slow' } }
        @{ Name = 'x265-medium-crf16';  ContentType = 'LiveAction'; Encode = @{ Codec = 'libx265'; Crf = 16; Preset = 'medium' } }
        @{ Name = 'amf-cqp18-10bit';    ContentType = 'LiveAction'; Encode = @{ Codec = 'hevc_amf'; Qp = 18; Quality = 'quality'; PixFmt = 'p010le' } }
        @{ Name = 'amf-cqp20-10bit';    ContentType = 'LiveAction'; Encode = @{ Codec = 'hevc_amf'; Qp = 20; Quality = 'quality'; PixFmt = 'p010le' } }
        # Live-action model comparison: same encode as shipping (x265 slow crf16), engine pinned per variant.
        # Judge by eye with -Mode Frames (SSIM/PSNR score the encode against each model's OWN output,
        # so they do not rank models); UpscaleFps gives the speed.
        @{ Name = 'model-openproteus';  ContentType = 'LiveAction'; Config = @{ UpscaleLiveAction = 'openproteus' }; Encode = @{ Codec = 'libx265'; Crf = 16; Preset = 'slow' } }
        @{ Name = 'model-liveaction';   ContentType = 'LiveAction'; Config = @{ UpscaleLiveAction = 'liveaction' };  Encode = @{ Codec = 'libx265'; Crf = 16; Preset = 'slow' } }
    )
}
