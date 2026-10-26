import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart'
    show TextEditingController, TextEditingValue, TextSelection;
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/features/gaia/adapters/claude_code/claude_code_runner.dart';
import 'package:voyager/features/gaia/adapters/gaia_clis.dart';
import 'package:voyager/features/gaia/adapters/gaia_agent_runner.dart';
import 'package:flutter/services.dart';
import 'package:voyager/features/gaia/companion/gaia_attachments.dart';
import 'package:voyager/features/gaia/companion/gaia_commands.dart';
import 'package:voyager/features/gaia/companion/gaia_debug.dart';
import 'package:voyager/features/gaia/companion/gaia_handoff.dart';
import 'package:voyager/features/gaia/companion/gaia_image_render.dart';
import 'package:voyager/features/gaia/companion/gaia_sidebar.dart';
import 'package:voyager/features/gaia/companion/gaia_window.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/gaia_pipe.dart';
import 'package:voyager/features/gaia/utility/gaia_utility.dart';

const _uuid = Uuid();

/// How often a streaming reply is written through to the main instance. The
/// companion's own view updates on every delta.
const _persistEvery = Duration(seconds: 1);

/// A finished run, as Gaia's own toast shows it.
typedef GaiaRunToast = ({
  String chatId,
  String title,
  String body,
  bool error,
  bool question,
});

/// The companion's state: chats read from and written to the main instance,
/// runs on each tier's agent, the window mode, Abort, and the drain before
/// an update (GAIA_HLD.md §3, §7, §14, §15.7).
class GaiaController extends ChangeNotifier {
  GaiaController({
    required this._pipe,
    required this._window,
    required this._runners,
    Map<String, Future<GaiaCliVersion?> Function()>? cliVersions,
    this._exit = exit,
    GaiaDebug? debug,
    GaiaSidebar? sidebar,
    this._utility,
    Future<String> Function()? clipboard,
    String? draftDirectory,
  }) : _clipboard = clipboard ?? _readClipboard,
       _draftDirectory = draftDirectory ?? Directory.systemTemp.path,
       _cliVersions =
           cliVersions ??
           {
             for (final MapEntry(:key, :value) in kGaiaClis.entries)
               key: value.version,
           },
       debug = debug ?? GaiaDebug(),
       sidebar = sidebar ?? GaiaSidebar();

  final GaiaPipe _pipe;
  final GaiaWindow _window;

  /// One per adapter id (`kGaia…Adapter`).
  final Map<String, GaiaAgentRunner> _runners;

  /// The debug menu's toggles; scripted replies play on [_scripted].
  final GaiaDebug debug;
  final _scripted = GaiaScriptedRunner();

  /// The Gaia window's sidebar: open or not, and its width.
  final GaiaSidebar sidebar;

  /// The router and chat titles (§5.1); null for none.
  final GaiaUtility? _utility;

  /// The clipboard's text, for `$CLIPBOARD` (§9.2).
  final Future<String> Function() _clipboard;

  static Future<String> _readClipboard() async =>
      (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? '';

  /// Where the draft's images wait until they're sent.
  final String _draftDirectory;

  /// The composer's text. Here rather than in the composer, so it outlives
  /// a mode change and a capture can add to it (§15.1).
  final draft = TextEditingController();

  /// The draft's images (§9.3), each named in [draft] by its `[image N]`.
  final draftImages = <GaiaDraftImage>[];

  /// Adds [bytes] to the draft as the next image, its token at the caret.
  Future<void> attachImage(Uint8List bytes) async {
    final file = File(p.join(_draftDirectory, '${_uuid.v4()}.img'));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);
    _attachFile(file.path);
  }

  /// [attachImage] for an image already in a file the draft can own.
  void _attachFile(String path) {
    final label = [
      gaiaNextImageLabel(messages),
      for (final image in draftImages) image.label + 1,
    ].reduce(max);
    draftImages.add(GaiaDraftImage(label: label, path: path));
    _insertInDraft(gaiaImageToken(label));
    notifyListeners();
  }

  /// The region capture being cropped on the overlay (§3.2): its file and
  /// its monitor's frame. Null when there's none.
  ({String path, GaiaFrame frame})? cropping;

  /// What the window was before the overlay, to go back to; null for
  /// hidden.
  GaiaMode? _beforeCrop;

  /// A capture from the main instance (§15.1): C crops it on the overlay,
  /// D attaches it whole. Either way Gaia ends up on screen with it in the
  /// draft.
  Future<void> _onCapture(Map<String, Object?> params) async {
    final path = params['path']! as String;
    // Over a crop's overlay, what the window was is still what was before it.
    final overCrop = cropping != null;
    _discardCrop();
    _dropPickUp();
    final shown = overCrop ? _beforeCrop : _window.shown;
    if (params['kind'] == 'screen') {
      _attachFile(await _intoDrafts(path));
      return _show(shown ?? GaiaMode.small);
    }
    _beforeCrop = shown;
    cropping = (
      path: path,
      frame: (
        left: params['left']! as int,
        top: params['top']! as int,
        width: params['width']! as int,
        height: params['height']! as int,
      ),
    );
    onScreen.value = true;
    await _window.show(GaiaMode.overlay, () {
      layout = GaiaMode.overlay;
      notifyListeners();
    }, frame: cropping!.frame);
  }

