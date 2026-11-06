import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:uuid/uuid.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/media/widgets/media_image.dart';
import 'package:voyager/core/widgets/voyager_text_field.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/companion/gaia_activity_chip.dart';
import 'package:voyager/features/gaia/companion/gaia_card_view.dart';
import 'package:voyager/features/gaia/companion/gaia_markdown.dart';
import 'package:voyager/features/gaia/companion/gaia_orb_materials.dart';
import 'package:voyager/features/gaia/companion/gaia_pinned_prompt.dart';
import 'package:voyager/features/gaia/companion/gaia_spinner.dart';
import 'package:voyager/features/gaia/host/gaia_host.dart';
import 'package:voyager/features/gaia/page/gaia_providers.dart';
import 'package:voyager/features/gaia/remote/gaia_remote.dart';
import 'package:voyager/features/gaia/remote/gaia_remote_client.dart';

/// A command this screen sent and is following: what it said, until the
/// beacon settles it and, for a message, the message itself syncs back.
class _Sent {
  _Sent({required this.id, required this.type, this.text = ''});

  final String id;
  final GaiaRemoteCommandType type;
  final String text;
  GaiaRemoteCommandStatus status = GaiaRemoteCommandStatus.pending;
  String? error;
  DateTime? settledAt;

  /// The chat was busy: it waits in its queue (§13).
  var queued = false;
  StreamSubscription<GaiaRemoteCommand?>? subscription;
}

/// A chat on the phone (GAIA_HLD.md §12.2, §17): the transcript, the reply
/// a beacon is streaming (§8.1), its cards answered here, and a composer
/// whose messages run on a desktop beacon. [chatId] may be a chat not yet
/// made: the beacon makes it with the first message.
class GaiaRemoteChatPage extends ConsumerStatefulWidget {
  const GaiaRemoteChatPage({super.key, required this.chatId, this.title});

  final String chatId;

  /// For a chat not yet made.
  final String? title;

  @override
  ConsumerState<GaiaRemoteChatPage> createState() => _GaiaRemoteChatPageState();
}

class _GaiaRemoteChatPageState extends ConsumerState<GaiaRemoteChatPage> {
  final _composer = TextEditingController();
  final _sent = <_Sent>[];
  final _picks = <String, Set<int>>{};
  void Function()? _unwatch;
  GaiaRemoteClient? _client;

  /// A phone put away isn't watching: what happens next is a push (§14).
  late final AppLifecycleListener _lifecycle;

