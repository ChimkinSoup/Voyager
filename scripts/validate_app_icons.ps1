param([string]$IconDirectory = (Join-Path $PSScriptRoot '../output/app-icons'))

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class NativeIconValidation {
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern IntPtr LoadImage(IntPtr instance, string name, uint type, int width, int height, uint flags);
    [DllImport("user32.dll")]
    public static extern bool DestroyIcon(IntPtr handle);
}
'@
$IconDirectory = [IO.Path]::GetFullPath($IconDirectory)
$sizes = @(16, 20, 24, 32, 40, 48, 64, 256)
$densities = @('mdpi', 'hdpi', 'xhdpi', 'xxhdpi', 'xxxhdpi')
$legacy = @(48, 72, 96, 144, 192)
$layers = @(108, 162, 216, 324, 432)
$notification = @(24, 36, 48, 72, 96)
$checks = [Collections.Generic.List[object]]::new()

function Assert([bool]$condition, [string]$message) {
    if (-not $condition) { throw $message }
}

function Check-Png([string]$relative, [int]$size, [string]$kind = '') {
    $path = Join-Path $IconDirectory $relative
    $b = [Drawing.Bitmap]::new($path)
    try {
        Assert ($b.Width -eq $size -and $b.Height -eq $size) "Wrong dimensions: $relative"
        $visible = 0
        $transparent = 0
        $maxRadius = 0.0
        if ($kind) {
            for ($y = 0; $y -lt $size; $y++) {
                for ($x = 0; $x -lt $size; $x++) {
                    $p = $b.GetPixel($x, $y)
                    if ($p.A -eq 0) { $transparent++ }
                    if ($p.A -gt 0) {
                        $visible++
                        if ($kind -eq 'white' -or $kind -eq 'monochrome') {
                            Assert ($p.R -eq 255 -and $p.G -eq 255 -and $p.B -eq 255) "Nonwhite silhouette pixel: $relative at $x,$y"
                        }
                    }
                    if ($p.A -gt 8 -and ($kind -eq 'foreground' -or $kind -eq 'monochrome')) {
                        $radius = [Math]::Sqrt([Math]::Pow($x - $size / 2.0, 2) + [Math]::Pow($y - $size / 2.0, 2))
                        $maxRadius = [Math]::Max($maxRadius, $radius)
                    }
                }
            }
            Assert ($visible -gt 0) "Empty icon: $relative"
            if ($kind -eq 'opaque') {
                for ($y = 0; $y -lt $size; $y++) {
                    for ($x = 0; $x -lt $size; $x++) {
                        Assert ($b.GetPixel($x, $y).A -eq 255) "Nonopaque background/store pixel: $relative"
                    }
                }
            } else {
                Assert ($transparent -gt 0) "Missing transparency: $relative"
            }
            if ($kind -eq 'foreground' -or $kind -eq 'monochrome') {
                # Allow half a pixel for the antialiased boundary at low density.
                Assert ($maxRadius -le (33.0 / 108 * $size + 0.5)) "Art exceeds Android safe circle: $relative"
            }
        }
        $checks.Add([ordered]@{
            file = $relative; width = $size; height = $size; kind = $kind
            maxVisibleRadiusDp = if ($maxRadius) { [Math]::Round($maxRadius * 108 / $size, 3) } else { $null }
            sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        })
    } finally { $b.Dispose() }
}

