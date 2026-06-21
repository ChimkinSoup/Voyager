import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/widgets/voyager_menu_catalog.dart';

void main() {
  testWidgets('buildCatalogMenu filters entries and supports overrides', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            final entries = buildCatalogMenu(
              context,
              from: entityManageMenuEntries,
              visible: {
                VoyagerMenuCatalogEntry.rename,
                VoyagerMenuCatalogEntry.delete,
              },
              childOverrides: {
                VoyagerMenuCatalogEntry.delete: (context, entry) => Row(
                  children: [
                    Icon(
                      PhosphorIconsRegular.trash,
                      color: Colors.redAccent,
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Text(entry.label),
                  ],
                ),
              },
            );
            expect(entries, hasLength(2));
            expect(entries[0].runtimeType.toString(), contains('VoyagerPopupMenuItem'));
            return const SizedBox.shrink();
          },
        ),
      ),
    );
  });

  test('weather catalog maps icon strings', () {
    expect(
      VoyagerMenuCatalogEntry.weatherRain.weatherIconValue,
      'rain',
    );
    expect(
      VoyagerMenuCatalogEntryLabels.forWeatherIcon('snow'),
      VoyagerMenuCatalogEntry.weatherSnow,
    );
  });
}
