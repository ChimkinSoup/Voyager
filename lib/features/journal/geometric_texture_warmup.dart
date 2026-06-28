import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/widgets/geometric_texture.dart';

/// Renders the geometric texture for a few frames after login so GPU shaders
/// compile before the user sees any content.
///
/// Waits for [geometricShaderProvider] to finish loading before painting so
/// the warmup frames actually hit the compiled program.
class GeometricTextureWarmup extends ConsumerStatefulWidget {
  const GeometricTextureWarmup({super.key});

  @override
  ConsumerState<GeometricTextureWarmup> createState() =>
      _GeometricTextureWarmupState();
}

class _GeometricTextureWarmupState
    extends ConsumerState<GeometricTextureWarmup> {
  bool _done = false;
  int _frame = 0;
  var _warmupStarted = false;

  void _advance(Duration _) {
    if (!mounted) return;
    _frame++;
    if (_frame >= 3) {
      setState(() => _done = true);
      return;
    }
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback(_advance);
  }

  void _startWarmup() {
    if (_warmupStarted || _done) return;
    _warmupStarted = true;
    WidgetsBinding.instance.addPostFrameCallback(_advance);
  }

  @override
  Widget build(BuildContext context) {
    if (_done) return const SizedBox.shrink();

    ref.listen(geometricShaderProvider, (previous, next) {
      if (_warmupStarted || _done) return;
      if (next.hasValue) {
        if (next.value == null) {
          setState(() => _done = true);
        } else {
          _startWarmup();
        }
      }
    });

    final shaderAsync = ref.watch(geometricShaderProvider);
    if (!_warmupStarted && !_done && shaderAsync.hasValue) {
      if (shaderAsync.value == null) {
        _done = true;
        return const SizedBox.shrink();
      }
      _startWarmup();
    }

    final program = shaderAsync.valueOrNull;
    if (program == null) return const SizedBox.shrink();

    return SizedBox.shrink(
      child: OverflowBox(
        alignment: Alignment.topLeft,
        maxWidth: 800,
        maxHeight: 600,
        child: Opacity(
          opacity: 1 / 255,
          child: SizedBox(
            width: 800,
            height: 600,
            child: GeometricTexture(
              program: program,
              baseColor: Theme.of(context).scaffoldBackgroundColor,
              accentColor: Theme.of(context).colorScheme.primary,
            ),
          ),
        ),
      ),
    );
  }
}
