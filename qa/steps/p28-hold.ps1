# Phase 28A: press and hold at a physical client point for -Ms milliseconds by
# injecting pointer events over the VM service (no real input). Profile qa.
param([double]$X, [double]$Y, [int]$Ms = 1800)
$env:VOYAGER_QA_PROFILE = 'qa'
$lx = $X / 2; $ly = $Y / 2
$expr = "Future(() async { GestureBinding.instance.handlePointerEvent(PointerDownEvent(pointer: 977, position: Offset($lx, $ly))); await Future.delayed(Duration(milliseconds: $Ms)); GestureBinding.instance.handlePointerEvent(PointerUpEvent(pointer: 977, position: Offset($lx, $ly))); })"
& C:\Users\Juno\Code\Voyager\qa\harness\vm.ps1 -Profile qa eval core/dev/perf_stall_logger.dart $expr
