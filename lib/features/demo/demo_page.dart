import 'package:flutter/material.dart';
import 'package:voyager/features/life_tracker/life_tree_canvas.dart';
import 'package:voyager/features/life_tracker/life_tree_geometry.dart';

/// Demo page dedicated to showcasing the 1:1 algorithmic Sumi-e Cherry Blossom Tree.
class DemoPage extends StatefulWidget {
  const DemoPage({super.key});

  @override
  State<DemoPage> createState() => _DemoPageState();
}

class _DemoPageState extends State<DemoPage> {
  late final LifeTreeCanvasController _controller;

  static const _paperColor = Color(0xFFF4F2EB);
  static const _inkColor = Color(0xFF221E1B);
  static const _grassColor = Color(0xFF869775);
  static const _accentColor = Color(0xFF7C9EFF);

  static const _leafColors = <Color>[
    Color(0xFFEB8B9C),
    Color(0xFFF2A4B2),
    Color(0xFFE57F91),
    Color(0xFFDE7285),
  ];

  @override
  void initState() {
    super.initState();
    _controller = LifeTreeCanvasController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final geometry = generateLifeTreeGeometry();

    return Container(
      color: _paperColor,
      child: Stack(
        children: [
          Positioned.fill(
            child: LifeTreeCanvas(
              geometry: geometry,
              leafColors: _leafColors,
              inkColor: _inkColor,
              paperColor: _paperColor,
              grassColor: _grassColor,
              groundedLeafIndices: const {},
              controller: _controller,
              accentColor: _accentColor,
            ),
          ),
          Positioned(
            left: 24,
            top: 24,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: _paperColor.withValues(alpha: 0.85),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: _inkColor.withValues(alpha: 0.15)),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                child: Text(
                  'Demo — 1:1 Sumi-e Cherry Blossom Tree',
                  style: TextStyle(
                    color: _inkColor,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
