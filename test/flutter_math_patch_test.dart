import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';

/// The VOYAGER PATCHes in third_party/flutter_math_fork-0.7.4.
void main() {
  Future<Size> typeset(
    WidgetTester tester,
    String tex, {
    MathStyle style = MathStyle.display,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: Math.tex(
            tex,
            mathStyle: style,
            textStyle: const TextStyle(fontSize: 20),
          ),
        ),
      ),
    );
    return tester.getSize(find.byType(Math));
  }

  testWidgets('a delimiter in a script style encloses what it brackets', (
    tester,
  ) async {
    // Inline, so the numerator is in script style. Drawn at that style, the
    // bracket came out shorter than the binomial, failing its constraints.
    await typeset(
      tester,
      r'\frac{\binom{8}{x}\binom{6}{3-x}}{364}',
      style: MathStyle.text,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('tall rows of a matrix or cases keep a gap between them', (
    tester,
  ) async {
    final fraction = await typeset(tester, r'\dfrac{13}{49}');
    // A matrix lays out with MatrixNode, a cases with EquationArrayNode.
    for (final env in ['matrix', 'cases']) {
      final twoRows = await typeset(
        tester,
        '\\begin{$env} \\dfrac{13}{49} \\\\ \\dfrac{24}{49} \\end{$env}',
      );
      // 3pt at 20px is 6px; rows that touched made twice the height.
      expect(
        twoRows.height,
        greaterThanOrEqualTo(2 * fraction.height + 5.9),
        reason: env,
      );
    }
  });

  testWidgets('a rule between tall rows sits midway in the gap', (
    tester,
  ) async {
    // A matrix lays out with MatrixNode, a cases with EquationArrayNode.
    for (final env in ['matrix', 'cases']) {
      final size = await typeset(
        tester,
        '\\begin{$env} \\dfrac{a}{b} \\\\ \\hline \\dfrac{c}{d} \\end{$env}',
      );
      // Each layout's rule positions, from the top.
      List<double>? rules;
      void visit(RenderObject object) {
        final type = object.runtimeType.toString();
        if (type == 'RenderEqnArray') {
          rules = (object as dynamic).hlinePos as List<double>;
        } else if (type.startsWith('RenderCustomLayout') &&
            '${(object as dynamic).delegate.runtimeType}' ==
                'MatrixLayoutDelegate') {
          rules = (object as dynamic).delegate.hLinePos as List<double>;
        }
        object.visitChildren(visit);
      }

      visit(tester.renderObject(find.byType(Math)));
      // The rows are alike, so midway is half the height, less half the
      // rule's thickness. Pushed down with the row below, it sat on the
      // row above.
      expect(
        rules![1],
        moreOrLessEquals(size.height / 2, epsilon: 1),
        reason: env,
      );
    }
  });

  testWidgets('short rows keep their usual spacing', (tester) async {
    final plain = await typeset(
      tester,
      r'\begin{cases} 0, & x < 1 \\ 1, & x \ge 1 \end{cases}',
    );
    // The height unpatched: the struts already keep these rows apart.
    expect(plain.height, moreOrLessEquals(49.24, epsilon: 0.01));
  });
}