  /// The overlay's crop is done: [region], in the capture's pixels, joins
  /// the draft; null cancels. The window goes back to how it was, and a
  /// crop begun from hidden opens the small floater with it.
  Future<void> finishCrop(Rect? region) async {
    final capture = cropping;
    if (capture == null) return;
    cropping = null;
    try {
      if (region != null) {
        // Off screen while it renders, not the chat stretched over the
        // monitor.
        _window.hide();
        final png = await gaiaRenderPng(capture.path, crop: region);
        await attachImage(png);
      }
    } finally {
      unawaited(_deleteQuietly(capture.path));
    }
    final back = _beforeCrop ?? (region == null ? null : GaiaMode.small);
    if (back != null) return _show(back);
    _window.hide();
    onScreen.value = false;
    layout = GaiaMode.small;
    notifyListeners();
  }

  /// A crop left behind by another hotkey: its capture isn't wanted.
  void _discardCrop() {
    final capture = cropping;
    if (capture == null) return;
    cropping = null;
    unawaited(_deleteQuietly(capture.path));
  }

  /// [path] moved into the draft's own folder: the main instance sweeps
  /// its captures folder (§15.1).
  Future<String> _intoDrafts(String path) async {
    final target = p.join(_draftDirectory, '${_uuid.v4()}.img');
    await Directory(_draftDirectory).create(recursive: true);
    try {
      await File(path).rename(target);
    } on FileSystemException {
      // Another volume.
      await File(path).copy(target);
      unawaited(_deleteQuietly(path));
    }
    return target;
  }

  static Future<void> _deleteQuietly(String path) =>
      File(path).delete().then((_) {}, onError: (_) {});

  /// The small floater is too small to draw in: the annotation editor opens
  /// on the large one. True when it grew, for [restoreSmall] after.
  Future<bool> enlargeForEditor() async {
    if (_window.shown != GaiaMode.small) return false;
    await _show(GaiaMode.large);
    return true;
  }

  Future<void> restoreSmall() => _show(GaiaMode.small);

  /// The annotation editor's [edits] (§9.4) for the draft's [label],
  /// rendered for its thumbnail.
  Future<void> editDraftImage(int label, GaiaImageEdits edits) async {
    final index = draftImages.indexWhere((image) => image.label == label);
    if (index < 0) return;
    final image = draftImages[index];
    String? preview;
    if (!edits.isEmpty) {
      // A new name each time, so the thumbnail isn't the cached old one.
      preview = p.join(_draftDirectory, '${_uuid.v4()}-preview.png');
      await File(
        preview,
      ).writeAsBytes(await gaiaRenderPng(image.path, edits: edits));
    }
    if (image.preview case final old?) unawaited(_deleteQuietly(old));
    // Removed while it rendered.
    final at = draftImages.indexOf(image);
    if (at < 0) {
      if (preview != null) unawaited(_deleteQuietly(preview));
      return;
    }
    draftImages[at] = image.copyWith(edits: edits, preview: preview);
    notifyListeners();
  }

  /// Takes [label] out of the draft, and its token with it.
  void removeDraftImage(int label) {
    for (final image in draftImages.where((image) => image.label == label)) {
      unawaited(_deleteQuietly(image.path));
      if (image.preview case final preview?) {
        unawaited(_deleteQuietly(preview));
      }
    }
    draftImages.removeWhere((image) => image.label == label);
    final token = gaiaImageToken(label);
    final text = draft.text;
    final at = text.indexOf(token);
    if (at >= 0) {
      // The space the insert put before it goes too.
      final start = at > 0 && text[at - 1] == ' ' ? at - 1 : at;
      draft.value = TextEditingValue(
        text: text.replaceRange(start, at + token.length, ''),
        selection: TextSelection.collapsed(offset: start),
      );
    }
    notifyListeners();
  }

  /// Hands the draft's images to a send, which owns them from then on.
  List<GaiaDraftImage> takeDraftImages() {
    final images = [...draftImages];
    draftImages.clear();
    notifyListeners();
    return images;
  }

  /// [text] at the draft's caret, or at its end when it has none, set off
  /// from the text before it by a space.
  void _insertInDraft(String text) {
    final value = draft.value;
    final at = value.selection.isValid
        ? value.selection.end
        : value.text.length;
    final before = value.text.substring(0, at);
    final insert = before.isEmpty || before.trimRight() != before
        ? text
        : ' $text';
    draft.value = TextEditingValue(
      text: value.text.replaceRange(at, at, insert),
      selection: TextSelection.collapsed(offset: at + insert.length),
    );
  }

  /// The window Gaia was last summoned from (§15.4): a chip on the draft,
  /// which the next message takes with it unless the user removes it.
  GaiaContextPart? windowContext;

  void dropWindowContext() {
    windowContext = null;
    notifyListeners();
  }

  /// The text selected where Gaia was last summoned from, for `$SELECTION`
  /// (§9.2).
  var _summonSelection = '';

  /// Each sent image's local file, by media id, as the main instance says.
  final _imageFiles = <String, Future<String?>>{};

  /// The [_imageFiles] the main instance said aren't here, to ask again.
  final _missingImages = <String>{};

  /// The file holding a message's image; null while it isn't on this
  /// device. Asked once, and again after the next change the main instance
  /// reports, which may be the download that brought it.
  Future<String?> imageFile(String mediaId) =>
      _imageFiles[mediaId] ??= () async {
        try {
          final path =
              await _pipe.request('mediaFile', {'mediaId': mediaId}) as String?;
          if (path == null) _missingImages.add(mediaId);
          return path;
        } on GaiaPipeException {
          _missingImages.add(mediaId);
          return null;
        }
      }();

  /// Runs that finished in another chat while Gaia was on screen, for its
  /// own toast.
  Stream<GaiaRunToast> get toasts => _toasts.stream;
  final _toasts = StreamController<GaiaRunToast>.broadcast();

