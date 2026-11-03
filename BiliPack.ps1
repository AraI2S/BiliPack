# BiliPack - lossless MP4 muxing of separated video/audio files.
# Requires Windows PowerShell 5.1+ and ffmpeg.exe / ffprobe.exe.
# Run Main.bat and enter a source directory. Outputs go to <source>\Merged.
param(
    [string]$InputDir = '',
    [switch]$Recursive,
    [string]$Manifest = '',
    [switch]$DryRun,
    [switch]$Overwrite,
    [switch]$VerifyDecode,
    [ValidateRange(0, 86400)][double]$MaxGap = 2.0,
    [switch]$AllowDurationMismatch
)

$ErrorActionPreference = 'Stop'
$script:Invariant = [System.Globalization.CultureInfo]::InvariantCulture
$script:KeyComparison = [System.StringComparison]::OrdinalIgnoreCase

function Find-Tool([string]$ToolName) {
    $local = Join-Path $PSScriptRoot ($ToolName + '.exe')
    if (Test-Path -LiteralPath $local -PathType Leaf) { return $local }
    $found = Get-Command ($ToolName + '.exe') -CommandType Application -ErrorAction SilentlyContinue
    if ($null -ne $found) { return $found.Source }
    $found = Get-Command $ToolName -CommandType Application -ErrorAction SilentlyContinue
    if ($null -ne $found) { return $found.Source }
    throw "找不到 $ToolName.exe；请将 ffmpeg.exe 和 ffprobe.exe 放在脚本旁边，或加入 PATH。"
}

function Name-Key([string]$Value) {
    return $Value.Normalize([System.Text.NormalizationForm]::FormC).ToUpperInvariant()
}

