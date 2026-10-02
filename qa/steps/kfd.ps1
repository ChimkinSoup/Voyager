# Phase 11 helper: run one voy.ps1 "do" string, then debugPrint the focused node and its widget ancestry into the run log.
param([Parameter(Mandatory)][string]$Steps, [string]$Tag = 'FOCUS')
& "C:\Users\Juno\Code\Voyager\qa\harness\voy.ps1" do $Steps
Set-Location C:\Users\Juno\Code\Voyager
& "C:\Users\Juno\AppData\Local\Temp\claude\C--Users-Juno-Code-Voyager\cb127d74-c249-48c5-8ab3-4c170737918c\scratchpad\vm.exe" eval "features/shell/app_shell.dart" "Future(() { final n = FocusManager.instance.primaryFocus; final ctx = n?.context; var s = '$Tag ' + n.toString() + ' | ' + (ctx?.widget.runtimeType.toString() ?? 'noctx'); var k = 0; ctx?.visitAncestorElements((e) { k++; if (k < 40) s += ' > ' + e.widget.runtimeType.toString(); return true; }); debugPrint(s); })"
