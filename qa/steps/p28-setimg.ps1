# Put an image file on the clipboard as a PNG-format DataObject (PROGRESS.md
# "Image clipboard"). -Text puts plain text instead (no image).
param([string]$Path, [string]$Text)
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
if ($Text) { [System.Windows.Forms.Clipboard]::SetText($Text); 'clipboard: text'; return }
$img = [System.Drawing.Image]::FromFile($Path)
$ms = New-Object System.IO.MemoryStream
$img.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
$data = New-Object System.Windows.Forms.DataObject
$data.SetImage($img)
$data.SetData('PNG', $false, $ms)
[System.Windows.Forms.Clipboard]::SetDataObject($data, $true)
"clipboard: $Path ($($ms.Length) png bytes)"