function Is-Under([string]$Child, [string]$Parent) {
    $p = $Parent.TrimEnd([char[]]@('\', '/'))
    return $Child.Equals($p, $script:KeyComparison) -or
        $Child.StartsWith(($p + [System.IO.Path]::DirectorySeparatorChar), $script:KeyComparison)
}

function Safe-Relative([string]$Value, [string]$Description, [string]$BaseDirectory) {
    $raw = $Value.Trim()
    if ([string]::IsNullOrWhiteSpace($raw) -or [System.IO.Path]::IsPathRooted($raw)) {
        throw "$Description 必须是非空相对路径：$Value"
    }
    $parts = $raw -split '[\\/]'
    if ($parts -contains '..' -or $parts -contains '.') {
        throw "$Description 不能包含 . 或 .. 路径段：$Value"
    }
    $full = [System.IO.Path]::GetFullPath((Join-Path $BaseDirectory $raw))
    if (-not (Is-Under $full $BaseDirectory)) { throw "$Description 超出指定目录：$Value" }
    return $full
}

function Read-PositiveNumber($Raw) {
    $value = 0.0
    if ([double]::TryParse([string]$Raw, [System.Globalization.NumberStyles]::Float,
        $script:Invariant, [ref]$value) -and
        -not [double]::IsNaN($value) -and -not [double]::IsInfinity($value) -and $value -gt 0) {
        return $value
    }
    return $null
}

function Probe-Media([System.IO.FileInfo]$File) {
    try {
        $lines = & $script:FFprobe '-v' 'error' '-show_streams' '-show_format' '-of' 'json' $File.FullName 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $lines) { return $null }
        $obj = ($lines -join "`n") | ConvertFrom-Json
        $videos = @($obj.streams | Where-Object {
            $_.codec_type -eq 'video' -and $_.disposition.attached_pic -ne 1
        })
        $audios = @($obj.streams | Where-Object { $_.codec_type -eq 'audio' })
        if ($videos.Count -eq 1 -and $audios.Count -eq 0) {
            $chosen = $videos[0]; $kind = 'video'
        } elseif ($audios.Count -eq 1 -and $videos.Count -eq 0) {
            $chosen = $audios[0]; $kind = 'audio'
        } else { return $null }
        $duration = Read-PositiveNumber $chosen.duration
        if ($null -eq $duration) { $duration = Read-PositiveNumber $obj.format.duration }
        return [pscustomobject]@{
            File = $File
            Path = $File.FullName
            Kind = $kind
            Index = [int]$chosen.index
            Codec = [string]$chosen.codec_name
            Duration = $duration
        }
    } catch { return $null }
}

function Add-Group([hashtable]$Groups, [string]$Key, $Entry) {
    if (-not $Groups.ContainsKey($Key)) {
        $Groups[$Key] = [System.Collections.ArrayList]::new()
    }
    [void]$Groups[$Key].Add($Entry)
}

function New-Pair($Video, $Audio, [string]$Destination, [string]$Source) {
    return [pscustomobject]@{
        Video = $Video
        Audio = $Audio
        Destination = $Destination
        Source = $Source
    }
}

function Show-Progress([string]$Stage, [int]$Done, [int]$Count, [double]$Fraction = 0) {
    if ($Count -le 0) { return }
    $pct = 100.0 * (($Done + [Math]::Max(0, [Math]::Min(1, $Fraction))) / $Count)
    Write-Progress -Id 1 -Activity ("BiliPack | " + $Stage) -Status (
        ('{0}/{1} | 总体 {2:N1}%' -f $Done, $Count, $pct)) -PercentComplete ([int][Math]::Min(100, $pct))
}

function Check-Output($OutputPath, $Pair, [bool]$FullDecode) {
    $lines = & $script:FFprobe '-v' 'error' '-show_streams' '-show_format' '-of' 'json' $OutputPath 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $lines) { throw 'ffprobe 无法读取封装结果' }
    $obj = ($lines -join "`n") | ConvertFrom-Json
    $streams = @($obj.streams)
    $vs = @($streams | Where-Object { $_.codec_type -eq 'video' })
    $as = @($streams | Where-Object { $_.codec_type -eq 'audio' })
    if ($streams.Count -ne 2 -or $vs.Count -ne 1 -or $as.Count -ne 1 -or
        $vs[0].codec_name -ne $Pair.Video.Codec -or
        $as[0].codec_name -ne $Pair.Audio.Codec -or
        $obj.format.format_name -notmatch 'mp4') {
        throw '输出轨道、编码或 MP4 容器校验失败'
    }
    if ((Get-Item -LiteralPath $OutputPath).Length -eq 0) { throw '输出文件为空' }
    $actualStreams = @($vs[0], $as[0])
    $sourceStreams = @($Pair.Video, $Pair.Audio)
    for ($j = 0; $j -lt 2; $j++) {
        $actual = Read-PositiveNumber $actualStreams[$j].duration
        $expected = $sourceStreams[$j].Duration
        if ($null -ne $expected -and $null -ne $actual -and
            [Math]::Abs($actual - $expected) -gt [Math]::Max(2.0, $expected * 0.001)) {
            throw '封装结果中的轨道时长异常'
        }
    }
    if ($FullDecode) {
        & $script:FFmpeg '-hide_banner' '-nostdin' '-v' 'error' '-xerror' '-i' $OutputPath '-map' '0:v:0' '-map' '0:a:0' '-f' 'null' '-' 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { throw '完整解码校验失败' }
    }
}

function Check-OutputParents([string]$Destination, [string]$OutputRoot) {
    $dir = [System.IO.Path]::GetDirectoryName($Destination)
    if (-not (Is-Under $dir $OutputRoot)) { throw '输出路径超出 Merged 目录' }
    while ((Is-Under $dir $OutputRoot) -and (Test-Path -LiteralPath $dir)) {
        $item = Get-Item -LiteralPath $dir -Force
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw '输出路径包含符号链接或目录联接，已拒绝写入'
        }
        if ($dir.Equals($OutputRoot, $script:KeyComparison)) { break }
        $dir = [System.IO.Path]::GetDirectoryName($dir)
    }
}

