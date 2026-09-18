import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/core/widgets/glass_surface.dart';
import 'package:voyager/features/finance/finance_transaction_modal.dart';

/// Paints the new-transaction sheet once, offscreen, so its first real
/// opening doesn't stutter.
///
/// Measured in a profile build: the first opening of a session spent ~95ms
/// rasterizing each of two frames, and later ones under 13ms. That is the GPU
/// compiling the programs the sheet draws with — its heavy backdrop blur and
/// shadow, the form's glyphs — which happens on first use and not again. A
/// snapshot rasterizes through the same GPU context as the window, so drawing
/// the real sheet into one leaves those programs compiled, and nothing of it
/// ever reaches the screen.
///
/// [context] supplies the app's theme, pixel ratio and providers.
Future<void> warmUpFinanceSheet(BuildContext context) async {
  final theme = Theme.of(context);
  final media = MediaQuery.of(context);
  final container = ProviderScope.containerOf(context, listen: false);
  final view = View.of(context);
  final dpr = media.devicePixelRatio;
  const size = Size(640, 640);
  const radius = BorderRadius.vertical(top: Radius.circular(20));

  final boundary = RenderRepaintBoundary();
  final renderView = RenderView(
    view: view,
    configuration: ViewConfiguration(
      logicalConstraints: BoxConstraints.tight(size),
      physicalConstraints: BoxConstraints.tight(size * dpr),
      devicePixelRatio: dpr,
    ),
    child: boundary,
  );
  final pipelineOwner = PipelineOwner()..rootNode = renderView;
  renderView.prepareInitialFrame();
  final focusManager = FocusManager();
  final buildOwner = BuildOwner(focusManager: focusManager);

  final sheet = UncontrolledProviderScope(
    container: container,
    child: MediaQuery(
      data: media.copyWith(size: size),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Localizations(
          locale: const Locale('en', 'US'),
          delegates: const [
            DefaultMaterialLocalizations.delegate,
            DefaultWidgetsLocalizations.delegate,
          ],
          child: Theme(
            data: theme,
            // The amount field autofocuses, and a focused field opens the
            // platform's text input — taking it from the app's own field.
            child: ExcludeFocus(
              child: TickerMode(
                enabled: false,
                child: Overlay(
                  initialEntries: [
                    OverlayEntry(
                      builder: (_) => Stack(
                        fit: StackFit.expand,
                        children: [
                          // Something for the backdrop blur to sample.
                          ColoredBox(color: theme.scaffoldBackgroundColor),
                          Align(
                            alignment: Alignment.bottomCenter,
                            child: GlassSurface(
                              weight: GlassWeight.heavy,
                              borderRadius: radius,
                              child: Material(
                                type: MaterialType.transparency,
                                child: financeTransactionForm(
                                  container: container,
                                  onClose: () {},
                                  // Autofocus looks the field up by a
                                  // GlobalKey from a post-frame callback, and
                                  // keys resolve through the app's
                                  // BuildOwner, not [buildOwner]: it would
                                  // throw on the frame that runs while the
                                  // snapshot is awaited.
                                  autofocus: false,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  final root = RenderObjectToWidgetAdapter<RenderBox>(
    container: boundary,
    child: sheet,
  ).attachToRenderTree(buildOwner);
  try {
    buildOwner
      ..buildScope(root)
      ..finalizeTree();
    pipelineOwner
      ..flushLayout()
      ..flushCompositingBits()
      ..flushPaint();
    final image = await boundary.toImage(pixelRatio: dpr);
    image.dispose();
  } finally {
    RenderObjectToWidgetAdapter<RenderBox>(
      container: boundary,
    ).attachToRenderTree(buildOwner, root);
    buildOwner
      ..buildScope(root)
      ..finalizeTree();
    focusManager.dispose();
  }
}