  /// The beacon the user picked, over the one [gaiaBeaconFor] would.
  String? _target;
  GaiaTier? _tier;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onHide: () {
        _unwatch?.call();
        _unwatch = null;
      },
      onShow: () {
        if (_client case final client?) {
          _unwatch ??= client.watch(widget.chatId);
        }
      },
    );
    unawaited(_startWatching());
  }

  Future<void> _startWatching() async {
    final client = await ref.read(gaiaRemoteClientProvider.future);
    if (!mounted || client == null) return;
    _client = client;
    _unwatch = client.watch(widget.chatId);
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _unwatch?.call();
    // Commands still on their way go on being followed, so each is deleted
    // once it's settled (§12.2).
    _composer.dispose();
    super.dispose();
  }

  GaiaChat? _chat(List<GaiaChat> chats) =>
      chats.where((chat) => chat.id == widget.chatId).firstOrNull;

  /// The beacon this chat's commands go to: the one running it, else the
  /// user's pick, else the one whose session ran it last (§12.2).
  GaiaBeacon? _beaconFor(
    GaiaChat? chat,
    List<GaiaBeacon> beacons,
    DateTime now,
  ) {
    final online = [
      for (final beacon in beacons)
        if (beacon.onlineAt(now)) beacon,
    ];
    if (online.where((b) => b.isRunning(widget.chatId)).firstOrNull
        case final running?) {
      return running;
    }
    if (online.where((b) => b.deviceId == _target).firstOrNull
        case final picked?) {
      return picked;
    }
    final lastSeq = <String, int>{};
    for (final MapEntry(:key, :value) in (chat?.agentSessions ?? {}).entries) {
      final device = key.split('/').first;
      if (value.lastSeq > (lastSeq[device] ?? -1)) {
        lastSeq[device] = value.lastSeq;
      }
    }
    return gaiaBeaconFor(lastSeq, online, now);
  }

  Future<void> _send(
    GaiaBeacon beacon,
    GaiaRemoteCommandType type, {
    Map<String, Object?> payload = const {},
    String text = '',
  }) async {
    final client = _client;
    if (client == null) return;
    try {
      final id = await client.send(
        type,
        target: beacon.deviceId,
        chatId: widget.chatId,
        payload: payload,
      );
      final sent = _Sent(id: id, type: type, text: text);
      sent.subscription = client.command(id).listen((command) {
        if (command == null) return;
        if (mounted) {
          setState(() {
            sent
              ..status = command.status
              ..error = command.error
              ..queued = command.result?['queued'] == true;
            if (command.settled) sent.settledAt = DateTime.now();
          });
        }
        if (command.settled) {
          unawaited(sent.subscription?.cancel());
          unawaited(client.forget(id).catchError((Object _) {}));
        }
      });
      setState(() => _sent.add(sent));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text("Couldn't send: $error")));
    }
  }

  /// The composer's send: the answer to an open question, the reason a
  /// permission or proposal is turned down, or else a message.
  Future<void> _submit(GaiaBeacon beacon, GaiaCardPart? card) async {
    final text = _composer.text.trim();
    if (card != null && card.kind == GaiaCardKind.question) {
      final picks = _picks[card.id] ?? const {};
      if (text.isEmpty && picks.isEmpty) return;
      _composer.clear();
      return _answer(beacon, card, text: text);
    }
    if (card != null && text.isNotEmpty) {
      _composer.clear();
      return _answer(beacon, card, reject: true, text: text);
    }
    if (text.isEmpty) return;
    _composer.clear();
    final isNew = _chat(ref.read(gaiaChatsProvider).valueOrNull ?? []) == null;
    await _send(
      beacon,
      GaiaRemoteCommandType.prompt,
      text: text,
      payload: {'text': text, 'tier': _tier?.name, 'isNew': isNew},
    );
    _tier = null;
  }

  /// The composer's send with no desktop online: into this chat's queue,
  /// which syncs and goes once a beacon drains it, or from the Queue tab.
  Future<void> _queueOffline() async {
    final text = _composer.text.trim();
    if (text.isEmpty) return;
    _composer.clear();
    final repository = ref.read(gaiaRepositoryProvider);
    final last = (await repository.listQueue())
        .where((item) => item.chatId == widget.chatId)
        .lastOrNull;
    final now = DateTime.now().toUtc();
    await repository.upsertQueueItem(
      GaiaQueueItem(
        id: const Uuid().v4(),
        chatId: widget.chatId,
        text: text,
        order: (last?.order ?? 0) + 1,
        createdAt: now,
        updatedAt: now,
        version: 1,
      ),
    );
  }

  Future<void> _answer(
    GaiaBeacon beacon,
    GaiaCardPart card, {
    bool reject = false,
    String text = '',
  }) => _send(
    beacon,
    GaiaRemoteCommandType.answer,
    payload: {
      'cardId': card.id,
      'decision': reject ? 'reject' : 'accept',
      'text': text,
      'selected': [
        for (final i
            in (_picks.remove(card.id) ?? const <int>{}).toList()..sort())
          card.options[i].label,
      ],
    },
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final chats = ref.watch(gaiaChatsProvider).valueOrNull ?? const [];
    final chat = _chat(chats);
    final messages =
        ref.watch(gaiaMessagesProvider(widget.chatId)).valueOrNull ?? const [];
    final beacons = ref.watch(gaiaBeaconsProvider).valueOrNull ?? const [];
    final now = ref.watch(gaiaClockProvider).valueOrNull ?? DateTime.now();
    final live = ref.watch(gaiaLiveProvider(widget.chatId)).valueOrNull;
    final client = ref.watch(gaiaRemoteClientProvider).valueOrNull;
    final devices = ref.watch(gaiaDevicesProvider).valueOrNull ?? const [];
    final me = devices
        .where((device) => device.deviceId == client?.deviceId)
        .firstOrNull;
    final beacon = _beaconFor(chat, beacons, now);
    final running = beacon?.isRunning(widget.chatId) ?? false;
    final paired =
        me != null &&
        !me.revoked &&
        me.publicKey == client?.key.publicKey &&
        beacon != null &&
        me.trustedBy.containsKey(beacon.deviceId);
    final last = messages.lastOrNull;
    // A running reply's cards come with its live text: the reply itself
    // syncs only once it ends.
    final openCard =
        live?.cards.lastOrNull ??
        (last?.role == GaiaMessageRole.assistant
            ? last!.parts.reversed
                  .whereType<GaiaCardPart>()
                  .where(
                    (card) =>
                        card.isOpen &&
                        (running || card.kind == GaiaCardKind.question),
                  )
                  .firstOrNull
            : null);
    final onPick = paired
        ? (GaiaCardPart card, int i) => setState(() {
            final picks = _picks[card.id] ??= {};
            if (picks.contains(i)) {
              picks.remove(i);
            } else {
              if (!card.multiSelect) picks.clear();
              picks.add(i);
            }
          })
        : null;
    final onAllow = paired
        ? (GaiaCardPart card) => _answer(beacon, card)
        : null;
    final onReject = paired
        ? (GaiaCardPart card) =>
              _answer(beacon, card, reject: true, text: _composer.text.trim())
        : null;
    // A message stays shown as sent until it syncs back, or for a while
    // after its beacon took it.
    final shownText = {
      for (final message in messages)
        if (message.role == GaiaMessageRole.user) message.text.trim(),
    };
    final pending = [
      for (final sent in _sent)
        if (sent.type == GaiaRemoteCommandType.prompt &&
            !(sent.status == GaiaRemoteCommandStatus.done &&
                (shownText.contains(sent.text) ||
                    (sent.queued &&
                        now.difference(sent.settledAt!).inSeconds > 5) ||
                    now.difference(sent.settledAt!).inSeconds > 30)))
          sent,
    ];
    final failed = [
      for (final sent in _sent)
        if (sent.type != GaiaRemoteCommandType.prompt &&
            sent.error != null &&
            now.difference(sent.settledAt ?? now).inSeconds < 30)
          sent,
    ];
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final online = [
      for (final b in beacons)
        if (b.onlineAt(now)) b,
    ];
    final queued = [
      for (final item in ref.watch(gaiaQueueProvider).valueOrNull ?? const [])
        if (item.chatId == widget.chatId) item,
    ];
    // No desktop up: what's written waits in the chat's queue (§18), for
    // an existing chat this phone may send to.
    final offline =
        beacon == null &&
        chat != null &&
        client != null &&
        me != null &&
        !me.revoked &&
        me.trustedBy.isNotEmpty;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          chat?.title ?? widget.title ?? 'New chat',
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          if (online.length > 1 && !running)
            PopupMenuButton<String>(
              tooltip: 'Run on',
              icon: const Icon(PhosphorIconsRegular.desktopTower),
              onSelected: (id) => setState(() => _target = id),
              itemBuilder: (_) => [
                for (final b in online)
                  CheckedPopupMenuItem(
                    value: b.deviceId,
                    checked: b.deviceId == beacon?.deviceId,
                    child: Text(b.name),
                  ),
              ],
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              reverse: true,
              padding: const EdgeInsets.all(16),
              children: [
                for (final sent in failed.reversed)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      sent.error!,
                      style: muted?.copyWith(color: theme.colorScheme.error),
                    ),
                  ),
                for (final sent in pending.reversed)
                  _PendingBubble(sent: sent, beacon: beacon?.name),
                if (live != null &&
                    !messages.any(
                      (m) =>
                          m.id == live.messageId &&
                          m.status != GaiaMessageStatus.streaming,
                    ))
                  _LiveReply(
                    live: live,
                    card: (card) => GaiaCardView(
                      card: card,
                      waiting: true,
                      picks: _picks[card.id] ?? const {},
                      // Any of several, as a reply's proposals come stacked.
                      onPick: onPick == null ? null : (i) => onPick(card, i),
                      onAllow: onAllow == null ? null : () => onAllow(card),
                      onReject: onReject == null ? null : () => onReject(card),
                    ),
                  )
                else if (running)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 12),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: GaiaSpinner(size: 20, label: 'Running'),
                    ),
                  ),
                for (final message in messages.reversed)
                  if (message.id == live?.messageId &&
                      message.status == GaiaMessageStatus.streaming)
                    const SizedBox.shrink()
                  else
                    GaiaTranscriptMessage(
                      key: ValueKey(message.id),
                      message: message,
                      openCard: message == last ? openCard : null,
                      picks: _picks,
                      onPick: onPick,
                      onAllow: onAllow,
                      onReject: onReject,
                    ),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // The chat's queue (§13): what goes next, sent by the
                  // beacon when drain is on, or from here.
                  if (queued.isNotEmpty)
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            [
                              queued.length == 1
                                  ? '1 queued'
                                  : '${queued.length} queued',
                              if (chat?.drain ?? false) 'drain on',
                              'next: ${queued.first.text.split('\n').first}',
                            ].join(' · '),
                            style: muted,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (paired && !running)
                          TextButton(
                            onPressed: () =>
                                _send(beacon, GaiaRemoteCommandType.queuePop),
                            child: const Text('Send next'),
                          ),
                      ],
                    ),
                  if (offline)
                    _Composer(
                      controller: _composer,
                      beaconName: '',
                      tier: null,
                      running: false,
                      hint: 'Queue a message for when a desktop is online',
                      onTier: (_) {},
                      onSend: _queueOffline,
                      onStop: () {},
                    )
                  else
                    !paired
                        ? Text(
                            client == null
                                ? 'Sign in to chat with Gaia from here.'
                                : beacon == null
                                ? 'No desktop is online. Chats run on a desktop '
                                      'with Gaia; this one will carry on when one is.'
                                : 'Pair this phone with ${beacon.name} on the Gaia '
                                      "page's Status tab to chat from here.",
                            style: muted,
                          )
                        : _Composer(
                            controller: _composer,
                            beaconName: beacon.name,
                            tier: _tier ?? chat?.tier,
                            running: running,
                            hint: switch (openCard?.kind) {
                              GaiaCardKind.question => 'Answer, or pick above',
                              GaiaCardKind.permission =>
                                'Why not? (sends Deny)',
                              GaiaCardKind.proposal =>
                                'What to change? (turns it down)',
                              GaiaCardKind.control => 'Why not? (sends Deny)',
                              null => 'Message Gaia on ${beacon.name}',
                            },
                            onTier: (tier) => setState(() => _tier = tier),
                            onSend: () => _submit(beacon, openCard),
                            onStop: () =>
                                _send(beacon, GaiaRemoteCommandType.cancel),
                          ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.beaconName,
    required this.tier,
    required this.running,
    required this.hint,
    required this.onTier,
    required this.onSend,
    required this.onStop,
  });

  final TextEditingController controller;
  final String beaconName;
  final GaiaTier? tier;
  final bool running;
  final String hint;
  final void Function(GaiaTier tier) onTier;
  final VoidCallback onSend;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        PopupMenuButton<GaiaTier>(
          tooltip: 'Tier',
          initialValue: tier,
          onSelected: onTier,
          itemBuilder: (_) => [
            for (final tier in GaiaTier.values)
              PopupMenuItem(value: tier, child: Text(tier.label)),
          ],
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 12),
            child: Text(tier?.label ?? 'Auto'),
          ),
        ),
        Expanded(
          child: VoyagerTextField(
            controller: controller,
            minLines: 1,
            maxLines: 6,
            textInputAction: TextInputAction.newline,
            decoration: InputDecoration(hintText: hint, isDense: true),
          ),
        ),
        const SizedBox(width: 8),
        if (running)
          IconButton.filledTonal(
            tooltip: 'Stop',
            onPressed: onStop,
            icon: const Icon(PhosphorIconsFill.stop),
          ),
        IconButton.filled(
          tooltip: 'Send',
          onPressed: onSend,
          icon: const Icon(PhosphorIconsFill.paperPlaneRight),
        ),
      ],
    );
  }
}