  /// Each CLI's `--version` by adapter, and how the companion ends:
  /// parameters for tests.
  final Map<String, Future<GaiaCliVersion?> Function()> _cliVersions;
  final void Function(int code) _exit;

  var aborted = false;
  var chats = <GaiaChat>[];

  /// Voyager's accent, as ARGB: the theme follows it.
  final accent = ValueNotifier(0xFF7C9EFF);

  /// On screen and in front, from the window's focus and blur; the
  /// starfield drifts only then.
  final focused = ValueNotifier(false);

  /// Whether the window is shown at all, in any mode. Off, every ticker
  /// is muted: a hidden window's tree stays alive, and the buttons' glow
  /// rings would otherwise keep asking for frames at the display's rate.
  final onScreen = ValueNotifier(false);

  /// The main instance's device, whose native sessions this companion runs.
  var _deviceId = '';

  /// Whether a run that finishes while Gaia is hidden raises a toast (§14).
  var _notifyOnDone = true;

  /// The configured agents and which tier points at which (§7.1).
  var agents = kGaiaDefaultAgents;
  var tiers = kGaiaDefaultTiers;

  /// The tier a new chat starts on (§7.2).
  var lastTier = GaiaTier.standard;

  /// The tier picked for the next message, over the chat's own (§7.2).
  GaiaTier? pickedTier;

  /// The user's slash commands (§9.2).
  var commands = const <GaiaCommand>[];

  /// Rebound keys (§9.1), by `GaiaKeybind` name.
  var keybinds = const <String, String>{};

  /// Null for a new chat not yet sent.
  String? currentChatId;
  final _messages = <String, List<GaiaMessage>>{};

  /// What the content is laid out for; [GaiaWindow.show] says when it
  /// changes.
  var layout = GaiaMode.small;

  /// Each CLI's version by adapter, once read; null when not installed.
  var cliVersions = <String, GaiaCliVersion?>{};
  var cliChecked = false;

  /// Runs still going while an update or quit waits on them (§3.2); null
  /// when nothing is draining.
  int? draining;

  /// The user chose to wait for [draining]'s runs rather than cancel them.
  var drainWaiting = false;

  /// The drain's Cancel stopped the runs: their replies are `interrupted`.
  var _drainCancelled = false;

  /// The mode to go back to when a floater opened over the Gaia window is
  /// dismissed (§3.3).
  GaiaMode? _returnTo;

  final _stopping = <String>{};
  final _running = <String>{};
  final _lastPersist = <String, DateTime>{};

  GaiaChat? get currentChat =>
      chats.where((chat) => chat.id == currentChatId).firstOrNull;

  List<GaiaMessage> get messages =>
      currentChatId == null ? const [] : _messages[currentChatId] ?? const [];

  bool isRunning(String chatId) => _running.contains(chatId);

  bool get currentRunning =>
      currentChatId != null && _running.contains(currentChatId);

  Future<void> start() async {
    await _window.init();
    _pipe
      ..onEvent = _onEvent
      ..onRequest = _onRequest
      ..onConnected = () {
        unawaited(_onConnected());
      }
      // The main instance is gone, let go of this companion, or never
      // answered: a companion never outlives it.
      ..onDisconnected = () {
        _scripted.killAll();
        unawaited(_killAll().whenComplete(() => _exit(0)));
      };
    if (!await _pipe.connect()) return _exit(0);
    unawaited(_checkCli());
  }

  Future<void> _onConnected() async {
    final hello = (await _pipe.request('hello'))! as Map;
    aborted = hello['aborted'] == true;
    accent.value = hello['accent']! as int;
    _deviceId = hello['deviceId']! as String;
    await _applySettings((hello['settings']! as Map).cast<String, Object?>());
    await _refresh();
  }

  Future<void> _checkCli() async {
    cliVersions = {
      for (final MapEntry(:key, :value) in _cliVersions.entries)
        key: await value(),
    };
    cliChecked = true;
    notifyListeners();
  }

  Future<void> _applySettings(Map<String, Object?> settings) async {
    _notifyOnDone = settings['notifyOnDone'] != false;
    _utility?.apply(settings);
    agents = gaiaAgentsFromJson(settings['agents']);
    tiers = gaiaTiersFromJson(settings['tiers']);
    lastTier = gaiaTierFromName(settings['lastTier']) ?? GaiaTier.standard;
    commands = gaiaCommandsFromJson(settings['commands']);
    keybinds = gaiaKeybindsFromJson(settings['keybinds']);
    final configDir = settings['claudeConfigDir'] as String? ?? '';
    // Another account's usage is unknown until it runs.
    if (configDir != _claudeConfigDir) usage.remove(kGaiaClaudeCodeAdapter);
    _claudeConfigDir = configDir;
    notifyListeners();
    if (_runners[kGaiaClaudeCodeAdapter] case final ClaudeCodeRunner claude) {
      claude.setConfigDir(configDir);
    }
    final instructions = settings['gaiaMd'] as String? ?? '';
    await Future.wait([
      for (final runner in _runners.values)
        runner.setInstructions(instructions),
    ]);
  }

  /// Each adapter's account usage as its last run that said left it (§6.2);
  /// one account per adapter until accounts come in Phase 7.
  final usage = <String, GaiaUsage>{};
  var _claudeConfigDir = '';

  /// The current chat's context at its last reply that said (§7.5).
  int? get contextTokens => messages.reversed
      .map((message) => message.contextTokens)
      .nonNulls
      .firstOrNull;