function Mux-One($Pair, [int]$Done, [int]$Total, [string]$OutputRoot) {
    $target = $Pair.Destination
    $name = [System.IO.Path]::GetFileName($target)
    Write-Host ('[' + $Pair.Source + '] ' + $Pair.Video.File.Name + ' + ' + $Pair.Audio.File.Name + ' -> ' + $name)
    if ($null -ne $Pair.Video.Duration -and $null -ne $Pair.Audio.Duration) {
        $delta = [Math]::Abs($Pair.Video.Duration - $Pair.Audio.Duration)
        if ($delta -gt $MaxGap -and -not $AllowDurationMismatch) {
            Write-Host ('  [跳过] 音视频时长相差 {0:N3} 秒，超过 {1:N3} 秒' -f $delta, $MaxGap)
            return 'failed'
        }
        if ($delta -gt $MaxGap) { Write-Host ('  [注意] 音视频时长相差 {0:N3} 秒' -f $delta) }
    } else { Write-Host '  [注意] 无法取得两条轨道的完整时长信息' }
    Check-OutputParents $target $OutputRoot
    if (Test-Path -LiteralPath $target) {
        $existing = Get-Item -LiteralPath $target -Force
        if (($existing.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw '输出文件是符号链接，已拒绝覆盖'
        }
    }
    if ((Test-Path -LiteralPath $target) -and -not $Overwrite) {
        Write-Host '  [跳过] 输出已存在；原文件不变'
        return 'existing'
    }
    if ($DryRun) { Write-Host '  [预览] 可以封装'; return 'dry' }
    $parent = [System.IO.Path]::GetDirectoryName($target)
    if (-not [System.IO.Directory]::Exists($parent)) { [void][System.IO.Directory]::CreateDirectory($parent) }
    Check-OutputParents $target $OutputRoot
    $tmp = Join-Path $parent ('.' + $name + '.' + [guid]::NewGuid().ToString('N') + '.partial.mp4')
    $log = [System.IO.Path]::GetTempFileName()
    try {
        $ffargs = @(
            '-hide_banner', '-nostdin', '-loglevel', 'error', '-stats_period', '0.5',
            '-progress', 'pipe:1', '-n',
            '-i', $Pair.Video.Path, '-i', $Pair.Audio.Path,
            '-map', ('0:' + $Pair.Video.Index), '-map', ('1:' + $Pair.Audio.Index),
            '-c', 'copy', '-map_metadata', '0', '-map_chapters', '-1',
            '-disposition:a:0', 'default', '-movflags', '+faststart',
            '-f', 'mp4', $tmp
        )
        $duration = $Pair.Video.Duration
        if ($null -eq $duration) { $duration = $Pair.Audio.Duration }
        & $script:FFmpeg @ffargs 2> $log | ForEach-Object {
            $line = [string]$_
            if ($line.StartsWith('out_time=')) {
                $value = $line.Substring(9)
                $ts = [timespan]::Zero
                if ($duration -gt 0 -and [timespan]::TryParse($value, $script:Invariant, [ref]$ts)) {
                    Show-Progress '封装中' $Done $Total ([Math]::Min(0.99, $ts.TotalSeconds / $duration))
                }
            }
        }
        if ($LASTEXITCODE -ne 0) {
            $errors = @(Get-Content -LiteralPath $log -ErrorAction SilentlyContinue | Select-Object -Last 8)
            throw ('FFmpeg 失败：' + ($errors -join ' '))
        }
        Check-Output $tmp $Pair ([bool]$VerifyDecode)
        if (Test-Path -LiteralPath $target) {
            if (-not $Overwrite) { throw '封装期间已有其他程序创建同名输出' }
            if ((Get-Item -LiteralPath $target).PSIsContainer) { throw '输出位置已被目录占用' }
            [System.IO.File]::Replace($tmp, $target, $null)
        } else {
            [System.IO.File]::Move($tmp, $target)
        }
        $miB = (Get-Item -LiteralPath $target).Length / 1MB
        Write-Host ('  [完成] {0} ({1:N2} MiB)' -f $target, $miB)
        return 'success'
    } catch {
        Write-Host ('  [失败] ' + $_.Exception.Message) -ForegroundColor Red
        return 'failed'
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $log) { Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue }
    }
}

