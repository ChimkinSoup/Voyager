# Phase 28A D4: press -Key (default tab) -N times on profile qa and print the
# focused node's widget, rect (physical px) and nearest Text after each press.
param([int]$N = 12, [string]$Key = 'tab')
$env:VOYAGER_QA_PROFILE = 'qa'
$expr = "(() { final f = FocusManager.instance.primaryFocus; final ctx = f?.context; if (ctx == null) return 'none'; final r = ctx.findRenderObject(); var rect = ''; if (r is RenderBox && r.hasSize) { final o = r.localToGlobal(Offset.zero); rect = ((o.dx * 2).round()).toString() + ',' + ((o.dy * 2).round()).toString() + ' ' + ((r.size.width * 2).round()).toString() + 'x' + ((r.size.height * 2).round()).toString(); } var label = ''; void v(Element e) { if (label.isNotEmpty) return; final w = e.widget; if (w is Text && w.data != null) { label = w.data!; return; } e.visitChildren(v); } (ctx as Element).visitChildren(v); return rect + ' ' + ctx.widget.runtimeType.toString() + ' [' + label + ']'; })()"
for ($i = 1; $i -le $N; $i++) {
  & C:\Users\Juno\Code\Voyager\qa\harness\voy.ps1 do "key $Key; wait 250" | Out-Null
  $o = & C:\Users\Juno\Code\Voyager\qa\harness\vm.ps1 -Profile qa eval features/photo_series/photo_series_detail.dart $expr
  "$i $o"
}