  /// Whether switching the current chat to [tier] needs the user's yes
  /// (§7.5): a change after the chat's first reply.
  bool switchNeedsConfirm(GaiaTier tier) =>
      tier != nextTier &&
      messages.any((message) => message.role == GaiaMessageRole.assistant);

  /// The tier the next message in the current chat goes to (§7.2).
  GaiaTier get nextTier => pickedTier ?? currentChat?.tier ?? lastTier;

  GaiaAgent? agentFor(GaiaTier tier) =>
      agents.where((agent) => agent.id == tiers[tier]).firstOrNull;

  /// The tier picker, for the next message.
  void pickTier(GaiaTier tier) {
    pickedTier = tier;
    notifyListeners();
  }

  Future<void> _killAll() =>
      Future.wait([for (final runner in _runners.values) runner.killAll()]);

  void _onEvent(String event, Map<String, Object?> params) {
    switch (event) {
      case 'hotkey':
        unawaited(onHotkey(params['key']! as String));
      case 'capture':
        unawaited(_onCapture(params));
      case 'context':
        windowContext = switch (params['window']) {
          final Map<Object?, Object?> json =>
            GaiaPart.fromJson(json.cast()) as GaiaContextPart,
          _ => null,
        };
        _summonSelection = params['selection'] as String? ?? '';
        notifyListeners();
      case 'refused':
        unawaited(_onRefused());
      case 'selection':
        unawaited(
          _onSelection(params['text'] as String?, params['source'] as String?),
        );
      case 'pickUp':
        unawaited(_onPickUp(armed: params['armed'] == true));
      case 'openChat':
        unawaited(openChat(params['chatId']! as String));
      case 'accent':
        accent.value = params['argb']! as int;
      case 'settings':
        unawaited(_applySettings(params));
      case 'changed':
        unawaited(_refresh());
    }
  }

  Future<Object?> _onRequest(String method, Map<String, Object?> params) async {
    switch (method) {
      case 'abort':
        await _abort();
        return null;
      case 'stop':
        await stop(params['chatId']! as String);
        return null;
      case 'drain':
        return _drain();
      default:
        throw GaiaPipeException('unknown method $method');
    }
  }

  /// Chats and messages changed in the main instance: written here, synced
  /// from another device, or pinned, renamed or deleted on the Gaia page.
  /// A chat running here keeps the messages it is writing.
  Future<void> _refresh() async {
    // An image that wasn't here may be now. One still being asked about
    // isn't waited on.
    _missingImages
      ..forEach(_imageFiles.remove)
      ..clear();
    final list = (await _pipe.request('chats'))! as List;
    chats = [
      for (final chat in list)
        GaiaChat.fromJson((chat as Map).cast<String, Object?>()),
    ];
    final current = currentChatId;
    if (current != null &&
        !_running.contains(current) &&
        !chats.any((chat) => chat.id == current)) {
      currentChatId = null;
    }
    _messages.removeWhere(
      (chatId, _) => !_running.contains(chatId) && chatId != currentChatId,
    );
    notifyListeners();
    final shown = currentChatId;
    if (shown != null && !_running.contains(shown)) await _load(shown);
  }

  /// What the window was before pick-up mode's pill (§15.3), to go back
  /// to; null for hidden.
  GaiaMode? _beforePickUp;
  var _pickingUp = false;

  /// Pick-up mode armed: Gaia hides behind its "selecting" pill while the
  /// user selects something. Disarmed by Esc, it goes back to how it was.
  Future<void> _onPickUp({required bool armed}) async {
    if (armed == _pickingUp) return;
    _pickingUp = armed;
    if (armed) {
      if (cropping != null) await finishCrop(null);
      _beforePickUp = _window.shown;
      return _show(GaiaMode.pickUp);
    }
    await _leavePickUp(selected: false);
  }

  /// The pill's own cancel: the main instance stops waiting for F.
  Future<void> cancelPickUp() async {
    if (!_pickingUp) return;
    _pickingUp = false;
    _pipe.notify('pickUpCancelled');
    await _leavePickUp(selected: false);
  }

  /// Another summon in pick-up mode, which the main instance ended: the
  /// pill goes, and the summon is taken from hidden.
  void _dropPickUp() {
    if (!_pickingUp) return;
    _pickingUp = false;
    _beforePickUp = null;
    _window.hide();
  }

  /// Out of the pill: back to how Gaia was, or with a selection to show,
  /// the small floater when it was hidden.
  Future<void> _leavePickUp({required bool selected}) async {
    final back = _beforePickUp ?? (selected ? GaiaMode.small : null);
    _beforePickUp = null;
    if (back != null) return _show(back);
    _window.hide();
    onScreen.value = false;
    layout = GaiaMode.small;
    notifyListeners();
  }

  /// E, or F's second press (§15.2, §15.3): [text], quoted with its
  /// [source], goes at the end of the draft, and Gaia comes up with it.
  Future<void> _onSelection(String? text, String? source) async {
    if (text != null) {
      final quote = gaiaQuoteSelection(text, source);
      final draftText = draft.text.trimRight();
      final joined = draftText.isEmpty ? quote : '$draftText\n\n$quote';
      draft.value = TextEditingValue(
        text: '$joined\n\n',
        selection: TextSelection.collapsed(offset: joined.length + 2),
      );
    } else {
      _toasts.add((
        chatId: '',
        title: 'Nothing selected',
        body: "Gaia couldn't find selected text there.",
        error: false,
        question: false,
      ));
    }
    if (_pickingUp) {
      _pickingUp = false;
      return _leavePickUp(selected: true);
    }
    if (cropping != null) await finishCrop(null);
    await _show(_window.shown ?? GaiaMode.small);
  }

