# Checks for VIM.md claims not yet exercised (see p3x-gen.py).
import importlib.util
spec = importlib.util.spec_from_file_location("g", "qa/steps/p3x-gen.py")
g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g)
L1, L2, L3, L4, L5, T, J, at, start, a0 = g.L1, g.L2, g.L3, g.L4, g.L5, g.T, g.J, g.at, g.start, g.a0
g.cases.clear()
c = g.c
c("v-s", a0, "v l s", J("  pha-beta gamma.delta  ", L2, L3, L4, L5), a0, "insert")
c("v-x", a0, "v l x", J("  pha-beta gamma.delta  ", L2, L3, L4, L5), a0)
c("v-X", a0, "v l X", J("  pha-beta gamma.delta  ", L2, L3, L4, L5), a0)
c("v-gU", a0, "v e gU", J("  ALPHA-beta gamma.delta  ", L2, L3, L4, L5), a0)
c("di)", at(1, "y"), "di)", J(L1, "call() <t>", L3, L4, L5), at(1, "(") + 1)
c("di}", at(1, "z"), "di}", J(L1, "call(x, [y], {}) <t>", L3, L4, L5), at(1, "{") + 1)
c("da[", at(1, "y"), "da[", J(L1, "call(x, , {z: 'q'}) <t>", L3, L4, L5), at(1, "["))
c("da<", at(1, "t"), "da<", J(L1, "call(x, [y], {z: 'q'}) ", L3, L4, L5), "*")
c("V->", start(1), "V >", J(L1, "  " + L2, L3, L4, L5), start(1) + 2)
c("V-<", start(0), "V <", J(L1[2:], L2, L3, L4, L5), start(0))
c("yy-caret", at(0, "beta"), "yy", T, at(0, "beta"))
open("qa/steps/p3x-cases5.tsv", "w", encoding="utf-8", newline="\n").write("\n".join(g.cases) + "\n")
print(len(g.cases), "cases")
