# Generates qa/steps/p3x-cases.tsv: Vim commands present in lib/core/vim but not
# listed in VIM.md. Expected values follow stock Vim (whichwrap=b,s, shiftwidth=2,
# the app's kVimShiftWidth).
L1 = "  alpha-beta gamma.delta  "
L2 = "call(x, [y], {z: 'q'}) <t>"
L3 = ""
L4 = 'Line Four "quoted text" end'
L5 = "last"
LINES = [L1, L2, L3, L4, L5]
T = "\n".join(LINES)


def start(i):  # offset of line i (0-based)
    return sum(len(l) + 1 for l in LINES[:i])


def at(i, sub, k=0):  # offset of the k-th occurrence of sub in line i
    s = LINES[i]
    p = -1
    for _ in range(k + 1):
        p = s.index(sub, p + 1)
    return start(i) + p


def J(*ls):
    return "\n".join(ls)


def esc(s):
    return s.replace("\n", r"\n")


cases = []


def c(name, caret, keys, exp_text, exp_sel, mode="normal", text=T):
    cases.append("\t".join([name, esc(text), str(caret), keys, esc(exp_text) if exp_text != "*" else "*", str(exp_sel), mode]))


a0 = at(0, "alpha")
# ---- motions ----
c("W", a0, "W", T, at(0, "gamma"))
c("w-punct", a0, "w", T, at(0, "-"))
c("E", a0, "E", T, at(0, "-beta") + 4)
c("B", at(0, "gamma"), "B", T, a0)
c("^", at(0, "beta"), "^", T, a0)
c("g_", start(0), "g_", T, at(0, "delta") + 4)
c("$-vs-g_", start(0), "$", T, start(0) + len(L1) - 1)
c("}", a0, "}", T, start(2))
c("{", at(3, "Four"), "{", T, start(2))
c("%-paren", at(1, "("), "%", T, at(1, ")"))
c("%-bracket", at(1, "["), "%", T, at(1, "]"))
c("%-back", at(1, ")"), "%", T, at(1, "("))
c("%-ahead", start(1), "%", T, at(1, ")"))
c("5|", at(0, "gamma"), "5|", T, start(0) + 4)
c("+", at(0, "beta"), "+", T, start(1))
c("-", at(1, "x"), "-", T, a0)
c("space", at(0, "gamma"), "{space}", T, at(0, "gamma") + 1)
c("space-wrap", start(0) + len(L1) - 1, "{space}", T, start(1))
c("enter", at(0, "beta"), "{enter}", T, start(1))
c("3G", a0, "3G", T, start(2))
c("2gg", at(4, "last"), "2gg", T, start(1))
c("2$", a0, "2$", T, start(1) + len(L2) - 1)
c("ctrl+d", a0, "{ctrl+d}", T, "*")
c("ctrl+u", at(4, "a"), "{ctrl+u}", T, "*")
# ---- arrow/nav keys in Normal ----
c("right", a0, "{right}", T, a0 + 1)
c("left", a0 + 2, "{left}", T, a0 + 1)
c("down", a0, "{down}", T, start(1) + 2)
c("up", start(1) + 2, "{up}", T, start(0) + 2)
c("home", at(0, "gamma"), "{home}", T, start(0))
c("end", a0, "{end}", T, start(0) + len(L1) - 1)
c("delete", a0, "{delete}", J("  lpha-beta gamma.delta  ", L2, L3, L4, L5), a0)
c("backspace-wrap", start(1), "{backspace}", T, start(0) + len(L1) - 1)
# ---- shift ----
c(">>", at(1, "x"), ">>", J(L1, "  " + L2, L3, L4, L5), start(1) + 2)
c("<<", at(0, "beta"), "<<", J(L1[2:], L2, L3, L4, L5), start(0))
c(">j", a0, ">j", J("  " + L1, "  " + L2, L3, L4, L5), start(0) + 4)
c("V-j->", a0, "V j >", J("  " + L1, "  " + L2, L3, L4, L5), start(0) + 4)
c(">>-dot", at(1, "x"), ">> .", J(L1, "    " + L2, L3, L4, L5), start(1) + 4)
c("2>>", start(4), "k k 2>>", T, "*")  # placeholder replaced below
cases.pop()
c("2>>", start(3), "2>>", J(L1, L2, L3, "  " + L4, "  " + L5), start(3) + 2)
# ---- case operators ----
c("guiw", at(3, "Line"), "guiw", J(L1, L2, L3, 'line Four "quoted text" end', L5), start(3))
c("gUiw", at(3, "Line"), "gUiw", J(L1, L2, L3, 'LINE Four "quoted text" end', L5), start(3))
c("g~iw", at(3, "Line"), "g~iw", J(L1, L2, L3, 'lINE Four "quoted text" end', L5), start(3))
c("guu", at(3, "Four"), "guu", J(L1, L2, L3, L4.lower(), L5), "*")
c("gUU", at(3, "Four"), "gUU", J(L1, L2, L3, L4.upper(), L5), "*")
c("g~~", at(3, "Four"), "g~~", J(L1, L2, L3, L4.swapcase(), L5), "*")
c("gUw", at(3, "Four"), "gUw", J(L1, L2, L3, 'Line FOUR "quoted text" end', L5), at(3, "Four"))
c("v-U", at(3, "Four"), "v e U", J(L1, L2, L3, 'Line FOUR "quoted text" end', L5), at(3, "Four"))
c("v-u", at(3, "Line"), "v e u", J(L1, L2, L3, 'line Four "quoted text" end', L5), start(3))
c("v-~", at(3, "Line"), "v e ~", J(L1, L2, L3, 'lINE Four "quoted text" end', L5), start(3))
c("U-normal-noop", at(3, "Line"), "U", T, at(3, "Line"))
c("4~", at(3, "Line"), "4~", J(L1, L2, L3, 'lINE Four "quoted text" end', L5), start(3) + 4)
# ---- single-key edits ----
c("C", at(0, "gamma"), "C", J("  alpha-beta ", L2, L3, L4, L5), at(0, "gamma"), "insert")
c("Y-P", at(4, "a"), "Y k P", J(L1, L2, L3, L5, L4, L5), start(3))
c("S", at(0, "beta"), "S", J("", L2, L3, L4, L5), 0, "insert")
c("s", a0, "s", J("  lpha-beta gamma.delta  ", L2, L3, L4, L5), a0, "insert")
c("3s", a0, "3s", J("  ha-beta gamma.delta  ", L2, L3, L4, L5), a0, "insert")
c("X", a0 + 2, "X", J("  apha-beta gamma.delta  ", L2, L3, L4, L5), a0 + 1)
c("3X", a0 + 3, "3X", J("  ha-beta gamma.delta  ", L2, L3, L4, L5), a0)
c("X-bol", start(1), "X", T, start(1))
c("3rx", a0, "3rx", J("  xxxha-beta gamma.delta  ", L2, L3, L4, L5), a0 + 2)
c("J", at(3, "Four"), "J", J(L1, L2, L3, L4 + " " + L5), start(3) + len(L4))
c("J-indent", at(4, "last"), "k k k J", "*", "*")
cases.pop()
c("J-lead-ws", start(0), "J", J(L1 + L2, L3, L4, L5) if L1.endswith(" ") else "?", "*")
c("3J", start(3), "3J", "*", "*")  # only 2 lines left: Vim refuses (beep), text unchanged
cases.pop()
c("v-J", start(0), "V j J", J(L1 + L2, L3, L4, L5), "*")
c("yiw-P", at(0, "gamma"), "yiw w P", J("  alpha-beta gamma.gammadelta  ", L2, L3, L4, L5), at(0, "delta") + 4)
# ---- text objects ----
c("diw", at(0, "gamma") + 1, "diw", J("  alpha-beta .delta  ", L2, L3, L4, L5), at(0, "gamma"))
c("daw", at(3, "Four") + 1, "daw", J(L1, L2, L3, 'Line "quoted text" end', L5), at(3, "Four"))
c("ciW", at(0, "beta"), "ciW", J("   gamma.delta  ", L2, L3, L4, L5), a0, "insert")
c("daW", at(0, "beta"), "daW", J("  gamma.delta  ", L2, L3, L4, L5), a0)
c("di(", at(1, "y"), "di(", J(L1, "call() <t>", L3, L4, L5), at(1, "("), )
cases[-1] = cases[-1].replace("\t" + str(at(1, "(")) + "\t", "\t" + str(at(1, "(") + 1) + "\t")
c("dib", at(1, "y"), "dib", J(L1, "call() <t>", L3, L4, L5), at(1, "(") + 1)
c("da(", at(1, "x"), "da(", J(L1, "call <t>", L3, L4, L5), at(1, "("))
c("di[", at(1, "y"), "di[", J(L1, "call(x, [], {z: 'q'}) <t>", L3, L4, L5), at(1, "[") + 1)
c("da{", at(1, "z"), "da{", J(L1, "call(x, [y], ) <t>", L3, L4, L5), at(1, "{"))
c("diB", at(1, "z"), "diB", J(L1, "call(x, [y], {}) <t>", L3, L4, L5), at(1, "{") + 1)
c("di'", at(1, "q"), "di'", J(L1, "call(x, [y], {z: ''}) <t>", L3, L4, L5), at(1, "'") + 1)
c("di<", at(1, "t"), "di<", J(L1, "call(x, [y], {z: 'q'}) <>", L3, L4, L5), at(1, "<") + 1)
c('ci"', at(3, "text"), 'ci" NEW {esc}', J(L1, L2, L3, 'Line Four "NEW" end', L5), at(3, '"') + 3)
c('da"', at(3, "quoted"), 'da"', J(L1, L2, L3, "Line Four end", L5), at(3, '"'))
c("yi(-p", at(1, "x"), "yi( $ p", J(L1, L2 + "x, [y], {z: 'q'}", L3, L4, L5), "*")
c("dip", a0, "dip", J(L3, L4, L5), 0)
c("dap", a0, "dap", J(L4, L5), 0)
c("viw-d", at(0, "gamma") + 2, "v i w d", J("  alpha-beta .delta  ", L2, L3, L4, L5), at(0, "gamma"))
c("vi(-mode", at(1, "y"), "v i (", T, "%d,%d" % (at(1, "(") + 1, at(1, ")") - 1), "visual")
c("di(-outside", at(3, "Four"), "di( l", T, at(3, "Four") + 1)
# ---- visual extras ----
c("v-o", a0, "v l l o", T, "%d,%d" % (a0 + 3, a0), "visual")
c("ctrl+[-insert", a0, "i {ctrl+lbracket}", T, a0 - 1)
c("ctrl+[-visual", a0, "v l {ctrl+lbracket}", T, a0 + 1)
c("ctrl+a", a0, "{ctrl+a}", T, "*", "*")
# ---- backward search + prompt keys ----
c("?", at(4, "last"), "?a {enter}", T, at(3, "Four") - 0 if False else T.rindex("a", 0, at(4, "last")))
c("?-n", at(4, "last"), "?a {enter} n", T, T.rindex("a", 0, T.rindex("a", 0, at(4, "last"))))
c("?-N", at(4, "last"), "?quoted {enter} N", T, at(3, "quoted"))
c("/-ctrl+w", 0, "/xyz {ctrl+w} gamma {enter}", T, at(0, "gamma"))
c("/-ctrl+u", 0, "/abc {ctrl+u} delta {enter}", T, at(0, "delta"))
c("/-bs-empty", a0, "/ {backspace} l", T, a0 + 1)
c("/-ctrl+v", 0, "/ {ctrl+v} {enter}", T, at(3, "quoted"))

open("qa/steps/p3x-cases.tsv", "w", encoding="utf-8", newline="\n").write("\n".join(cases) + "\n")
print(len(cases), "cases")