try {
    if ([string]::IsNullOrWhiteSpace($InputDir)) {
        while ($true) {
            Write-Host ''
            $entered = Read-Host '请输入素材目录（粘贴路径，直接回车退出）'
            if ([string]::IsNullOrWhiteSpace($entered)) { exit 0 }
            $entered = $entered.Trim().Trim([char[]]@('"', "'"))
            if (Test-Path -LiteralPath $entered -PathType Container) { $InputDir = $entered; break }
            Write-Host '[错误] 目录不存在，请重新输入。' -ForegroundColor Yellow
        }
    }
    if (-not (Test-Path -LiteralPath $InputDir -PathType Container)) {
        throw '指定目录不存在或无法访问'
    }
    $root = (Get-Item -LiteralPath $InputDir -Force).FullName
    $output = Join-Path $root 'Merged'
    $script:FFmpeg = Find-Tool 'ffmpeg'
    $script:FFprobe = Find-Tool 'ffprobe'
    if (Test-Path -LiteralPath $output) {
        if (-not (Test-Path -LiteralPath $output -PathType Container)) { throw '目标目录下的 Merged 已被文件占用' }
        Check-OutputParents (Join-Path $output 'test.mp4') $output
    }
    Write-Host ''
    Write-Host ('素材目录：' + $root)
    Write-Host ('输出目录：' + $output)
    Write-Host '规则：同名，或文件名末尾 v（视频）与 a（音频）；均忽略扩展名和大小写'
    Write-Host ''

    # Enumerate directories ourselves so Merged and junctions are never traversed.
    $fileList = [System.Collections.ArrayList]::new()
    $pending = [System.Collections.Generic.Stack[string]]::new()
    $pending.Push($root)
    while ($pending.Count -gt 0) {
        $current = $pending.Pop()
        foreach ($item in @(Get-ChildItem -LiteralPath $current -Force)) {
            if ((Is-Under $item.FullName $output) -or
                (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) { continue }
            if ($item.PSIsContainer) {
                if ($Recursive) { $pending.Push($item.FullName) }
            } else { [void]$fileList.Add($item) }
        }
    }
    $files = $fileList.ToArray()
    $exactGroups = @{}
    $avGroups = @{}
    foreach ($f in $files) {
        $parentKey = Name-Key $f.DirectoryName
        $stemKey = Name-Key $f.BaseName
        Add-Group $exactGroups ($parentKey + [char]0 + $stemKey) $f
        if ($stemKey.Length -ge 2) {
            $letter = $stemKey.Substring($stemKey.Length - 1)
            if ($letter -eq 'V' -or $letter -eq 'A') {
                $common = $stemKey.Substring(0, $stemKey.Length - 1)
                Add-Group $avGroups ($parentKey + [char]0 + $common) $f
            }
        }
    }

    # Only probe files with plausible matching names, plus explicit CSV inputs.
    $candidates = @{}
    foreach ($group in $exactGroups.Values) {
        if ($group.Count -ge 2) { foreach ($f in $group) { $candidates[$f.FullName] = $f } }
    }
    foreach ($group in $avGroups.Values) {
        $names = @($group | ForEach-Object { (Name-Key $_.BaseName) })
        if (@($names | Where-Object { $_.EndsWith('V') }).Count -gt 0 -and
            @($names | Where-Object { $_.EndsWith('A') }).Count -gt 0) {
            foreach ($f in $group) { $candidates[$f.FullName] = $f }
        }
    }

    $csvRows = @()
    if (-not [string]::IsNullOrWhiteSpace($Manifest)) {
        $manifestPath = $Manifest
        if (-not [System.IO.Path]::IsPathRooted($manifestPath)) {
            $manifestPath = Join-Path $root $manifestPath
        }
        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'CSV 清单不存在' }
        $csvRows = @(Import-Csv -LiteralPath $manifestPath -Encoding UTF8)
        if ($csvRows.Count -gt 0 -and
            (-not ($csvRows[0].PSObject.Properties.Name -contains 'video') -or
             -not ($csvRows[0].PSObject.Properties.Name -contains 'audio'))) {
            throw 'CSV 表头必须含有 video,audio，output 可选'
        }
        foreach ($row in $csvRows) {
            foreach ($col in @('video', 'audio')) {
                $rel = [string]$row.$col
                $path = Safe-Relative $rel $col $root
                if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "CSV 中的文件不存在：$rel" }
                $f = Get-Item -LiteralPath $path
                $candidates[$f.FullName] = $f
            }
        }
    }

    $media = @{}
    $scan = @($candidates.Values | Sort-Object FullName)
    for ($i = 0; $i -lt $scan.Count; $i++) {
        Show-Progress '检查媒体轨道' $i $scan.Count
        $m = Probe-Media $scan[$i]
        if ($null -ne $m) { $media[$m.Path] = $m }
    }
    Write-Progress -Id 1 -Activity 'BiliPack | 检查媒体轨道' -Completed
    Write-Host ('发现 {0} 个潜在素材，确认 {1} 个单独音轨/视频轨文件。' -f $scan.Count, $media.Count)

    $pairs = [System.Collections.ArrayList]::new()
    $usedCsv = @{}
    foreach ($row in $csvRows) {
        $vPath = Safe-Relative ([string]$row.video) 'video' $root
        $aPath = Safe-Relative ([string]$row.audio) 'audio' $root
        if (-not $media.ContainsKey($vPath) -or -not $media.ContainsKey($aPath) -or
            $media[$vPath].Kind -ne 'video' -or $media[$aPath].Kind -ne 'audio') {
            throw ('CSV 的音视频轨道类型不符：' + $row.video + ' / ' + $row.audio)
        }
        if ($usedCsv.ContainsKey($vPath) -or $usedCsv.ContainsKey($aPath)) {
            throw 'CSV 中的源文件重复使用'
        }
        $outName = [string]$row.output
        if ([string]::IsNullOrWhiteSpace($outName)) {
            $outName = $media[$vPath].File.BaseName + '.mp4'
        }
        if (-not $outName.EndsWith('.mp4', [System.StringComparison]::OrdinalIgnoreCase)) {
            $outName += '.mp4'
        }
        $dest = Safe-Relative $outName 'output' $output
        [void]$pairs.Add((New-Pair $media[$vPath] $media[$aPath] $dest 'CSV'))
        $usedCsv[$vPath] = $true
        $usedCsv[$aPath] = $true
    }

    $auto = [System.Collections.ArrayList]::new()
    $ambiguous = 0
    foreach ($group in $exactGroups.Values) {
        $items = @($group | Where-Object { $media.ContainsKey($_.FullName) -and -not $usedCsv.ContainsKey($_.FullName) } |
            ForEach-Object { $media[$_.FullName] })
        $vs = @($items | Where-Object { $_.Kind -eq 'video' })
        $as = @($items | Where-Object { $_.Kind -eq 'audio' })
        if ($vs.Count -eq 1 -and $as.Count -eq 1) {
            $parentRel = $vs[0].File.DirectoryName.Substring($root.Length).TrimStart([char[]]@('\','/'))
            $dir = if ($parentRel) { Join-Path $output $parentRel } else { $output }
            [void]$auto.Add((New-Pair $vs[0] $as[0] (Join-Path $dir ($vs[0].File.BaseName + '.mp4')) '同名'))
        } elseif ($vs.Count -gt 0 -and $as.Count -gt 0) {
            $ambiguous++
            Write-Host ('[歧义] 同名素材有多条视频或音频候选：' + $group[0].BaseName)
        }
    }
    foreach ($group in $avGroups.Values) {
        $items = @($group | Where-Object { $media.ContainsKey($_.FullName) -and -not $usedCsv.ContainsKey($_.FullName) } |
            ForEach-Object { $media[$_.FullName] })
        $vs = @($items | Where-Object { $_.Kind -eq 'video' -and (Name-Key $_.File.BaseName).EndsWith('V') })
        $as = @($items | Where-Object { $_.Kind -eq 'audio' -and (Name-Key $_.File.BaseName).EndsWith('A') })
        if ($vs.Count -eq 1 -and $as.Count -eq 1) {
            $parentRel = $vs[0].File.DirectoryName.Substring($root.Length).TrimStart([char[]]@('\','/'))
            $dir = if ($parentRel) { Join-Path $output $parentRel } else { $output }
            $prefix = $vs[0].File.BaseName.Substring(0, $vs[0].File.BaseName.Length - 1)
            [void]$auto.Add((New-Pair $vs[0] $as[0] (Join-Path $dir ($prefix + '.mp4')) 'a/v'))
        } elseif ($vs.Count -gt 0 -and $as.Count -gt 0) {
            $ambiguous++
            Write-Host ('[歧义] a/v 素材有多条视频或音频候选：' + $group[0].BaseName)
        }
    }

    # If a file participates in multiple auto matches, do not guess.
    $sourceUses = @{}
    foreach ($p in $auto) {
        foreach ($path in @($p.Video.Path, $p.Audio.Path)) {
            if (-not $sourceUses.ContainsKey($path)) { $sourceUses[$path] = 0 }
            $sourceUses[$path]++
        }
    }
    foreach ($p in $auto) {
        if ($sourceUses[$p.Video.Path] -gt 1 -or $sourceUses[$p.Audio.Path] -gt 1) {
            $ambiguous++
            Write-Host ('[歧义] 文件同时符合多个配对规则，已跳过：' + $p.Video.File.Name)
        } else { [void]$pairs.Add($p) }
    }

    if ($pairs.Count -eq 0) {
        Write-Host '没有找到有效文件对。请检查文件名、实际轨道类型，或提供 CSV 手动清单。'
        if ($ambiguous -gt 0) { exit 1 }
        exit 0
    }
    $destUses = @{}
    foreach ($p in $pairs) {
        $k = Name-Key $p.Destination
        if (-not $destUses.ContainsKey($k)) { $destUses[$k] = 0 }
        $destUses[$k]++
    }
    $results = @{ success = 0; failed = $ambiguous; existing = 0; dry = 0 }
    for ($i = 0; $i -lt $pairs.Count; $i++) {
        $p = $pairs[$i]
        Show-Progress '封装中' $i $pairs.Count
        if ($destUses[(Name-Key $p.Destination)] -gt 1) {
            Write-Host ('[歧义] 多组素材指向同一个输出，已跳过：' + $p.Destination)
            $results.failed++
            continue
        }
        if ($media.ContainsKey($p.Destination)) {
            Write-Host ('[禁止] 输出路径与输入素材重合：' + $p.Destination)
            $results.failed++
            continue
        }
        try {
            $status = Mux-One $p $i $pairs.Count $output
            $results[$status]++
        } catch {
            $results.failed++
            Write-Host ('[失败] ' + $_.Exception.Message) -ForegroundColor Red
        }
    }
    Write-Progress -Id 1 -Activity 'BiliPack | 封装中' -Completed
    Write-Host ''
    Write-Host ('结果：完成 {0}，预览 {1}，已存在 {2}，失败/歧义 {3}' -f
        $results.success, $results.dry, $results.existing, $results.failed)
    if ($results.failed -gt 0) { exit 1 }
    exit 0
} catch {
    Write-Progress -Id 1 -Activity 'BiliPack' -Completed
    Write-Host ('[错误] ' + $_.Exception.Message) -ForegroundColor Red
    exit 2
}