  /// A capture hotkey while aborted (§15.7): Gaia comes up saying so.
  Future<void> _onRefused() async {
    _toasts.add((
      chatId: '',
      title: 'Gaia is aborted',
      body: 'Re-arm it to capture again.',
      error: true,
      question: false,
    ));
    if (_window.shown == null) await _show(GaiaMode.small);
  }

  /// The hotkey table in §15.1.
  Future<void> onHotkey(String key) async {
    // Mid-crop, any of them cancels it.
    if (cropping != null) return finishCrop(null);
    _dropPickUp();
    final shown = _window.shown;
    switch (key) {
      case 'small':
        if (shown == GaiaMode.small) return dismiss();
        _returnTo = shown == GaiaMode.window ? GaiaMode.window : _returnTo;
        await _show(GaiaMode.small);
      case 'large':
        _returnTo = shown == GaiaMode.window ? GaiaMode.window : _returnTo;
        await _show(GaiaMode.large);
      case 'window':
        await openWindow();
    }
  }

  Future<void> openWindow() async {
    _returnTo = null;
    await _show(GaiaMode.window);
  }

  /// A notification clicked, or a chat picked on the Gaia page.
  Future<void> openChat(String chatId) async {
    await openWindow();
    await selectChat(chatId);
  }

  /// Escape or close: a floater opened over the Gaia window turns back into
  /// it; anything else hides. Runs carry on (§14).
  Future<void> dismiss() async {
    if (cropping != null) return finishCrop(null);
    if (_pickingUp) return cancelPickUp();
    final back = _returnTo;
    _returnTo = null;
    if (back != null && _window.shown != back) return _show(back);
    _window.hide();
    onScreen.value = false;
  }

  Future<void> _show(GaiaMode mode) {
    if (currentChatId == null) _utility?.warm();
    onScreen.value = true;
    return _window.show(mode, () {
      layout = mode;
      notifyListeners();
    });
  }

  void newChat() {
    currentChatId = null;
    pickedTier = null;
    _utility?.warm();
    notifyListeners();
  }

  Future<void> selectChat(String chatId) async {
    if (chatId != currentChatId) pickedTier = null;
    currentChatId = chatId;
    notifyListeners();
    if (_messages.containsKey(chatId)) return;
    await _load(chatId);
  }

  Future<void> _load(String chatId) async {
    final list = (await _pipe.request('messages', {'chatId': chatId}))! as List;
    // A run that started meanwhile has the newer list.
    if (_running.contains(chatId)) return;
    _messages[chatId] = [
      for (final message in list)
        GaiaMessage.fromJson((message as Map).cast<String, Object?>()),
    ];
    notifyListeners();
  }

  /// Runs a built-in command (§9.2).
  Future<void> runBuiltin(GaiaBuiltin builtin) async {
    switch (builtin) {
      case GaiaBuiltin.newChat:
        newChat();
      case GaiaBuiltin.stop:
        if (currentChatId case final chatId?) await stop(chatId);
    }
  }

  /// [text] with a user's command expanded (§9.2); [text] itself when it
  /// doesn't start with one.
  Future<String> _expand(String text) async {
    final name = RegExp(r'^/([\w-]+)').firstMatch(text)?.group(1);
    final command = commands.where((c) => c.name == name).firstOrNull;
    if (command == null) return text;
    return expandGaiaCommand(
          text,
          commands,
          clipboard: command.template.contains(r'$CLIPBOARD')
              ? await _clipboard()
              : '',
          now: DateTime.now(),
          selection: _summonSelection,
        ) ??
        text;
  }

