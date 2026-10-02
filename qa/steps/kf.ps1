# Phase 11 helper: run one voy.ps1 "do" string, then print the focused node.
param([Parameter(Mandatory)][string]$Steps)
& "C:\Users\Juno\Code\Voyager\qa\harness\voy.ps1" do $Steps
Set-Location C:\Users\Juno\Code\Voyager
& "C:\Users\Juno\AppData\Local\Temp\claude\C--Users-Juno-Code-Voyager\cb127d74-c249-48c5-8ab3-4c170737918c\scratchpad\vm.exe" eval "features/shell/app_shell.dart" "FocusManager.instance.primaryFocus?.toStringShort() ?? 'none'"