/// A message sent from here that hasn't synced back yet.
class _PendingBubble extends StatelessWidget {
  const _PendingBubble({required this.sent, required this.beacon});

  final _Sent sent;
  final String? beacon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: sent.error != null
          ? theme.colorScheme.error
          : theme.colorScheme.onSurfaceVariant,
    );
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12, left: 48),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: gaiaPromptColor(theme).withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(sent.text),
            const SizedBox(height: 4),
            Text(
              sent.error ??
                  switch (sent.status) {
                    GaiaRemoteCommandStatus.pending =>
                      'Sending to ${beacon ?? 'your desktop'}…',
                    GaiaRemoteCommandStatus.claimed => 'Starting…',
                    _ when sent.queued => 'Queued: it goes after this reply',
                    _ => 'Sent',
                  },
              style: muted,
            ),
          ],
        ),
      ),
    );
  }
}

/// The reply a beacon is streaming (§8.1).
class _LiveReply extends StatelessWidget {
  const _LiveReply({required this.live, required this.card});

  final GaiaLive live;

  /// An open card of [live]'s, as it's shown.
  final Widget Function(GaiaCardPart card) card;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (live.text.isNotEmpty) GaiaMarkdown(text: live.text),
          for (final open in live.cards) card(open),
          const SizedBox(height: 6),
          Row(
            children: [
              const GaiaSpinner(size: 16, label: 'Running'),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  live.status.isEmpty ? 'Writing…' : live.status,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// One message of a chat's transcript on the Gaia page. [openCard] is the
/// card answered here, with [picks] and the callbacks; without them every
/// card is a record.
class GaiaTranscriptMessage extends ConsumerWidget {
  const GaiaTranscriptMessage({
    super.key,
    required this.message,
    this.openCard,
    this.picks = const {},
    this.onPick,
    this.onAllow,
    this.onReject,
  });

  final GaiaMessage message;
  final GaiaCardPart? openCard;
  final Map<String, Set<int>> picks;
  final void Function(GaiaCardPart card, int index)? onPick;
  final void Function(GaiaCardPart card)? onAllow;
  final void Function(GaiaCardPart card)? onReject;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    if (message.role == GaiaMessageRole.user) {
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          margin: const EdgeInsets.only(bottom: 12, left: 48),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: gaiaPromptColor(theme),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (message.parts.whereType<GaiaContextPart>().firstOrNull
                  case final window?) ...[
                Text(window.label, style: muted),
                const SizedBox(height: 4),
              ],
              if (message.parts.whereType<GaiaElementPart>().firstOrNull
                  case final control?) ...[
                Text(control.label, style: muted),
                const SizedBox(height: 4),
              ],
              for (final quote in message.parts.whereType<GaiaQuotePart>()) ...[
                Text(
                  quote.label,
                  style: muted,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
              ],
              SelectableText(message.text),
              // By path: the file is on the device it came from.
              for (final file in message.parts.whereType<GaiaFilePart>())
                Text(file.reference, style: muted),
              if (message.parts.whereType<GaiaImagePart>() case final images
                  when images.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final image in images) GaiaPageImage(part: image),
                  ],
                ),
              ],
            ],
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (index, part) in message.parts.indexed)
            switch (part) {
              GaiaTextPart(:final text, :final checks) => GaiaMarkdown(
                text: text,
                checks: checks,
                onCheck: (task) => GaiaHost.instance.toggleCheck(
                  ref.read(gaiaRepositoryProvider),
                  message.id,
                  index,
                  task,
                  !checks.contains(task),
                ),
              ),
              GaiaActivityPart(:final tools) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: GaiaActivityChip(
                  label: 'Used ${tools.toSet().join(', ')}',
                  part: part,
                ),
              ),
              GaiaCardPart() when part.id == openCard?.id => GaiaCardView(
                card: part,
                waiting: true,
                picks: picks[part.id] ?? const {},
                onPick: onPick == null ? null : (i) => onPick!(part, i),
                onAllow: onAllow == null ? null : () => onAllow!(part),
                onReject: onReject == null ? null : () => onReject!(part),
              ),
              GaiaCardPart() => GaiaCardView(card: part),
              // Only the user's messages carry attachments and context.
              GaiaImagePart() ||
              GaiaFilePart() ||
              GaiaContextPart() ||
              GaiaElementPart() ||
              GaiaQuotePart() ||
              GaiaUnknownPart() => const SizedBox.shrink(),
            },
          if (message.status != GaiaMessageStatus.complete)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                switch (message.status) {
                  GaiaMessageStatus.streaming => 'Still running',
                  GaiaMessageStatus.error => message.error ?? 'Error',
                  GaiaMessageStatus.cancelled => 'Stopped',
                  GaiaMessageStatus.interrupted => 'Interrupted',
                  GaiaMessageStatus.aborted => 'Aborted',
                  GaiaMessageStatus.complete => '',
                },
                style: switch (message.status) {
                  GaiaMessageStatus.streaming => muted,
                  GaiaMessageStatus.error => muted?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                  _ => muted?.copyWith(color: kGaiaStatusRose),
                },
              ),
            ),
        ],
      ),
    );
  }
}