  /// Sends [text] with [images] (§9.3), which this send now owns.
  Future<void> send(
    String text, {
    List<GaiaDraftImage> images = const [],
  }) async {
    if (gaiaBuiltinIn(text) case final builtin?) return runBuiltin(builtin);
    var prompt = (await _expand(text.trim())).trim();
    if (prompt.isEmpty && images.isEmpty) return;
    var chat = currentChat;
    if (aborted ||
        draining != null ||
        _startingChat ||
        chat != null && _running.contains(chat.id)) {
      return _giveBack(text, images);
    }
    // Claimed now, so a second send can't start while this one's images
    // upload or its tier is picked.
    final chatId = chat?.id ?? _uuid.v4();
    if (chat != null) {
      _running.add(chatId);
    } else {
      _startingChat = true;
    }
    // Numbered on from the chat's images, so no two of its messages have
    // the same [image N].
    final (relabeled, labeled) = gaiaRelabelDraft(
      prompt,
      images,
      gaiaNextImageLabel(_messages[chatId] ?? const []),
    );
    final imageParts = <GaiaImagePart>[];
    final imageInputs = <GaiaImageInput>[];
    final referenceIds = <String>[];
    final uploads = <String>[];
    // Taken off the chat again when the send doesn't happen.
    void detach() {
      for (final referenceId in referenceIds) {
        unawaited(_request('detachImage', {'referenceId': referenceId}));
      }
    }

    // Before anything is saved: an image that can't be attached stops the
    // send, and it all goes back in the draft.
    for (final image in labeled) {
      try {
        // Edits are flattened now (§9.4), and a capture is a BMP, which the
        // media module doesn't take.
        final upload = await gaiaUploadablePath(image.path, edits: image.edits);
        if (upload != image.path) uploads.add(upload);
        final stored =
            (await _pipe.request('attachImage', {
                  'chatId': chatId,
                  'path': upload,
                }))!
                as Map;
        final mediaId = stored['mediaId']! as String;
        final path = stored['path']! as String;
        _imageFiles[mediaId] = Future.value(path);
        referenceIds.add(stored['referenceId']! as String);
        imageParts.add(
          GaiaImagePart(
            mediaId: mediaId,
            label: image.label,
            width: stored['width']! as int,
            height: stored['height']! as int,
          ),
        );
        imageInputs.add((
          label: image.label,
          path: path,
          mimeType: stored['mimeType']! as String,
        ));
      } catch (error) {
        uploads.forEach(_deleteQuietly);
        detach();
        _running.remove(chatId);
        _startingChat = false;
        _toasts.add((
          chatId: '',
          title: "Couldn't attach ${gaiaImageToken(image.label)}",
          body: error is GaiaPipeException ? error.message : '$error',
          error: true,
          question: false,
        ));
        return _giveBack(text, images);
      }
    }
    uploads.forEach(_deleteQuietly);
    prompt = relabeled;
    // The summon's window goes with this message only.
    final context = windowContext;
    windowContext = null;
    final now = utcNow();
    var tier = nextTier;
    // The router picks only a new chat's first tier, and never over the
    // user's own pick (§7.2).
    if (chat == null && pickedTier == null) {
      if (_utility == null) debugPrint('[gaia] router: no utility model');
      tier = await _utility?.route(prompt) ?? tier;
    } else {
      debugPrint(
        '[gaia] router: skipped, '
        '${chat != null ? 'not a new chat' : 'tier picked: ${pickedTier!.name}'}',
      );
    }
    debugPrint('[gaia] router: sending on ${tier.name}');
    pickedTier = null;
    final agent = agentFor(tier);
    if (chat == null) {
      // No utility model yet: the title is the first line (§5.1).
      final firstLine = prompt.isEmpty ? 'Image' : prompt.split('\n').first;
      chat = GaiaChat(
        id: chatId,
        title: firstLine.length > 60
            ? '${firstLine.substring(0, 60)}…'
            : firstLine,
        createdAt: now,
        updatedAt: now,
        lastMessageAt: now,
        tier: tier,
      );
      chats = [chat, ...chats];
      _messages[chatId] = [];
      currentChatId = chatId;
      _running.add(chatId);
      _startingChat = false;
      try {
        await _pipe.request('putChat', {'chat': chat.toJson()});
      } on GaiaPipeException catch (error) {
        // The main instance is going away: no run whose chat can't be kept.
        debugPrint('[gaia] chat not saved, not sending: $error');
        chats = [
          for (final c in chats)
            if (c.id != chatId) c,
        ];
        _messages.remove(chatId);
        _running.remove(chatId);
        if (currentChatId == chatId) currentChatId = null;
        detach();
        windowContext = context;
        return _giveBack(text, images);
      }
    }
    // Sent: the main instance keeps its own copies.
    for (final image in images) {
      for (final path in {image.path, ?image.preview}) {
        unawaited(_deleteQuietly(path));
      }
    }
    if (chat.tier != tier) {
      chat = chat.copyWith(tier: tier);
      chats = [for (final c in chats) c.id == chatId ? chat : c];
      unawaited(_request('setTier', {'chatId': chatId, 'tier': tier.name}));
    }
    if (tier != lastTier) {
      lastTier = tier;
      unawaited(_request('setLastTier', {'tier': tier.name}));
    }
    final list = _messages[chatId] ??= [];
    final script = debug.scriptFor(prompt);
    final runner = agent == null ? null : _runners[agent.adapter];
    final seq = list.isEmpty ? 0 : list.last.seq + 1;
    final question = GaiaMessage(
      id: _uuid.v4(),
      chatId: chatId,
      seq: seq,
      role: GaiaMessageRole.user,
      parts: [GaiaTextPart(prompt), ...imageParts, ?context],
      status: GaiaMessageStatus.complete,
      createdAt: now,
      updatedAt: now,
    );
    var reply = GaiaMessage(
      id: _uuid.v4(),
      chatId: chatId,
      seq: seq + 1,
      role: GaiaMessageRole.assistant,
      parts: const [],
      status: GaiaMessageStatus.streaming,
      createdAt: now,
      updatedAt: now,
      model: script == null ? agent?.model : 'gaia-debug-script',
      adapter: script == null ? agent?.adapter : null,
    );
    list.addAll([question, reply]);
    _moveToTop(chatId, now);
    _reportRuns();
    notifyListeners();
    unawaited(_persist(question));
    unawaited(_persist(reply));

    final builder = GaiaTurnBuilder();
    var session = agent == null
        ? null
        : chat.agentSessions[gaiaSessionKey(_deviceId, adapter: agent.adapter)];
    // Here at once, so a next message straight away resumes it; the main
    // instance's copy follows. A null [sessionId] drops the chat's.
    void recordSession(String adapter, String? sessionId) {
      final key = gaiaSessionKey(_deviceId, adapter: adapter);
      if (_chat(chatId) case final current?) {
        final updated = current.copyWith(
          agentSessions: sessionId == null
              ? ({...current.agentSessions}..remove(key))
              : {
                  ...current.agentSessions,
                  key: GaiaAgentSession(
                    sessionId: sessionId,
                    lastSeq: reply.seq,
                  ),
                },
        );
        chats = [for (final c in chats) c.id == chatId ? updated : c];
      }
      unawaited(
        _request('setSession', {
          'chatId': chatId,
          'adapter': adapter,
          'sessionId': sessionId,
          'lastSeq': reply.seq,
        }),
      );
    }

    // What the session didn't see: the whole chat for a new session, or
    // the turns another agent or device took since (§7.4).
    // The window it was asked from goes ahead of it (§15.4).
    final asked = context == null ? prompt : '${context.preamble}\n\n$prompt';
    Future<String> handedOver() async {
      if (script != null || agent == null || runner == null) return asked;
      final unseen = gaiaUnseenTurns(
        list,
        lastSeq: session?.lastSeq ?? -1,
        beforeSeq: seq,
      );
      if (unseen.isEmpty) return asked;
      final (older, recent) = gaiaSplitHandoff(unseen);
      final summary = older.isEmpty
          ? null
          : await _utility?.summarize(gaiaTranscriptText(older));
      return '${gaiaHandoffPreamble(recent: recent, joining: session == null, summary: summary, omitted: summary == null ? older.length : 0, labels: {for (final a in agents) a.model: a.label})}\n$asked';
    }

    final sent = await handedOver();
    var retried = false;
    String failed(Object error) => retried
        ? "This chat's earlier session wasn't found, and starting a new one "
              'failed too: $error'
        : '$error';
    final configDir = _claudeConfigDir;
    void onEvent(GaiaAgentEvent event) {
      // Kept as it comes, so a turn stopped later still counts. One from a
      // run on the account before a config dir change isn't this one's.
      if (event case GaiaUsageUpdate(
        usage: final turnUsage,
      ) when agent != null && configDir == _claudeConfigDir) {
        usage[agent.adapter] = turnUsage;
        notifyListeners();
      }
      if (!builder.apply(event)) return;
      reply = _replace(reply, reply.copyWith(parts: builder.parts));
      final last = _lastPersist[reply.id];
      if (last == null || DateTime.now().difference(last) > _persistEvery) {
        unawaited(_persist(reply));
      }
    }

    try {
      var result = script != null
          ? await _scripted.send(
              chatId: chatId,
              script: script,
              replyDelay: debug.replyDelay,
              streamSpeed: debug.streamSpeed,
              onEvent: onEvent,
            )
          : agent == null
          ? GaiaTurnResult(
              sessionId: '',
              isError: true,
              text:
                  'No agent is set for ${tier.label}. Pick one on the Gaia '
                  'page.',
            )
          : runner == null
          ? GaiaTurnResult(
              sessionId: '',
              isError: true,
              text: "${agent.label} can't run on this device.",
            )
          : await runner.send(
              chatId: chatId,
              sessionId: session?.sessionId,
              model: agent.model,
              prompt: sent,
              images: imageInputs,
              onEvent: onEvent,
            );
      // A resume that found no session, say one under another Claude config
      // folder: once more as a new session with the chat handed over.
      if (session != null &&
          !result.sessionFound &&
          !_stopping.contains(chatId)) {
        // Dropped first: a retry that dies still leaves it gone.
        session = null;
        retried = true;
        recordSession(agent!.adapter, null);
        result = await runner!.send(
          chatId: chatId,
          sessionId: null,
          model: agent.model,
          prompt: await handedOver(),
          images: imageInputs,
          onEvent: onEvent,
        );
      }
      // A scripted reply, or one no agent ran, has no session to resume. A failed turn's is kept when it was already
      // the chat's, or the agent got as far as replying or a tool; a
      // new one that failed straight away, like "Not logged in", exists
      // only where the login wasn't (BUG-317). One a resume didn't find
      // is dropped.
      final keep =
          result.sessionFound &&
          (!result.isError || session != null || builder.finished.isNotEmpty);
      if (result.sessionId.isNotEmpty &&
          agent != null &&
          (keep || session != null)) {
        recordSession(agent.adapter, keep ? result.sessionId : null);
      }
      final parts = builder.finished;
      reply = _replace(
        reply,
        result.isError
            ? reply.copyWith(
                parts: parts,
                status: GaiaMessageStatus.error,
                error: failed(result.text),
              )
            : reply.copyWith(
                parts: parts,
                status: GaiaMessageStatus.complete,
                contextTokens: result.contextTokens,
                needsInput: gaiaEndsWithQuestion(
                  parts.whereType<GaiaTextPart>().lastOrNull?.text ?? '',
                ),
              ),
      );
    } catch (error) {
      final stopped = _stopping.contains(chatId);
      reply = _replace(
        reply,
        reply.copyWith(
          parts: builder.finished,
          status: aborted
              ? GaiaMessageStatus.aborted
              : _drainCancelled
              ? GaiaMessageStatus.interrupted
              : stopped
              ? GaiaMessageStatus.cancelled
              : GaiaMessageStatus.error,
          error: aborted || _drainCancelled || stopped ? null : failed(error),
        ),
      );
    } finally {
      _stopping.remove(chatId);
      _running.remove(chatId);
      _lastPersist.remove(reply.id);
      _reportRuns();
      notifyListeners();
    }
    await _persist(reply);
    _reportDone(chatId, reply);
    if (reply.seq == 1 && reply.status == GaiaMessageStatus.complete) {
      unawaited(_retitle(chatId, prompt, reply.text));
    }
    _settleDrain();
  }