foreach ($app in @('voyager', 'gaia')) {
    $resource = if ($app -eq 'voyager') { 'ic_launcher' } else { 'ic_gaia' }
    foreach ($n in $sizes) { Check-Png "$app/windows/png/icon-$n.png" $n 'transparent' }
    $icoPath = Join-Path $IconDirectory "$app/windows/$app.ico"
    $stream = [IO.File]::OpenRead($icoPath)
    $reader = [IO.BinaryReader]::new($stream)
    try {
        Assert ($reader.ReadUInt16() -eq 0) 'Invalid ICO reserved field'
        Assert ($reader.ReadUInt16() -eq 1) 'Invalid ICO type'
        Assert ($reader.ReadUInt16() -eq 8) 'ICO must contain all eight sizes'
        $entries = @()
        for ($i = 0; $i -lt 8; $i++) {
            $w = [int]$reader.ReadByte(); if ($w -eq 0) { $w = 256 }
            $h = [int]$reader.ReadByte(); if ($h -eq 0) { $h = 256 }
            $null = $reader.ReadByte(); $null = $reader.ReadByte()
            Assert ($reader.ReadUInt16() -eq 1) 'Unexpected ICO planes'
            Assert ($reader.ReadUInt16() -eq 32) 'ICO frame must be 32-bit'
            $length = $reader.ReadUInt32(); $offset = $reader.ReadUInt32()
            Assert ($w -eq $sizes[$i] -and $h -eq $sizes[$i]) 'Wrong ICO frame dimensions'
            Assert ($offset + $length -le $stream.Length) 'ICO frame extends past EOF'
            $entries += @{ size = $w; length = $length; offset = $offset }
        }
        foreach ($entry in $entries) {
            $stream.Position = $entry.offset
            $data = $reader.ReadBytes($entry.length)
            $frameStream = [IO.MemoryStream]::new($data, $false)
            $frame = [Drawing.Image]::FromStream($frameStream)
            try {
                Assert ($frame.Width -eq $entry.size -and $frame.Height -eq $entry.size) 'ICO embedded frame decode failed'
                $png = [IO.File]::ReadAllBytes((Join-Path $IconDirectory "$app/windows/png/icon-$($entry.size).png"))
                Assert ([Convert]::ToBase64String($data) -eq [Convert]::ToBase64String($png)) 'ICO differs from standalone PNG'
            } finally { $frame.Dispose(); $frameStream.Dispose() }
        }
        # Native LoadImage avoids System.Drawing.Icon's legacy selection of
        # a smaller frame when the directory encodes 256 as a zero byte.
        foreach ($n in $sizes) {
            $handle = [NativeIconValidation]::LoadImage([IntPtr]::Zero, $icoPath, 1, $n, $n, 0x10)
            Assert ($handle -ne [IntPtr]::Zero) "Windows could not load $app ICO at $n"
            try {
                $native = [Drawing.Icon]::FromHandle($handle)
                try { Assert ($native.Width -eq $n -and $native.Height -eq $n) "Windows ICO decode failed at $n" }
                finally { $native.Dispose() }
            } finally { $null = [NativeIconValidation]::DestroyIcon($handle) }
        }
        $checks.Add([ordered]@{ file = "$app/windows/$app.ico"; frames = $sizes; sha256 = (Get-FileHash $icoPath).Hash.ToLowerInvariant() })
    } finally { $reader.Dispose(); $stream.Dispose() }

    Check-Png "$app/masters/icon-1024.png" 1024
    Check-Png "$app/masters/foreground-1024.png" 1024
    Check-Png "$app/masters/background-1024.png" 1024
    Check-Png "$app/masters/adaptive-foreground-432.png" 432 'foreground'
    Check-Png "$app/store/icon-512.png" 512 'opaque'

    for ($d = 0; $d -lt 5; $d++) {
        $mip = "$app/android/res/mipmap-$($densities[$d])/$resource"
        Check-Png "$mip.png" $legacy[$d] 'opaque'
        Check-Png "${mip}_round.png" $legacy[$d] 'transparent'
        Check-Png "${mip}_foreground.png" $layers[$d] 'foreground'
        Check-Png "${mip}_background.png" $layers[$d] 'opaque'
        Check-Png "${mip}_monochrome.png" $layers[$d] 'monochrome'
        Check-Png "$app/android/res/drawable-$($densities[$d])/ic_stat_$app.png" $notification[$d] 'white'
    }
    foreach ($version in @('v26', 'v33')) {
        foreach ($suffix in @('', '_round')) {
            $relative = "$app/android/res/mipmap-anydpi-$version/$resource$suffix.xml"
            [xml]$xml = Get-Content -LiteralPath (Join-Path $IconDirectory $relative) -Raw
            $xmlNs = [Xml.XmlNamespaceManager]::new($xml.NameTable)
            $xmlNs.AddNamespace('android', 'http://schemas.android.com/apk/res/android')
            Assert ($xml.DocumentElement.Name -eq 'adaptive-icon') "Invalid adaptive XML: $relative"
            foreach ($layer in @('foreground', 'background')) {
                $node = $xml.SelectSingleNode("/adaptive-icon/$layer")
                Assert ($null -ne $node) "Missing $layer in $relative"
                Assert ($node.GetAttribute('drawable', $xmlNs.LookupNamespace('android')).EndsWith("${resource}_$layer")) "Wrong resource ref in $relative"
            }
            Assert (($null -ne $xml.SelectSingleNode('/adaptive-icon/monochrome')) -eq ($version -eq 'v33')) "Wrong monochrome version qualifier: $relative"
        }
    }
    $aliasFile = Join-Path $IconDirectory "$app/android/res/values/${app}_icon_background.xml"
    [xml]$alias = Get-Content -LiteralPath $aliasFile -Raw
    Assert ($alias.resources.item.name -eq "${resource}_background") "Wrong background alias name: $app"
    Assert ($alias.resources.item.InnerText -eq "@mipmap/${resource}_background") "Wrong background alias target: $app"
}

for ($d = 0; $d -lt 5; $d++) {
    $v = Get-FileHash (Join-Path $IconDirectory "voyager/android/res/mipmap-$($densities[$d])/ic_launcher_background.png")
    $g = Get-FileHash (Join-Path $IconDirectory "gaia/android/res/mipmap-$($densities[$d])/ic_gaia_background.png")
    Assert ($v.Hash -eq $g.Hash) 'Voyager and Gaia backgrounds must match byte for byte'
}

$report = [ordered]@{
    status = 'passed'
    checkedAssets = $checks.Count
    windowsIcoSizes = $sizes
    notificationRgb = 'white only; transparent background'
    adaptiveSafeCircleDp = 66
    matchingBackgrounds = $true
    resourceXml = 'v26, v33 and background aliases validated'
    deviceOrBuildTest = 'not run; assets have not been integrated'
    files = @($checks.ToArray())
}
$report | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath (Join-Path $IconDirectory 'validation.json') -Encoding UTF8
Write-Output "PASS: $($checks.Count) assets verified; both 8-frame ICO files decoded; adaptive safe zones, white notification alpha and matching backgrounds verified."
