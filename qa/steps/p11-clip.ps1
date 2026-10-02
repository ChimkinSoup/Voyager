# Phase 11: put a test string on the clipboard. -Kind cjk | arabic | emoji | long300 | long5000 | cafe
param([Parameter(Mandatory)][string]$Kind)
switch ($Kind) {
  'cjk'      { $s = [string]::new([char[]]@(0x6771, 0x4EAC)) }
  'arabic'   { $s = [string]::new([char[]]@(0x645, 0x631, 0x62D, 0x628, 0x627)) }
  'emoji'    { $s = [char]::ConvertFromUtf32(0x1F600) }
  'cafe'     { $s = 'caf' + [char]0xE9 }
  'long300'  { $s = 'q' * 300 }
  'long5000' { $s = (1..1000 | ForEach-Object { 'word' }) -join ' ' }
}
Set-Clipboard -Value $s