  /// A new chat's first send is under way, before the chat exists.
  var _startingChat = false;

  /// A send that didn't happen: its [text] and [images] go back in the
  /// draft, the text unless the user has typed again.
  void _giveBack(String text, List<GaiaDraftImage> images) {
    if (draft.text.isEmpty) draft.text = text;
    draftImages.addAll(images);
    notifyListeners();
  }

  Future<void> stop(String chatId) async {
    if (!_running.contains(chatId)) return;
    _stopping.add(chatId);
    _scripted.stop(chatId);
    await Future.wait([
      for (final runner in _runners.values) runner.stop(chatId),
    ]);
  }

  /// Tells the main instance which chats are running, for the tray and the
  /// Gaia page (§14).
  void _reportRuns() => _pipe.notify('runs', {
    'runs': [
      for (final chatId in _running)
        {'chatId': chatId, 'title': _chat(chatId)?.title ?? ''},
    ],
  });

  /// A reply that finished while Gaia was hidden, or its window behind other
  /// apps, raises a Windows toast (§14), one that ends on a question saying
  /// so (§10.1). In front, Gaia's own toast says the same, unless the chat is
  /// the one in view; a floater, topmost and so still on screen while
  /// another app has focus, shows it for every chat.
  void _reportDone(String chatId, GaiaMessage reply) {
    if (!_notifyOnDone || draining != null) return;
    final front = _window.foreground;
    if (front && chatId == currentChatId) return;
    final floating =
        _window.shown == GaiaMode.small || _window.shown == GaiaMode.large;
    final String title;
    final String body;
    switch (reply.status) {
      case GaiaMessageStatus.complete:
        title = reply.needsInput ? 'Gaia has a question' : 'Gaia is done';
        final line = reply.text.trim().split('\n').first;
        body = line.length > 120 ? '${line.substring(0, 120)}…' : line;
      case GaiaMessageStatus.error:
        title = 'Gaia ran into an error';
        body = reply.error ?? '';
      default:
        return;
    }
    final chatTitle = _chat(chatId)?.title ?? '';
    final toast = (
      chatId: chatId,
      title: title,
      body: chatTitle.isEmpty ? body : '$chatTitle: $body',
      error: reply.status == GaiaMessageStatus.error,
      question: reply.needsInput,
    );
    if (front || floating) {
      _toasts.add(toast);
      return;
    }
    _pipe.notify('runDone', {
      'chatId': toast.chatId,
      'title': toast.title,
      'body': toast.body,
    });
  }

