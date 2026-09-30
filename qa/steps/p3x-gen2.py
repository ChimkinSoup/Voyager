# Reruns + extra checks for the unlisted Vim commands (see p3x-gen.py).
import importlib.util, sys
spec = importlib.util.spec_from_file_location("g", "qa/steps/p3x-gen.py")
g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g)
L1, L2, L3, L4, L5, T, J, at, start, a0 = g.L1, g.L2, g.L3, g.L4, g.L5, g.T, g.J, g.at, g.start, g.a0
g.cases.clear()
c = g.c
c("<<", at(0, "beta"), "<<", J(L1[2:], L2, L3, L4, L5), start(0))
c("3rx", a0, "3rx", J("  xxxha-beta gamma.delta  ", L2, L3, L4, L5), a0 + 2)
c("/-bs-empty", a0, "/ {backspace} l", T, a0 + 1)
# Visual-line J over two non-empty lines followed by a third non-empty line
N = "one\ntwo\nthree\nfour"
c("V-j-J", 0, "V j J", "one two\nthree\nfour", 3, text=N)
c("J-count-2", 0, "2J", "one two\nthree\nfour", 3, text=N)
c("J-count-3", 0, "3J", "one two three\nfour", "*", text=N)
c("v-J-charwise", 1, "v j J", "one two\nthree\nfour", 3, text=N)
# gj / gk on a soft-wrapped line (the journal body wraps at ~150 chars maximized)
LONG = " ".join("word%03d" % i for i in range(60))  # 479 chars, one logical line
c("gj", 0, "gj", LONG, "*", text=LONG)
c("gj-gk", 0, "gj gk", LONG, 0, text=LONG)
c("j-on-wrapped", 0, "j", LONG, 0, text=LONG)
# Space / l / h at line boundaries (Vim: Space and Backspace wrap, h/l don't)
c("space-wrap", start(0) + len(L1) - 1, "{space}", T, start(1))
c("l-no-wrap", start(0) + len(L1) - 1, "l", T, start(0) + len(L1) - 1)
open("qa/steps/p3x-cases2.tsv", "w", encoding="utf-8", newline="\n").write("\n".join(g.cases) + "\n")
print(len(g.cases), "cases")
