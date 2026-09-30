# Phase 3 Vim probe. For each case: Esc (to Normal), set the focused field's
# text + caret over the VM service, send real keys, read back text/selection/mode.
#   vimcase.ps1 <cases.tsv> [-VmExe <compiled vm.dart>]
# Case line (tab-separated): name  text  caret  keys  expText  expSel  [expMode]
#   text/expText: \n = newline, \u{hex} = any code point (non-ASCII is read back in that form).  expSel: "b,e" or "b" (collapsed); '*' = don't care.
#   keys: space-separated tokens; {chord} = key chord (e.g. {esc} {ctrl+r} {space}),
#         anything else is typed literally. {wait:ms} sleeps.
# The field under test must already have keyboard focus. Assumes Vim is ON.
param([Parameter(Mandatory = $true)][string]$Cases, [string]$VmExe = '')

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent (Split-Path -Parent $here)
Set-Location $root
if (-not ('Voy' -as [type])) { Add-Type -Path (Join-Path $here 'Probe.cs') -ReferencedAssemblies System.Drawing }

function Vm([string]$expr) {
  $ErrorActionPreference = 'Continue'
  if ($VmExe -ne '') { $o = & $VmExe eval 'core/vim/vim_text_scope.dart' $expr 2>&1 }
  else { $o = & dart run qa/harness/vm.dart eval 'core/vim/vim_text_scope.dart' $expr 2>&1 }
  return (($o | ForEach-Object { "$_" } | Where-Object { $_ -notmatch 'Running build hooks' }) -join "`n")
}

function DartStr([string]$s) {
  return "'" + $s.Replace('\', '\\').Replace("'", "\'").Replace('$', '\$').Replace("`n", '\n').Replace('\\u{', '\u{').Replace('"', '\x22') + "'"
}

$edit = 'FocusManager.instance.primaryFocus?.context?.findAncestorStateOfType<EditableTextState>()'
$scope = 'FocusManager.instance.primaryFocus?.context?.findAncestorStateOfType<_VimTextScopeState>()'
$readExpr = "(() { final s = $edit; if (s == null) return 'NOFIELD'; final v = s.textEditingValue; return v.selection.baseOffset.toString() + ',' + v.selection.extentOffset.toString() + '|' + ($($scope)?._session?.mode.name ?? 'nosession') + '|' + v.text.length.toString() + '|' + v.text.runes.map((r) => r == 10 ? r'\n' : (r < 128 ? String.fromCharCode(r) : r'\u{' + r.toRadixString(16) + '}')).join(); })()"

function Send-Keys([string]$keys) {
  foreach ($tok in ($keys -split ' ')) {
    if ($tok -eq '') { continue }
    if ($tok -match '^\{wait:(\d+)\}$') { Start-Sleep -Milliseconds ([int]$Matches[1]); continue }
    if ($tok -match '^\{(.+)\}$') { [Voy]::Chord($Matches[1]) } else { [Voy]::Type($tok) }
    Start-Sleep -Milliseconds 40
  }
}

$pass = 0; $fail = 0
foreach ($line in Get-Content -LiteralPath $Cases -Encoding UTF8) {
  if ($line.Trim() -eq '' -or $line.StartsWith('#')) { continue }
  $f = $line -split "`t"
  $name = $f[0]; $text = $f[1].Replace('\n', "`n"); $caret = [int]$f[2]; $keys = $f[3]
  $expText = $f[4]; $expSel = $f[5]; $expMode = if ($f.Count -gt 6) { $f[6] } else { '*' }
  if (-not [Voy]::Activate()) { throw "activate failed: $([Voy]::Status())" }
  [Voy]::Chord('esc'); Start-Sleep -Milliseconds 60; [Voy]::Chord('esc'); Start-Sleep -Milliseconds 60
  # Deferred with Future so the write runs outside the eval's stack (a synchronous
  # write can trip debug assertions that can't parse the `Eval` frame).
  $setExpr = "(() { final s = $edit; if (s == null) return 'NOFIELD'; Future(() { s.widget.controller.value = TextEditingValue(text: $(DartStr $text), selection: TextSelection.collapsed(offset: $caret)); }); return 'ok'; })()"
  $r = Vm $setExpr
  if ($r -ne 'ok') { Write-Output "ERROR $name set: $r"; $fail++; continue }
  Start-Sleep -Milliseconds 150
  if (-not [Voy]::Activate()) { throw "activate failed: $([Voy]::Status())" }
  Send-Keys $keys
  Start-Sleep -Milliseconds 250
  $got = Vm $readExpr
  # got = sel|mode|length|text (text last: the VM service truncates long strings)
  $p = $got.Split([char]'|', 4)
  $ok = $true
  if ($expText -ne '*' -and ($p.Count -lt 4 -or $p[3] -ne $expText)) { $ok = $false }
  if ($expSel -ne '*') {
    $want = if ($expSel.Contains(',')) { $expSel } else { "$expSel,$expSel" }
    if ($p[0] -ne $want) { $ok = $false }
  }
  if ($expMode -ne '*' -and $p[1] -ne $expMode) { $ok = $false }
  if ($ok) { $pass++; Write-Output "PASS $name  => $got" } else { $fail++; Write-Output "FAIL $name  => got [$got]  want [$expSel|$expMode|$expText]" }
}
Write-Output "pass=$pass fail=$fail"
