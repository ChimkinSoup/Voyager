# Last batch of unlisted Vim commands (see p3x-gen.py).
import importlib.util
spec = importlib.util.spec_from_file_location("g", "qa/steps/p3x-gen.py")
g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g)
L1, L2, L3, L4, L5, T, J, at, start, a0 = g.L1, g.L2, g.L3, g.L4, g.L5, g.T, g.J, g.at, g.start, g.a0
g.cases.clear()
c = g.c
c("pgdn", a0, "{pgdn}", T, start(4) + 2)
c("pgup", at(4, "st"), "{pgup}", T, start(0) + 2)
c("/-tab-cancels", a0, "/gam {tab}", T, a0, "*")
B = "say `code` and 'x'"
c("di`", B.index("code"), "di`", "say `` and 'x'", B.index("code"), text=B)
c("da'", B.index("x"), "da'", "say `code` and ", "*", text=B)
c("2Y-P", start(0), "2Y j j P", J(L1, L2, L1, L2, L3, L4, L5), start(2))
c("2S", at(0, "beta"), "2S", J("", L3, L4, L5), 0, "insert")
c("2P", at(4, "l"), "yiw 2P", J(L1, L2, L3, L4, "lastlastlast"), "*")
c(">>-u", at(1, "x"), ">> {wait:1200} u", T, "*")
open("qa/steps/p3x-cases3.tsv", "w", encoding="utf-8", newline="\n").write("\n".join(g.cases) + "\n")
print(len(g.cases), "cases")
