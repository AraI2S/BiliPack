<#
Batch-mux matching video-only and audio-only files into MP4 without re-encoding.
Windows PowerShell 5.1 or PowerShell 7; requires ffmpeg.exe and ffprobe.exe.

Double-click Main.bat in the media directory, or run:
  .\Main.bat -Preview
  .\Main.bat
  .\Main.bat -Recurse -VerifyDecode
  .\Main.bat -Manifest pairs.csv

CSV columns: video,audio,output (output optional; UTF-8 encoding).
Input paths are relative to the script/input folder; outputs go under merged/.
Original files are never modified or deleted.
#>

[CmdletBinding()]
param(
    [string]$InputDir = '',
    [string]$OutputDir = 'merged',
    [switch]$Recurse,
    [string]$Manifest = '',
    [switch]$Preview,
    [switch]$Force,
    [switch]$VerifyDecode,
    [switch]$AllowDurationMismatch,
    [double]$MaxGapSeconds = 2.0
)

$ErrorActionPreference = 'Continue'
$script:AllowedExtensions = @{
    '.mp4' = $true; '.m4s' = $true; '.m4a' = $true; '.m4v' = $true
    '.mov' = $true; '.aac' = $true; '.mp3' = $true; '.mkv' = $true
    '.webm' = $true; '.ts' = $true
}

function Find-Executable([string]$Name) {
    $besideScript = Join-Path $PSScriptRoot ($Name + '.exe')
    if (Test-Path -LiteralPath $besideScript -PathType Leaf) { return $besideScript }
    $command = Get-Command ($Name + '.exe') -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -ne $command) { return $command.Source }
    return $null
}

function Normalize-Path([string]$Value) {
    return [System.IO.Path]::GetFullPath($Value)
}