/// An image on a user's message (§9.3), as a thumbnail.
class GaiaPageImage extends ConsumerStatefulWidget {
  const GaiaPageImage({super.key, required this.part});

  final GaiaImagePart part;

  @override
  ConsumerState<GaiaPageImage> createState() => _GaiaPageImageState();
}

class _GaiaPageImageState extends ConsumerState<GaiaPageImage> {
  // Kept across rebuilds, which a streaming reply makes many of.
  late var _asset = ref.read(mediaServiceProvider).asset(widget.part.mediaId);

  @override
  void didUpdateWidget(GaiaPageImage old) {
    super.didUpdateWidget(old);
    if (old.part.mediaId != widget.part.mediaId) {
      _asset = ref.read(mediaServiceProvider).asset(widget.part.mediaId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final part = widget.part;
    const height = 120.0;
    final width = part.height == 0
        ? height
        : (height * part.width / part.height).clamp(40.0, 320.0);
    return FutureBuilder(
      future: _asset,
      builder: (context, snapshot) {
        final asset = snapshot.data;
        return SizedBox(
          width: width,
          height: height,
          child: asset == null
              ? Center(child: Text(gaiaImageToken(part.label)))
              : MediaImage(
                  asset: asset,
                  width: width,
                  height: height,
                  borderRadius: BorderRadius.circular(8),
                ),
        );
      },
    );
  }
}

/// "3:15 PM" today, else "Oct 30".
String gaiaWhen(DateTime at) {
  final now = DateTime.now();
  if (at.year == now.year && at.month == now.month && at.day == now.day) {
    return DateFormat.jm().format(at);
  }
  return at.year == now.year
      ? DateFormat.MMMd().format(at)
      : DateFormat.yMMMd().format(at);
}