  /// The main instance is about to quit or update (§3.2). With runs going,
  /// the Gaia window asks whether to wait for them or cancel them; `drained`
  /// follows once none are left.
  Future<Object?> _drain() async {
    final running = _running.length;
    if (running == 0) return {'running': 0};
    draining = running;
    drainWaiting = false;
    unawaited(openWindow());
    notifyListeners();
    return {'running': running};
  }

  void waitForDrain() {
    drainWaiting = true;
    notifyListeners();
  }

  /// Stops every run; each reply is kept, marked `interrupted`.
  Future<void> cancelDrain() async {
    _drainCancelled = true;
    _scripted.killAll();
    await _killAll();
  }

  void _settleDrain() {
    if (draining == null) return;
    draining = _running.length;
    if (_running.isEmpty) {
      draining = null;
      _pipe.notify('drained');
    }
    notifyListeners();
  }

  /// Every run is killed with its process tree, and each reply it was
  /// writing saved as aborted, before the main instance hears back (§15.7).
  Future<void> _abort() async {
    aborted = true;
    final saves = <Future<void>>[];
    for (final list in _messages.values) {
      for (final message in list) {
        if (message.status != GaiaMessageStatus.streaming) continue;
        saves.add(
          _persist(
            _replace(
              message,
              message.copyWith(status: GaiaMessageStatus.aborted),
            ),
          ),
        );
      }
    }
    notifyListeners();
    _scripted.killAll();
    await Future.wait([_killAll(), ...saves]);
  }

  Future<void> rearm() async {
    await _pipe.request('rearm');
    aborted = false;
    notifyListeners();
  }

  GaiaChat? _chat(String id) => chats.where((c) => c.id == id).firstOrNull;

  void _moveToTop(String chatId, DateTime at) {
    final chat = _chat(chatId)!;
    chats = [
      chat.copyWith(lastMessageAt: at),
      for (final c in chats)
        if (c.id != chatId) c,
    ];
  }

  /// Swaps [updated] in for [old] in its chat's list, and redraws.
  GaiaMessage _replace(GaiaMessage old, GaiaMessage updated) {
    final list = _messages[old.chatId];
    final index = list?.indexWhere((m) => m.id == old.id) ?? -1;
    if (index >= 0) list![index] = updated;
    notifyListeners();
    return updated;
  }

  /// The utility model's title for a chat's first exchange, over the
  /// first-line one it started with, unless it was renamed meanwhile.
  Future<void> _retitle(String chatId, String prompt, String reply) async {
    final from = _chat(chatId)?.title;
    if (from == null) return;
    final title = await _utility?.title(prompt, reply);
    final current = _chat(chatId);
    if (title == null || current == null || current.title != from) return;
    chats = [
      for (final c in chats) c.id == chatId ? c.copyWith(title: title) : c,
    ];
    notifyListeners();
    await _request('setTitle', {
      'chatId': chatId,
      'title': title,
      'from': from,
    });
  }

  /// A write to the main instance the run doesn't wait on: one lost to a
  /// main instance going away is only logged.
  Future<void> _request(String method, Map<String, Object?> params) async {
    try {
      await _pipe.request(method, params);
    } on GaiaPipeException catch (error) {
      debugPrint('[gaia] $method not saved: $error');
    }
  }

  Future<void> _persist(GaiaMessage message) async {
    _lastPersist[message.id] = DateTime.now();
    try {
      await _pipe.request('putMessage', {'message': message.toJson()});
    } on GaiaPipeException catch (error) {
      debugPrint('[gaia] message not saved: $error');
    }
  }
}