function Is-Inside([string]$Candidate, [string]$Parent) {
    $p = (Normalize-Path $Candidate).TrimEnd([char[]]@('\', '/'))
    $b = (Normalize-Path $Parent).TrimEnd([char[]]@('\', '/'))
    $same = $p.Equals($b, [System.StringComparison]::OrdinalIgnoreCase)
    $child = $p.StartsWith(($b + [System.IO.Path]::DirectorySeparatorChar),
        [System.StringComparison]::OrdinalIgnoreCase)
    return ($same -or $child)
}

function Resolve-Child([string]$Base, [string]$Relative, [string]$Field) {
    if ([string]::IsNullOrWhiteSpace($Relative) -or
        [System.IO.Path]::IsPathRooted($Relative)) {
        throw "$Field 必须是相对文件路径。"
    }
    $full = Normalize-Path (Join-Path $Base $Relative)
    if (-not (Is-Inside $full $Base) -or $full.Equals($Base,
            [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Field 不得指向指定目录之外。"
    }
    return $full
}

function Read-Seconds($Value) {
    if ($null -eq $Value) { return $null }
    [double]$number = 0
    $ok = [double]::TryParse([string]$Value,
        [System.Globalization.NumberStyles]::Float,
        [System.Globalization.CultureInfo]::InvariantCulture, [ref]$number)
    if ($ok -and -not [double]::IsNaN($number) -and
        -not [double]::IsInfinity($number) -and $number -gt 0) {
        return $number
    }
    return $null
}

function Read-Probe([string]$Path) {
    # JSON fields are ASCII except optional metadata; avoid parsing ffmpeg's prose.
    $probeArgs = @(
        '-v', 'error', '-show_entries',
        'stream=index,codec_type,codec_name,duration,disposition:format=duration,format_name',
        '-of', 'json', $Path
    )
    $lines = & $script:ProbeExe @probeArgs 2>$null
    $code = $LASTEXITCODE
    if ($code -ne 0) { throw "ffprobe failed (exit $code)." }
    $json = ($lines -join "`n")
    if ([string]::IsNullOrWhiteSpace($json)) { throw 'ffprobe returned empty output.' }
    return ConvertFrom-Json -InputObject $json -ErrorAction Stop
}

function Inspect-Media([string]$Path) {
    $data = Read-Probe $Path
    $streams = @($data.streams | Where-Object { $null -ne $_ })
    $videos = @($streams | Where-Object {
        $_.codec_type -eq 'video' -and $_.disposition.attached_pic -ne 1
    })
    $audios = @($streams | Where-Object { $_.codec_type -eq 'audio' })
    $type = 'Mixed'
    $track = $null
    if ($videos.Count -eq 1 -and $audios.Count -eq 0) {
        $type = 'Video'; $track = $videos[0]
    } elseif ($audios.Count -eq 1 -and $videos.Count -eq 0) {
        $type = 'Audio'; $track = $audios[0]
    }
    $seconds = $null
    $index = $null
    $codec = $null
    if ($null -ne $track) {
        $seconds = Read-Seconds $track.duration
        $index = [int]$track.index
        $codec = [string]$track.codec_name
    }
    if ($null -eq $seconds) { $seconds = Read-Seconds $data.format.duration }
    return [pscustomobject]@{
        Path = $Path; Kind = $type; Index = $index
        Codec = $codec; Duration = $seconds
    }
}

function New-Pair($Video, $Audio, [string]$Destination, [string]$Source) {
    return [pscustomobject]@{
        Video = $Video; Audio = $Audio
        Destination = $Destination; Source = $Source
    }
}

function Test-Output([string]$Temp, $Pair, [bool]$Decode) {
    $info = Read-Probe $Temp
    $tracks = @($info.streams | Where-Object { $null -ne $_ })
    $videos = @($tracks | Where-Object { $_.codec_type -eq 'video' })
    $audios = @($tracks | Where-Object { $_.codec_type -eq 'audio' })
    $container = [string]$info.format.format_name
    if ($tracks.Count -ne 2 -or $videos.Count -ne 1 -or $audios.Count -ne 1 -or
        $videos[0].codec_name -ne $Pair.Video.Codec -or
        $audios[0].codec_name -ne $Pair.Audio.Codec -or
        $container -notmatch '(^|,)mp4(,|$)') {
        throw 'Output track/codec/container verification failed.'
    }
    if ((Get-Item -LiteralPath $Temp).Length -le 0) { throw 'Output is empty.' }

    foreach ($element in @(
        [pscustomobject]@{ Input = $Pair.Video; Output = $videos[0] },
        [pscustomobject]@{ Input = $Pair.Audio; Output = $audios[0] }
    )) {
        $original = $element.Input.Duration
        $produced = Read-Seconds $element.Output.duration
        if ($null -ne $original -and $null -ne $produced) {
            $tolerance = [math]::Max(2.0, ([double]$original * 0.001))
            if ([math]::Abs([double]$produced - [double]$original) -gt $tolerance) {
                throw "Unexpected $($element.Input.Kind) duration in output."
            }
        }
    }
    if ($Decode) {
        $decodeArgs = @(
            '-hide_banner', '-nostdin', '-v', 'error', '-xerror',
            '-i', $Temp, '-map', '0:v:0', '-map', '0:a:0', '-f', 'null', '-'
        )
        & $script:FfmpegExe @decodeArgs 2>&1 | Out-Host
        if ($LASTEXITCODE -ne 0) { throw 'Full decode verification failed.' }
    }
}

function Run-Pair($Pair, [string]$Root, [string]$OutputRoot) {
    $video = $Pair.Video
    $audio = $Pair.Audio
    $destination = $Pair.Destination
    $relativeOutput = $destination.Substring($OutputRoot.TrimEnd([char[]]@('\', '/')).Length).TrimStart([char[]]@('\', '/'))
    Write-Host "`n[$($Pair.Source)] $([IO.Path]::GetFileName($video.Path)) + $([IO.Path]::GetFileName($audio.Path))"
    Write-Host "  -> $relativeOutput [$($video.Codec) + $($audio.Codec)]"

    if (-not (Is-Inside $destination $OutputRoot)) {
        Write-Warning '输出路径超出了目标目录。'
        return 'Failed'
    }
    if ($null -ne $video.Duration -and $null -ne $audio.Duration) {
        $gap = [math]::Abs([double]$video.Duration - [double]$audio.Duration)
        if ($gap -gt $MaxGapSeconds) {
            if (-not $AllowDurationMismatch) {
                Write-Warning ("音视频时长相差 {0:N3} 秒，超过阈值 {1:N3} 秒，已跳过。" -f $gap, $MaxGapSeconds)
                return 'Failed'
            }
            Write-Warning ("音视频时长相差 {0:N3} 秒，按参数要求继续。" -f $gap)
        }
    } else {
        Write-Warning '至少一条轨道缺少时长信息，无法执行时长差检查。'
    }

    if (Test-Path -LiteralPath $destination) {
        if (-not $Force) {
            Write-Host '  跳过：输出文件已存在。如需覆盖，请明确使用 -Force。'
            return 'Existing'
        }
        if (-not (Test-Path -LiteralPath $destination -PathType Leaf)) {
            Write-Warning '输出路径并非普通文件。'
            return 'Failed'
        }
        $existingItem = Get-Item -LiteralPath $destination -Force
        if (($existingItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            Write-Warning '拒绝覆盖符号链接或重解析点文件。'
            return 'Failed'
        }
    }
    if ($Preview) {
        Write-Host '  预览通过，未写入文件。'
        return 'Preview'
    }

    $parent = [IO.Path]::GetDirectoryName($destination)
    $temp = Join-Path $parent ('.' + [IO.Path]::GetFileNameWithoutExtension($destination) +
        '.' + [Guid]::NewGuid().ToString('N') + '.partial.mp4')
    try {
        [IO.Directory]::CreateDirectory($parent) | Out-Null
        Write-Host '  正在封装（直接复制原始音视频流）……'
        $ffArgs = @(
            '-hide_banner', '-nostdin', '-loglevel', 'warning', '-n',
            '-i', $video.Path, '-i', $audio.Path,
            '-map', ('0:' + $video.Index), '-map', ('1:' + $audio.Index),
            '-c', 'copy', '-map_metadata', '0', '-map_chapters', '-1',
            '-disposition:a:0', 'default', '-movflags', '+faststart',
            '-f', 'mp4', $temp
        )
        & $script:FfmpegExe @ffArgs
        if ($LASTEXITCODE -ne 0) { throw "ffmpeg failed (exit $LASTEXITCODE)." }
        Test-Output $temp $Pair ([bool]$VerifyDecode)

        # On Windows, File.Move refuses to replace a pre-existing file.
        # File.Replace is atomic if -Force was explicitly requested.
        if (Test-Path -LiteralPath $destination) {
            if (-not $Force) { throw '封装期间另一个进程创建了同名文件，拒绝覆盖。' }
            [IO.File]::Replace($temp, $destination, $null)
        } else {
            [IO.File]::Move($temp, $destination)
        }
        $sizeMiB = (Get-Item -LiteralPath $destination).Length / 1MB
        Write-Host ("  完成：{0}（{1:N2} MiB）" -f $relativeOutput, $sizeMiB) -ForegroundColor Green
        return 'Success'
    } catch {
        Write-Warning ("封装失败：{0}" -f $_.Exception.Message)
        return 'Failed'
    } finally {
        if (Test-Path -LiteralPath $temp -PathType Leaf) {
            Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        }
    }
}

# Main entry point.
if ([string]::IsNullOrWhiteSpace($InputDir)) { $InputDir = $PSScriptRoot }
try {
    $root = Normalize-Path $InputDir
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        throw "扫描目录不存在：$root"
    }
    if ([IO.Path]::IsPathRooted($OutputDir)) {
        $outputRoot = Normalize-Path $OutputDir
    } else {
        $outputRoot = Normalize-Path (Join-Path $root $OutputDir)
    }
    if ($outputRoot.Equals($root, [StringComparison]::OrdinalIgnoreCase)) {
        throw '扫描目录和输出目录必须不同。'
    }
    if ([double]::IsNaN($MaxGapSeconds) -or [double]::IsInfinity($MaxGapSeconds) -or
        $MaxGapSeconds -lt 0) { throw '-MaxGapSeconds 必须是非负的有限数值。' }

    $script:FfmpegExe = Find-Executable 'ffmpeg'
    $script:ProbeExe = Find-Executable 'ffprobe'
    if (-not $script:FfmpegExe -or -not $script:ProbeExe) {
        throw '找不到 ffmpeg.exe 或 ffprobe.exe。请放到脚本旁边或加入 PATH。'
    }

    Write-Host "扫描目录：$root"
    Write-Host "输出目录：$outputRoot"
    $mediaByPath = @{}
    $files = @(Get-ChildItem -LiteralPath $root -File -Recurse:$Recurse -ErrorAction Stop |
        Sort-Object FullName)
    foreach ($file in $files) {
        if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            -not $script:AllowedExtensions.ContainsKey($file.Extension) -or
            (Is-Inside $file.FullName $outputRoot)) { continue }
        try {
            $media = Inspect-Media $file.FullName
            $mediaByPath[$file.FullName] = $media
            if ($media.Kind -eq 'Mixed') {
                Write-Host "[忽略] 已含音画、多轨道或无法识别：$($file.Name)"
            }
        } catch {
            Write-Warning ("[忽略] 无法检查 {0}：{1}" -f $file.Name, $_.Exception.Message)
        }
    }
    Write-Host ("已探测媒体文件：{0}" -f $mediaByPath.Count)

    $pairs = [System.Collections.Generic.List[object]]::new()
    $used = @{}
    $issues = 0
    if (-not [string]::IsNullOrWhiteSpace($Manifest)) {
        $csvPath = $Manifest
        if (-not [IO.Path]::IsPathRooted($csvPath)) { $csvPath = Join-Path $root $csvPath }
        $rows = @(Import-Csv -LiteralPath $csvPath -Encoding UTF8 -ErrorAction Stop)
        if ($rows.Count -gt 0 -and
            (-not ($rows[0].PSObject.Properties.Name -contains 'video') -or
             -not ($rows[0].PSObject.Properties.Name -contains 'audio'))) {
            throw 'CSV 必须包含 video,audio 列，output 为可选列。'
        }
        $line = 1
        foreach ($row in $rows) {
            $line++
            try {
                $vPath = Resolve-Child $root ([string]$row.video) 'video'
                $aPath = Resolve-Child $root ([string]$row.audio) 'audio'
                if (-not $mediaByPath.ContainsKey($vPath) -or
                    -not $mediaByPath.ContainsKey($aPath)) { throw '找不到有效的输入媒体文件。' }
                $v = $mediaByPath[$vPath]; $a = $mediaByPath[$aPath]
                if ($v.Kind -ne 'Video' -or $a.Kind -ne 'Audio') {
                    throw 'CSV 指定的 video/audio 轨道类型不正确。'
                }
                if ($used.ContainsKey($vPath) -or $used.ContainsKey($aPath)) {
                    throw '同一输入文件在 CSV 中重复配对。'
                }
                $outputName = [string]$row.output
                if ([string]::IsNullOrWhiteSpace($outputName)) {
                    $outputName = [IO.Path]::GetFileNameWithoutExtension($vPath) + '.mp4'
                }
                if (-not $outputName.EndsWith('.mp4', [StringComparison]::OrdinalIgnoreCase)) {
                    $outputName += '.mp4'
                }
                $target = Resolve-Child $outputRoot $outputName 'output'
                $pairs.Add((New-Pair $v $a $target 'CSV'))
                $used[$vPath] = $true; $used[$aPath] = $true
            } catch {
                $issues++
                Write-Warning ("CSV 第 {0} 行已跳过：{1}" -f $line, $_.Exception.Message)
            }
        }
    }

    $groups = @{}
    foreach ($media in $mediaByPath.Values) {
        if ($used.ContainsKey($media.Path) -or $media.Kind -eq 'Mixed') { continue }
        $folderKey = [IO.Path]::GetDirectoryName($media.Path)
        $stem = [IO.Path]::GetFileNameWithoutExtension($media.Path)
        $stem = $stem.Normalize([Text.NormalizationForm]::FormC)
        $key = $folderKey + [char]0 + $stem
        if (-not $groups.ContainsKey($key)) {
            $groups[$key] = [System.Collections.Generic.List[object]]::new()
        }
        $groups[$key].Add($media)
    }
    foreach ($key in @($groups.Keys | Sort-Object)) {
        $group = @($groups[$key].ToArray())
        $videos = @($group | Where-Object { $_.Kind -eq 'Video' })
        $audios = @($group | Where-Object { $_.Kind -eq 'Audio' })
        if ($videos.Count -eq 1 -and $audios.Count -eq 1) {
            $v = $videos[0]; $a = $audios[0]
            $relativeDir = $v.Path.Substring($root.TrimEnd([char[]]@('\', '/')).Length).TrimStart([char[]]@('\', '/'))
            $relativeDir = [IO.Path]::GetDirectoryName($relativeDir)
            $outputName = [IO.Path]::GetFileNameWithoutExtension($v.Path) + '.mp4'
            $targetDir = $outputRoot
            if ($relativeDir) { $targetDir = Join-Path $outputRoot $relativeDir }
            $target = Join-Path $targetDir $outputName
            $pairs.Add((New-Pair $v $a $target 'AUTO'))
        } elseif ($videos.Count -gt 0 -and $audios.Count -gt 0) {
            $issues++
            $stemLabel = [IO.Path]::GetFileNameWithoutExtension($group[0].Path)
            Write-Warning ("同名存在歧义：{0}（{1} 条视频、{2} 条音频）。" -f $stemLabel, $videos.Count, $audios.Count)
        } else {
            foreach ($item in $group) {
                Write-Host "[未配对] $([IO.Path]::GetFileName($item.Path)) [$($item.Kind)]"
            }
        }
    }

    if ($pairs.Count -eq 0) {
        Write-Warning '没有找到文件对。请确认去掉扩展名后同名，或使用 -Manifest pairs.csv。'
        exit 1
    }
    $destCounts = @{}
    foreach ($pair in $pairs) {
        $key = $pair.Destination.Normalize([Text.NormalizationForm]::FormC)
        if (-not $destCounts.ContainsKey($key)) { $destCounts[$key] = 0 }
        $destCounts[$key]++
    }
    $summary = @{ Success = 0; Failed = $issues; Existing = 0; Preview = 0 }
    foreach ($pair in $pairs) {
        $key = $pair.Destination.Normalize([Text.NormalizationForm]::FormC)
        if ($destCounts[$key] -gt 1) {
            Write-Warning ("多组输入映射到了同一输出：{0}" -f $pair.Destination)
            $summary.Failed++
            continue
        }
        if ($mediaByPath.ContainsKey($pair.Destination)) {
            Write-Warning ("输出将覆盖某个源文件，已禁止：{0}" -f $pair.Destination)
            $summary.Failed++
            continue
        }
        try {
            $result = Run-Pair $pair $root $outputRoot
        } catch {
            Write-Warning ("当前配对失败，继续下一对：{0}" -f $_.Exception.Message)
            $result = 'Failed'
        }
        $summary[$result]++
    }
    $summaryText = "`n结果：完成={0}，预览={1}，已存在={2}，失败或歧义={3}"
    Write-Host ($summaryText -f $summary.Success, $summary.Preview, $summary.Existing, $summary.Failed)
    if ($summary.Failed -gt 0) { exit 1 }
    exit 0
} catch {
    Write-Host ("错误：{0}" -f $_.Exception.Message) -ForegroundColor Red
    exit 2
}
