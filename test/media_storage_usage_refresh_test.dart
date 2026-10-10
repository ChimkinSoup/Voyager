// BUG-209: a backup restore writes images without going through
// MediaService, so the Settings "N images · size" readout has to be among
// the providers a restore refreshes.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/domain/models/media_models.dart';

void main() {
  test('reloading every data provider recounts the image storage', () async {
    var assets = 0;
    final container = ProviderContainer(
      overrides: [
        mediaStorageUsageProvider.overrideWith(
          (ref) async => MediaStorageUsage(
            assetCount: assets,
            byteSize: assets * 7500,
            pendingUploadCount: 0,
            pendingDownloadCount: 0,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    final subscription = container.listen(mediaStorageUsageProvider, (_, _) {});
    addTearDown(subscription.close);
    expect((await container.read(mediaStorageUsageProvider.future)).assetCount, 0);

    // What the restore does on disk, then what it does to the providers.
    assets = 2;
    invalidateAllDataProvidersIn(container);

    expect((await container.read(mediaStorageUsageProvider.future)).assetCount, 2);
  });
}
