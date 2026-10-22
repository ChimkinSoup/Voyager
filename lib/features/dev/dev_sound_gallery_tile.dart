import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/sound/app_sounds.dart';

/// Every [AppSound], to hear what each event plays without setting it off.
class DevSoundGallerySection extends ConsumerWidget {
  const DevSoundGallerySection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final panelOpen = ref.watch(devSoundGalleryPanelOpenProvider);
    final sounds = ref.read(appSoundsProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          title: const Text('Sound gallery'),
          subtitle: const Text(
            'The sound each event plays. Tap one to hear it.',
          ),
          value: panelOpen,
          onChanged: (value) {
            ref.read(devSoundGalleryPanelOpenProvider.notifier).state = value;
          },
        ),
        if (panelOpen)
          for (final sound in AppSound.values)
            ListTile(
              title: Text(sound.label),
              trailing: const Icon(PhosphorIconsRegular.play),
              onTap: () => sounds.play(sound),
            ),
      ],
    );
  }
}
