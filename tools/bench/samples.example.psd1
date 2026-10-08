# Copy to samples.local.psd1 (gitignored) and set Source to local NAS rip paths.
# Start and Duration are seconds. A 240-frame clip at 24 fps is Duration = 10 (the #24 spike size).
# Name must match ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ and is used in output file names.
@{
    Samples = @(
        @{ Name = 'castaway-dark';      Source = '\\NAS\video\Cast Away\title.mkv';        Start = 1800; Duration = 120 }  # dark interior: banding
        @{ Name = 'snoopy-animation';   Source = '\\NAS\video\Snoopy Come Home\title.mkv';  Start = 900;  Duration = 120 }  # bright flat animation
        @{ Name = 'castaway-grain';     Source = '\\NAS\video\Cast Away\title.mkv';        Start = 3000; Duration = 120 }  # film grain
        @{ Name = 'castaway-motion';    Source = '\\NAS\video\Cast Away\title.mkv';        Start = 4200; Duration = 120 }  # fast motion
        @{ Name = 'castaway-text';      Source = '\\NAS\video\Cast Away\title.mkv';        Start = 6300; Duration = 120 }  # credits/text
        @{ Name = 'tv-interlaced';      Source = 'D:\rips\tv-disc\title.mkv';              Start = 600;  Duration = 120 }  # true-interlaced TV disc
    )
}
