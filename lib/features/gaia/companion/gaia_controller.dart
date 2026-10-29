import 'dart:async';
import 'dart:convert';
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
import 'package:voyager/features/gaia/companion/gaia_chat_tools.dart';
import 'package:voyager/features/gaia/companion/gaia_commands.dart';
import 'package:voyager/features/gaia/companion/gaia_debug.dart';
import 'package:voyager/features/gaia/companion/gaia_handoff.dart';
import 'package:voyager/features/gaia/companion/gaia_image_render.dart';
import 'package:voyager/features/gaia/companion/gaia_sidebar.dart';
import 'package:voyager/features/gaia/companion/gaia_window.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/domain/models/media_models.dart';
import 'package:voyager/features/gaia/gaia_pipe.dart';
import 'package:voyager/features/gaia/tools/gaia_mcp.dart';
import 'package:voyager/features/gaia/tools/gaia_proposals.dart';
import 'package:voyager/features/gaia/utility/gaia_utility.dart';

const _uuid = Uuid();

/// How often a streaming reply is written through to the main instance. The
/// companion's own view updates on every delta.
const _persistEvery = Duration(seconds: 1);

/// How long a handoff waits for its images' captions before it goes with
/// the files alone; the captions carry on, for the next one.
const _captionWait = Duration(seconds: 20);

/// How many messages' images are captioned at once: each is a CLI process.
const _captionsAtOnce = 3;

/// How soon a changed draft is saved (§9.3).
const _saveDraftsAfter = Duration(seconds: 1);

/// A finished run, as Gaia's own toast shows it.
typedef GaiaRunToast = ({
  String chatId,
  String title,
  String body,
  bool error,
  bool question,
});

/// A chat's draft while it's out of view.
typedef _Draft = ({
  TextEditingValue text,
  List<GaiaDraftImage> images,
  List<GaiaFilePart> files,
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
    @visibleForTesting this._cardHold = kGaiaCardHold,
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

  /// How long a card holds its tool call (§10.1).
  final Duration _cardHold;

  /// The composer's text for the chat in view. Here rather than in the
  /// composer, so it outlives a mode change and a capture can add to it
  /// (§15.1).
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

  /// The draft's files and folders (§9.3), shown above it but not named in
  /// it: the user calls one by its name.
  final draftFiles = <GaiaFilePart>[];

  /// Picked from the composer's +: an image joins as an image, anything
  /// else, and every folder, by its path.
  Future<void> attachPaths(List<String> paths, {bool folder = false}) async {
    for (final path in paths) {
      if (!folder &&
          _imageExtensions.contains(p.extension(path).toLowerCase())) {
        try {
          await attachImage(await File(path).readAsBytes());
          continue;
        } on FileSystemException catch (error) {
          // Unreadable here: it goes by its path, like any other file.
          debugPrint('[gaia] attach: $path not read as an image: $error');
        }
      }
      // Picked twice, it's still one.
      if (draftFiles.any((file) => p.equals(file.path, path))) continue;
      draftFiles.add(GaiaFilePart(path: path, folder: folder));
    }
    notifyListeners();
  }

  /// What media ingest takes, less HEIC: Windows may not decode it, and a
  /// refused image fails the whole send. The rest go by path.
  static const _imageExtensions = {'.png', '.jpg', '.jpeg', '.webp'};

  /// [attachImage] for an image already in a file the draft can own.
  void _attachFile(String path) {
    final label = _nextDraftLabel();
    draftImages.add(GaiaDraftImage(label: label, path: path));
    _insertInDraft(gaiaImageToken(label));
    notifyListeners();
    unawaited(_ingest(path));
  }

  /// The label the next image in the draft in view gets.
  int _nextDraftLabel() => [
    gaiaNextImageLabel(messages),
    for (final image in draftImages) image.label + 1,
    for (final image in arrivingImages) image.label + 1,
    for (final image
        in _unfetched[_keyOf(currentChatId)] ?? const <GaiaDraftImageRecord>[])
      image.label + 1,
  ].reduce(max);

  /// The main instance takes the draft image at [path] in, so the kept
  /// draft can name it. Refused, it stays in this draft alone, and its
  /// send says why.
  Future<void> _ingest(String path) async {
    try {
      final mediaId =
          (await _pipe.request('ingestImage', {'path': path}))! as String;
      _ingested(path, mediaId);
    } on GaiaPipeException catch (error) {
      debugPrint('[gaia] draft image not kept: $error');
    }
  }

  /// The region capture being cropped on the overlay (§3.2): its file and
  /// its monitor's frame. Null when there's none.
  ({String path, GaiaFrame frame})? cropping;

  /// What the window was before the overlay, to go back to; null for
  /// hidden.
  GaiaMode? _beforeCrop;

  /// Up but behind other apps before the overlay: a cancel puts it back
  /// there rather than in front.
  var _cropBehind = false;

  /// A capture from the main instance (§15.1): C crops it on the overlay,
  /// D attaches it whole. Either way Gaia ends up on screen with it in the
  /// draft.
  Future<void> _onCapture(Map<String, Object?> params) async {
    final path = params['path']! as String;
    final GaiaFrame frame = (
      left: params['left']! as int,
      top: params['top']! as int,
      width: params['width']! as int,
      height: params['height']! as int,
    );
    // C again over its own crop, on the same monitor: the crop stays.
    if (params['kind'] == 'region' && cropping?.frame == frame) {
      return _deleteQuietly(path);
    }
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
    if (!overCrop) _cropBehind = shown != null && !_window.foreground;
    cropping = (path: path, frame: frame);
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
        _window.hide(between: true);
        final png = await gaiaRenderPng(capture.path, crop: region);
        await attachImage(png);
      }
    } finally {
      unawaited(_deleteQuietly(capture.path));
    }
    final back = _beforeCrop ?? (region == null ? null : GaiaMode.small);
    if (back != null) return _show(back, behind: region == null && _cropBehind);
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
    // Removed while it rendered. By its file: an ingest or a kept draft
    // may have replaced its entry meanwhile.
    final at = draftImages.indexWhere((held) => held.path == image.path);
    if (at < 0) {
      if (preview != null) unawaited(_deleteQuietly(preview));
      return;
    }
    draftImages[at] = draftImages[at].copyWith(edits: edits, preview: preview);
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
    _arriving[_keyOf(currentChatId)]?.removeWhere(
      (image) => image.label == label,
    );
    if (_arriving[_keyOf(currentChatId)]?.isEmpty ?? false) {
      _arriving.remove(_keyOf(currentChatId));
    }
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

  /// Takes [file] out of the draft.
  void removeDraftFile(GaiaFilePart file) {
    draftFiles.remove(file);
    notifyListeners();
  }

  /// [takeDraftImages] for the draft's files and folders.
  List<GaiaFilePart> takeDraftFiles() {
    final files = [...draftFiles];
    draftFiles.clear();
    notifyListeners();
    return files;
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

  /// Messages attached to the draft as context, chips on it like
  /// [windowContext]'s. They stay on it from one chat to another.
  final draftQuotes = <GaiaQuotePart>[];

  void attachMessage(GaiaMessage message) {
    // Attached twice, it's still one.
    if (draftQuotes.any(
      (quote) => quote.role == message.role && quote.text == message.text,
    )) {
      return;
    }
    draftQuotes.add(GaiaQuotePart(role: message.role, text: message.text));
    notifyListeners();
  }

  void removeDraftQuote(GaiaQuotePart quote) {
    draftQuotes.remove(quote);
    notifyListeners();
  }

  /// Each chat's text, images and files while another chat is in view, by
  /// [_keyOf] its chat. The one in view is [draft], [draftImages] and
  /// [draftFiles]; quotes and the window go with whichever chat is in view.
  final _drafts = <String, _Draft>{};

  /// [chatId]'s draft's key, here and in the main instance's store.
  static String _keyOf(String? chatId) => chatId ?? GaiaDraft.newChatId;

  /// Brings [chatId] into view with its own draft, the one in view put
  /// away for when its chat is back.
  void _viewChat(String? chatId) {
    if (chatId == currentChatId) return;
    if (draft.text.isNotEmpty ||
        draftImages.isNotEmpty ||
        draftFiles.isNotEmpty) {
      _drafts[_keyOf(currentChatId)] = (
        text: draft.value.copyWith(composing: TextRange.empty),
        images: [...draftImages],
        files: [...draftFiles],
      );
    }
    final next = _drafts.remove(_keyOf(chatId));
    draftImages
      ..clear()
      ..addAll(next?.images ?? const []);
    draftFiles
      ..clear()
      ..addAll(next?.files ?? const []);
    currentChatId = chatId;
    draft.value = next?.text ?? TextEditingValue.empty;
  }

  /// [key]'s draft, in view or put away.
  _Draft _draftAt(String key) => key == _keyOf(currentChatId)
      ? (text: draft.value, images: draftImages, files: draftFiles)
      : _drafts[key] ??
            (text: TextEditingValue.empty, images: const [], files: const []);

  /// [_draftAt]'s other half.
  void _setDraftAt(String key, _Draft to) {
    // Copied first: [to] may hold the lists in view.
    final images = [...to.images];
    final files = [...to.files];
    if (key == _keyOf(currentChatId)) {
      draftImages
        ..clear()
        ..addAll(images);
      draftFiles
        ..clear()
        ..addAll(files);
      draft.value = to.text;
    } else if (to.text.text.isEmpty && images.isEmpty && files.isEmpty) {
      _drafts.remove(key);
    } else {
      _drafts[key] = (text: to.text, images: images, files: files);
    }
    notifyListeners();
  }

  /// The drafts are kept by the main instance and synced (§9.3). Each
  /// draft's content as last saved or loaded, by key, so a save sends only
  /// what changed; and its `updatedAt`, so a draft that comes back with it
  /// is known as this one's own, or one already taken.
  final _savedDrafts = <String, String>{};
  final _draftStamps = <String, DateTime>{};

  /// Until the kept drafts are in, nothing is saved over them.
  var _draftsLoaded = false;
  Timer? _saveSoon;

  /// A kept draft's images still on their way to this device, by key: its
  /// saves keep them until they're here.
  final _arriving = <String, List<GaiaDraftImageRecord>>{};

  /// A kept draft's images that never came to this device, by key: not
  /// shown, and their tokens taken out when it's sent, but kept in its
  /// saves, so the device that has them doesn't lose them.
  final _unfetched = <String, List<GaiaDraftImageRecord>>{};

  /// The draft in view's images still syncing from another device, which
  /// the composer shows as placeholders until they're here.
  List<GaiaDraftImageRecord> get arrivingImages =>
      _arriving[_keyOf(currentChatId)] ?? const [];

  /// Whether the draft in view can go now: not while any of its images are
  /// still syncing, which a toast says rather than sending without them.
  /// Ready, it loses the tokens of images that never came, and goes only
  /// if anything's left.
  bool readyToSend() {
    final waiting = arrivingImages;
    if (waiting.isEmpty) {
      for (final lost in _unfetched.remove(_keyOf(currentChatId)) ?? const []) {
        removeDraftImage(lost.label);
      }
      return !draftIsEmpty;
    }
    _toasts.add((
      chatId: '',
      title: 'Images still syncing',
      body:
          '${waiting.map((image) => gaiaImageToken(image.label)).join(', ')} '
          "${waiting.length == 1 ? "hasn't" : "haven't"} arrived from your "
          'other device yet.',
      error: false,
      question: false,
    ));
    return false;
  }

  /// At most a save a second: the controller notifies on every streamed
  /// token too, which would otherwise put it off for a whole reply.
  void _draftsChanged() {
    if (!_draftsLoaded) return;
    _saveSoon ??= Timer(_saveDraftsAfter, () => unawaited(_saveDrafts()));
  }

  /// [key]'s draft as the main instance keeps it, stamped [at].
  GaiaDraft _keptDraft(String key, DateTime at) {
    final held = _draftAt(key);
    final selection = held.text.selection;
    return GaiaDraft(
      id: key,
      text: held.text.text,
      caret: selection.isValid ? selection.extentOffset : -1,
      images: [
        for (final image in held.images)
          if (image.mediaId case final mediaId?)
            GaiaDraftImageRecord(
              mediaId: mediaId,
              label: image.label,
              edits: image.edits.isEmpty ? null : image.edits.toJson(),
            ),
        ...?_arriving[key],
        ...?_unfetched[key],
      ]..sort((a, b) => a.label.compareTo(b.label)),
      files: [...held.files],
      createdAt: at,
      updatedAt: at,
    );
  }

  /// What [_savedDrafts] compares: [kept] less its stamps.
  static String _contentOf(GaiaDraft kept) => jsonEncode({
    'text': kept.text,
    'caret': kept.caret,
    'images': [for (final image in kept.images) image.toJson()],
    'files': [for (final file in kept.files) file.toJson()],
  });

  static final _emptyContent = _contentOf(
    GaiaDraft(id: '', createdAt: DateTime.utc(0), updatedAt: DateTime.utc(0)),
  );

  /// Whether [key]'s draft has changed here since it was saved or loaded.
  bool _unsaved(String key) =>
      _contentOf(_keptDraft(key, DateTime.utc(0))) !=
      (_savedDrafts[key] ?? _emptyContent);

  Future<void> _saveDrafts() async {
    _saveSoon = null;
    final keys = {
      ..._drafts.keys,
      _keyOf(currentChatId),
      ..._savedDrafts.keys,
      ..._arriving.keys,
      ..._unfetched.keys,
    };
    for (final key in keys) {
      if (!_unsaved(key)) continue;
      final kept = _keptDraft(key, utcNow());
      _savedDrafts[key] = _contentOf(kept);
      _draftStamps[key] = kept.updatedAt;
      try {
        await _pipe.request('putDraft', {'draft': kept.toJson()});
      } on GaiaPipeException catch (error) {
        // Tried again with the next change.
        debugPrint('[gaia] draft not saved: $error');
        _savedDrafts.remove(key);
      }
    }
  }

  /// One load at a time, in order: an older list taken after a newer one
  /// would put the drafts back.
  Future<void> _draftsLoading = Future.value();

  Future<void> _loadDrafts() => _draftsLoading = _draftsLoading.then(
    (_) => _loadDraftsNow(),
    onError: (_) => _loadDraftsNow(),
  );

  /// The kept drafts, at start and whenever they change: one another
  /// device saved replaces this one's, unless this one's has changed since
  /// and is about to be saved over it.
  Future<void> _loadDraftsNow() async {
    try {
      final list = (await _pipe.request('drafts'))! as List;
      for (final json in list) {
        var kept = GaiaDraft.fromJson((json as Map).cast<String, Object?>());
        final key = kept.id;
        if (_draftStamps[key] == kept.updatedAt || _unsaved(key)) continue;
        if (kept.deletedAt != null) {
          // Its chat deleted elsewhere while in view: [_refresh] moves what's
          // here to a new chat.
          if (key == _keyOf(currentChatId) && !kept.isEmpty) continue;
          kept = GaiaDraft(
            id: key,
            createdAt: kept.createdAt,
            updatedAt: kept.updatedAt,
          );
        }
        _draftStamps[key] = kept.updatedAt;
        _applyDraft(kept);
        // As it stands here, its caret placed: taking it isn't a change.
        _savedDrafts[key] = _contentOf(_keptDraft(key, kept.updatedAt));
      }
    } on GaiaPipeException catch (error) {
      debugPrint('[gaia] drafts not loaded: $error');
    } finally {
      // Saved over only where something's been typed here since.
      _draftsLoaded = true;
    }
  }

  /// [kept] in place of [kept.id]'s draft. Its images already here stay;
  /// the rest are fetched, and join it as they come.
  void _applyDraft(GaiaDraft kept) {
    final key = kept.id;
    final had = _draftAt(key);
    final images = <GaiaDraftImage>[];
    final arriving = <GaiaDraftImageRecord>[];
    final unfetched = <GaiaDraftImageRecord>[];
    for (final record in kept.images) {
      // Each of its own: the same bytes twice are one media id.
      final same = had.images
          .where(
            (image) =>
                !images.any((taken) => taken.path == image.path) &&
                image.mediaId == record.mediaId &&
                jsonEncode(image.edits.isEmpty ? null : image.edits.toJson()) ==
                    jsonEncode(record.edits),
          )
          .firstOrNull;
      if (same != null) {
        images.add(same.copyWith(label: record.label));
      } else if (_unfetched[key]?.any(
            (lost) => jsonEncode(lost.toJson()) == jsonEncode(record.toJson()),
          ) ??
          false) {
        // Not waited on again.
        unfetched.add(record);
      } else {
        arriving.add(record);
      }
    }
    if (unfetched.isEmpty) {
      _unfetched.remove(key);
    } else {
      _unfetched[key] = unfetched;
    }
    for (final image in had.images) {
      if (images.any((kept) => kept.path == image.path)) continue;
      // Not in any kept draft yet, still being ingested or refused: no
      // other device can have taken it out.
      if (image.mediaId == null) {
        images.add(image);
        continue;
      }
      unawaited(_deleteQuietly(image.path));
      if (image.preview case final preview?) {
        unawaited(_deleteQuietly(preview));
      }
    }
    if (arriving.isEmpty) {
      _arriving.remove(key);
    } else {
      _arriving[key] = arriving;
    }
    final text = kept.text;
    _setDraftAt(key, (
      text: TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(
          offset: kept.caret < 0 || kept.caret > text.length
              ? text.length
              : kept.caret,
        ),
      ),
      images: images,
      files: kept.files,
    ));
    for (final record in arriving) {
      unawaited(_fetchDraftImage(key, record));
    }
  }

  /// A kept draft's image, once it's on this device: copied into a file
  /// of the companion's own, as every draft image is, and into [key]'s
  /// draft. One that doesn't come is let go here, into [_unfetched].
  Future<void> _fetchDraftImage(String key, GaiaDraftImageRecord record) async {
    String? path;
    try {
      path =
          await _pipe.request('draftImageFile', {'mediaId': record.mediaId})
              as String?;
    } on GaiaPipeException catch (error) {
      debugPrint('[gaia] draft image ${record.mediaId} not fetched: $error');
    }
    final waiting = _arriving[key];
    // Replaced by a newer draft meanwhile.
    if (waiting == null || !waiting.remove(record)) return;
    if (waiting.isEmpty) _arriving.remove(key);
    GaiaDraftImage? image;
    if (path != null) {
      final copy = p.join(_draftDirectory, '${_uuid.v4()}.img');
      await Directory(_draftDirectory).create(recursive: true);
      await File(path).copy(copy);
      final edits = GaiaImageEdits.fromJson(record.edits);
      String? preview;
      if (!edits.isEmpty) {
        preview = p.join(_draftDirectory, '${_uuid.v4()}-preview.png');
        await File(
          preview,
        ).writeAsBytes(await gaiaRenderPng(copy, edits: edits));
      }
      image = GaiaDraftImage(
        label: record.label,
        path: copy,
        edits: edits,
        preview: preview,
        mediaId: record.mediaId,
      );
    } else {
      (_unfetched[key] ??= []).add(record);
    }
    final held = _draftAt(key);
    _setDraftAt(key, (
      text: held.text,
      images: [...held.images, ?image],
      files: held.files,
    ));
  }

  /// A draft image the main instance now holds, by its own [path]: named
  /// by its [mediaId] in the kept draft from now on.
  void _ingested(String path, String mediaId) {
    for (final images in [
      draftImages,
      for (final held in _drafts.values) held.images,
    ]) {
      final at = images.indexWhere((image) => image.path == path);
      if (at < 0) continue;
      images[at] = images[at].copyWith(mediaId: mediaId);
      return notifyListeners();
    }
  }

  /// Nothing typed or attached.
  bool get draftIsEmpty =>
      draft.text.trim().isEmpty &&
      draftImages.isEmpty &&
      draftFiles.isEmpty &&
      draftQuotes.isEmpty;

  /// Edit & resend: [message]'s text, files, quotes and window in place of
  /// the draft's. Its images don't come back, so their tokens come out; an
  /// earlier message's it names stay.
  void editMessage(GaiaMessage message) {
    for (final image in draftImages) {
      unawaited(_deleteQuietly(image.path));
      if (image.preview case final preview?) {
        unawaited(_deleteQuietly(preview));
      }
    }
    draftImages.clear();
    var text = message.text;
    for (final image in message.parts.whereType<GaiaImagePart>()) {
      final token = gaiaImageToken(image.label);
      text = text.replaceAll(' $token', '').replaceAll(token, '');
    }
    text = text.trim();
    draftFiles
      ..clear()
      ..addAll(message.parts.whereType<GaiaFilePart>());
    draftQuotes
      ..clear()
      ..addAll(message.parts.whereType<GaiaQuotePart>());
    windowContext = message.parts.whereType<GaiaContextPart>().firstOrNull;
    draft.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    notifyListeners();
  }

  /// The text selected where Gaia was last summoned from, for `$SELECTION`
  /// (§9.2).
  var _summonSelection = '';

  /// Each sent image's local file, by media id, as the main instance says.
  final _imageFiles = <String, Future<String?>>{};

  /// A sent message's images still being attached, by the stand-in media
  /// id its message shows them under until they are.
  final uploadingImages = <String>{};

  /// The [_imageFiles] the main instance said aren't here, to ask again.
  final _missingImages = <String>{};

  /// Captions being written, by message id ([_caption]).
  final _captioning = <String, Future<void>>{};

  /// Images whose captioning failed, by media id: not tried again until
  /// Gaia restarts, so a broken utility model holds up one handoff, not
  /// every one.
  final _captionFailed = <String>{};

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

  /// Gaia opened by [onHotkey]: the composer takes the focus, to type
  /// straight away.
  Stream<void> get summoned => _summoned.stream;
  final _summoned = StreamController<void>.broadcast();

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

  /// The cards tool calls are waiting on, in every chat (§10).
  final cards = GaiaCards();

  /// The options picked on each open question card, by card id.
  final _cardPicks = <String, Set<int>>{};

  /// The card the composer answers (§10.1): an open card on the current
  /// chat's latest reply that a tool call is waiting on, or an open
  /// question whose wait ran out, which is answered as the next message.
  /// Null for none.
  GaiaCardPart? get openCard {
    final last = messages.lastOrNull;
    if (last == null || last.role != GaiaMessageRole.assistant) return null;
    return last.parts.reversed
        .whereType<GaiaCardPart>()
        .where(
          (card) =>
              card.isOpen &&
              (cards.isWaiting(card.id) || card.kind == GaiaCardKind.question),
        )
        .firstOrNull;
  }

  Set<int> cardPicks(String cardId) => _cardPicks[cardId] ?? const {};

  /// Picks option [index] of question [card], or unpicks it: one of several
  /// on a multi-select card, the only one otherwise.
  void pickCardOption(GaiaCardPart card, int index) {
    if (!card.isOpen || index < 0 || index >= card.options.length) return;
    final picks = _cardPicks[card.id] ??= {};
    if (picks.contains(index)) {
      picks.remove(index);
    } else {
      if (!card.multiSelect) picks.clear();
      picks.add(index);
    }
    notifyListeners();
  }

  /// Answers question [card] with its picked options and [text]. Its tool
  /// call gets them; one no longer waiting gets them as the next message,
  /// and the card is marked answered. False when there's nothing to send.
  Future<bool> answerCard(GaiaCardPart card, {String text = ''}) async {
    final selected = [
      for (final index in cardPicks(card.id).toList()..sort())
        card.options[index].label,
    ];
    if (selected.isEmpty && text.trim().isEmpty) return false;
    final answer = {'selected': selected, 'text': text.trim()};
    if (cards.decide(card.id, GaiaCardState.accepted, answer)) {
      _cardPicks.remove(card.id);
      notifyListeners();
      return true;
    }
    // What send would give back: the card stays open, its picks kept.
    if (aborted || draining != null || currentRunning) return false;
    _cardPicks.remove(card.id);
    await _decideStored(card.decided(GaiaCardState.accepted, answer));
    await send(
      [
        'Re: ${card.question}',
        if (selected.isNotEmpty) selected.join(', '),
        if (text.trim().isNotEmpty) text.trim(),
      ].join('\n'),
    );
    return true;
  }

  /// Turns [card] down: a question dismissed, a permission denied with
  /// [message] saying why, if the user said, or a proposal turned down with
  /// [message] as the correction the agent re-proposes with (§10).
  void rejectCard(GaiaCardPart card, {String message = ''}) {
    _cardPicks.remove(card.id);
    final answer = {if (message.trim().isNotEmpty) 'message': message.trim()};
    // A question whose wait ran out has no call to tell: just its message.
    if (!cards.decide(card.id, GaiaCardState.rejected, answer) &&
        card.kind == GaiaCardKind.question) {
      unawaited(_decideStored(card.decided(GaiaCardState.rejected, answer)));
    }
    notifyListeners();
  }

  /// Allows the call permission [card] asks about.
  void allowCard(GaiaCardPart card) {
    cards.decide(card.id, GaiaCardState.accepted);
    notifyListeners();
  }

  /// The user's edits to each open proposal card's fields, by card id.
  final _proposalEdits = <String, Map<String, Object?>>{};

  /// What proposal [card]'s editor holds: the proposed fields, as the user
  /// has edited them.
  Map<String, Object?> proposalFields(GaiaCardPart card) =>
      _proposalEdits[card.id] ?? card.proposal!.fields;

  /// Sets field [key] of proposal [card]'s editor to [value].
  void editProposal(GaiaCardPart card, String key, Object? value) {
    if (!card.isOpen || !cards.isWaiting(card.id)) return;
    // A text field's listener fires on caret moves too.
    if (proposalFields(card)[key] == value) return;
    _proposalEdits[card.id] = {...proposalFields(card), key: value};
    notifyListeners();
  }

  /// Accepts proposal [card] with what its editor holds, issuing the
  /// approval token its commit needs (§10). False when the fields can't be
  /// committed as they are, or nothing waits on it.
  bool acceptProposal(GaiaCardPart card) {
    final fields = proposalFields(card);
    if (gaiaProposalProblem(card.proposal!, fields) != null) return false;
    if (!cards.decide(card.id, GaiaCardState.accepted, {
      'fields': fields,
      'token': gaiaApprovalToken(),
    })) {
      return false;
    }
    _proposalEdits.remove(card.id);
    notifyListeners();
    return true;
  }

  /// The proposal cards on the current chat's latest reply still waiting
  /// on the user, in the order they came: several in one turn stack (§10).
  List<GaiaCardPart> get openProposals {
    final last = messages.lastOrNull;
    if (last == null || last.role != GaiaMessageRole.assistant) return const [];
    return [
      for (final card in last.parts.whereType<GaiaCardPart>())
        if (card.kind == GaiaCardKind.proposal &&
            card.isOpen &&
            cards.isWaiting(card.id))
          card,
    ];
  }

  /// Accepts every open proposal that can be committed as it stands; the
  /// rest stay open. How many were accepted.
  int acceptAllProposals() {
    var accepted = 0;
    for (final card in openProposals) {
      if (acceptProposal(card)) accepted++;
    }
    return accepted;
  }

  /// [card] decided with no tool call waiting: written to its message.
  Future<void> _decideStored(GaiaCardPart card) async {
    for (final list in _messages.values) {
      for (final message in list) {
        if (!message.parts.any((p) => p is GaiaCardPart && p.id == card.id)) {
          continue;
        }
        await _persist(
          _replace(
            message,
            message.copyWith(
              parts: [
                for (final part in message.parts)
                  part is GaiaCardPart && part.id == card.id ? card : part,
              ],
            ),
          ),
        );
        return;
      }
    }
  }

  Future<void> start() async {
    await _window.init();
    void applyCapturable() => _window.setCapturable(debug.allowScreenshots);
    applyCapturable();
    debug.addListener(applyCapturable);
    draft.addListener(_draftsChanged);
    addListener(_draftsChanged);
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
    await _loadDrafts();
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
      case 'summon':
        // Never sent from Gaia itself: whether it was hidden, behind, or
        // the pick-up pill, the user was last in the summoning app.
        _window.returnTo = params['returnTo']! as int;
      case 'hotkey':
        unawaited(
          onHotkey(
            params['key']! as String,
            pressed: params['pressed'] == true,
          ),
        );
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
      case 'drafts':
        unawaited(_loadDrafts());
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
    final saved = [
      for (final chat in list)
        GaiaChat.fromJson((chat as Map).cast<String, Object?>()),
    ];
    // A new chat isn't saved until its first message's images are attached.
    chats = [
      for (final chat in chats)
        if (_running.contains(chat.id) && !saved.any((c) => c.id == chat.id))
          chat,
      ...saved,
    ];
    final current = currentChatId;
    if (current != null &&
        !_running.contains(current) &&
        !chats.any((chat) => chat.id == current)) {
      _viewChat(null);
      // What was typed in it goes to a new chat, as a failed new chat's does.
      if (_drafts.remove(current) case final typed?) {
        _giveBack(null, typed.text.text, typed.images, typed.files);
      }
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
    _window.hide(between: true);
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

  /// The hotkey table in §15.1. [pressed] is the hotkey itself, not the
  /// tray or a button opening the window.
  Future<void> onHotkey(String key, {bool pressed = false}) async {
    // Mid-crop, any of them cancels it.
    if (cropping != null) return finishCrop(null);
    _dropPickUp();
    final shown = _window.shown;
    // Pressed again, a floater closes rather than going back to the Gaia
    // window it was opened over, which the next press would turn back into
    // the floater.
    if (key == shown?.name) _returnTo = null;
    switch (key) {
      case 'small':
        if (shown == GaiaMode.small) return dismiss();
        _returnTo = shown == GaiaMode.window ? GaiaMode.window : _returnTo;
        await _show(GaiaMode.small);
      case 'large':
        if (shown == GaiaMode.large) return dismiss();
        _returnTo = shown == GaiaMode.window ? GaiaMode.window : _returnTo;
        await _show(GaiaMode.large);
      case 'window':
        // Up but behind another app, it's brought to the front instead.
        if (pressed && shown == GaiaMode.window && _window.foreground) {
          return dismiss();
        }
        await openWindow();
    }
    _summoned.add(null);
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
    // Not in the Gaia window when the floater came up, or gone to another
    // app since, the user gets that app back, with the window behind it.
    if (back != null && _window.shown != back) {
      return _show(back, behind: _window.away);
    }
    _window.hide();
    onScreen.value = false;
  }

  Future<void> _show(GaiaMode mode, {bool behind = false}) {
    if (currentChatId == null && !debug.dummyMode) _utility?.warm();
    onScreen.value = true;
    return _window.show(mode, () {
      layout = mode;
      notifyListeners();
    }, behind: behind);
  }

  void newChat() {
    _viewChat(null);
    pickedTier = null;
    if (!debug.dummyMode) _utility?.warm();
    notifyListeners();
  }

  /// [newChat], the draft in view going with it: after the new chat's own
  /// draft, its images numbered on from that one's. Not while any of its
  /// images are still syncing, which a toast says.
  void moveDraftToNewChat() {
    final from = _keyOf(currentChatId);
    if (from == GaiaDraft.newChatId) return newChat();
    // Its tokens out for images that never came, a toast for ones coming.
    if (!readyToSend()) {
      if (arrivingImages.isEmpty) newChat();
      return;
    }
    final moving = (
      text: draft.text,
      images: [...draftImages],
      files: [...draftFiles],
    );
    // Emptied, not deleted: the images are the new chat's now.
    draftImages.clear();
    draftFiles.clear();
    draft.clear();
    newChat();
    final (text, images) = gaiaRelabelDraft(
      moving.text,
      moving.images,
      _nextDraftLabel(),
    );
    final joined = [
      if (draft.text.trim().isNotEmpty) draft.text.trimRight(),
      if (text.trim().isNotEmpty) text.trim(),
    ].join('\n\n');
    draft.value = TextEditingValue(
      text: joined,
      selection: TextSelection.collapsed(offset: joined.length),
    );
    draftImages.addAll(images);
    for (final file in moving.files) {
      if (draftFiles.any((held) => p.equals(held.path, file.path))) continue;
      draftFiles.add(file);
    }
    notifyListeners();
  }

  Future<void> selectChat(String chatId) async {
    if (chatId != currentChatId) pickedTier = null;
    _viewChat(chatId);
    notifyListeners();
    if (_messages.containsKey(chatId)) return;
    await _load(chatId);
  }

  /// The user's own name for [chatId], which the utility model's title
  /// then leaves alone.
  Future<void> renameChat(String chatId, String title) async {
    final from = _chat(chatId)?.title;
    if (from == null || title.isEmpty || title == from) return;
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

  /// Takes [chatId] off the list at once and deletes it in the main
  /// instance. Returns what [restoreChat] needs to undo it: when its images
  /// were taken off with it. Throws [GaiaPipeException] when it wasn't
  /// deleted, the list as it was again.
  Future<String?> deleteChat(String chatId) async {
    chats = [
      for (final c in chats)
        if (c.id != chatId) c,
    ];
    _messages.remove(chatId);
    if (currentChatId == chatId) {
      newChat();
    } else {
      notifyListeners();
    }
    try {
      final result = await _pipe.request('deleteChat', {'chatId': chatId});
      return (result as Map?)?['mediaDeletedAt'] as String?;
    } on GaiaPipeException catch (error) {
      debugPrint('[gaia] chat not deleted: $error');
      await _refresh();
      rethrow;
    }
  }

  /// With [open], as it was when deleted: the chat in view again, once
  /// it's back.
  Future<void> restoreChat(
    String chatId,
    String? mediaDeletedAt, {
    bool open = false,
  }) async {
    await _request('restoreChat', {
      'chatId': chatId,
      'mediaDeletedAt': mediaDeletedAt,
    });
    await _refresh();
    if (open && _chat(chatId) != null) await selectChat(chatId);
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

  /// Runs a built-in command (§9.2). `/new` takes what's left of the draft
  /// with it.
  Future<void> runBuiltin(GaiaBuiltin builtin) async {
    switch (builtin) {
      case GaiaBuiltin.newChat:
        moveDraftToNewChat();
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

  /// Sends [text] with [images] (§9.3), which this send now owns, and
  /// [files].
  Future<void> send(
    String text, {
    List<GaiaDraftImage> images = const [],
    List<GaiaFilePart> files = const [],
  }) async {
    if (gaiaBuiltinIn(text) case final builtin?) return runBuiltin(builtin);
    var prompt = (await _expand(text.trim())).trim();
    if (prompt.isEmpty &&
        images.isEmpty &&
        files.isEmpty &&
        draftQuotes.isEmpty) {
      return;
    }
    // A chat sent to before its messages came: they're numbered on from.
    if (currentChatId case final id?
        when !_messages.containsKey(id) && !_running.contains(id)) {
      await _load(id);
    }
    if (aborted || draining != null || currentRunning) {
      return _giveBack(currentChatId, text, images, files);
    }
    var chat = currentChat;
    final isNew = chat == null;
    // Claimed now, so a second send can't start while this one's images
    // upload or its tier is picked.
    final chatId = chat?.id ?? _uuid.v4();
    _running.add(chatId);
    // Numbered on from the chat's images, so no two of its messages have
    // the same [image N].
    final (relabeled, labeled) = gaiaRelabelDraft(
      prompt,
      images,
      gaiaNextImageLabel(_messages[chatId] ?? const []),
    );
    prompt = relabeled;
    // What the router and the title go by: a files-only message's names, a
    // quote-only one's first quote.
    final topic = prompt.isNotEmpty
        ? prompt
        : files.isNotEmpty
        ? files.map((file) => p.basename(file.path)).join(', ')
        : draftQuotes.first.text;
    // The summon's window goes with this message only.
    final context = windowContext;
    windowContext = null;
    final quotes = [...draftQuotes];
    draftQuotes.clear();
    final sentAt = utcNow();
    if (chat == null) {
      // No utility model yet: the title is the first line (§5.1). Its
      // images' tokens are in it; its files aren't.
      final firstLine = prompt.isNotEmpty
          ? prompt.split('\n').first
          : files.isNotEmpty
          ? p.basename(files.first.path)
          : quotes.first.text.trim().split('\n').first;
      chat = GaiaChat(
        id: chatId,
        title: firstLine.length > 60
            ? '${firstLine.substring(0, 60)}…'
            : firstLine,
        createdAt: sentAt,
        updatedAt: sentAt,
        lastMessageAt: sentAt,
        tier: nextTier,
      );
      chats = [chat, ...chats];
      currentChatId = chatId;
    }
    final list = _messages[chatId] ??= [];
    // Shown at once, its images from the draft's own files while they're
    // attached; saved only once they are.
    final uploading = [for (final _ in labeled) 'uploading-${_uuid.v4()}'];
    for (final (i, image) in labeled.indexed) {
      _imageFiles[uploading[i]] = Future.value(image.preview ?? image.path);
    }
    uploadingImages.addAll(uploading);
    var question = GaiaMessage(
      id: _uuid.v4(),
      chatId: chatId,
      seq: list.isEmpty ? 0 : list.last.seq + 1,
      role: GaiaMessageRole.user,
      parts: [
        GaiaTextPart(prompt),
        for (final (i, image) in labeled.indexed)
          GaiaImagePart(
            mediaId: uploading[i],
            label: image.label,
            width: 0,
            height: 0,
          ),
        ...files,
        ...quotes,
        ?context,
      ],
      status: GaiaMessageStatus.complete,
      createdAt: sentAt,
      updatedAt: sentAt,
    );
    list.add(question);
    notifyListeners();
    final imageParts = <GaiaImagePart>[];
    final imageInputs = <GaiaImageInput>[];
    final referenceIds = <String>[];
    final uploads = <String>[];

    // The send didn't happen: the question comes off the chat, and a new
    // chat with it, and it all goes back in the draft.
    void undo() {
      for (final referenceId in referenceIds) {
        unawaited(_request('detachImage', {'referenceId': referenceId}));
      }
      uploadingImages.removeAll(uploading);
      uploading.forEach(_imageFiles.remove);
      list.removeWhere((message) => message.id == question.id);
      _running.remove(chatId);
      if (isNew) {
        chats = [
          for (final c in chats)
            if (c.id != chatId) c,
        ];
        _messages.remove(chatId);
        if (currentChatId == chatId) _viewChat(null);
        // What was typed in it since goes back to a new chat with the rest.
        if (_drafts.remove(chatId) case final typed?) {
          _giveBack(null, typed.text.text, typed.images, typed.files);
        }
      }
      windowContext = context;
      // Less any attached again meanwhile.
      draftQuotes.insertAll(0, [
        for (final quote in quotes)
          if (!draftQuotes.any(
            (q) => q.role == quote.role && q.text == quote.text,
          ))
            quote,
      ]);
      _giveBack(isNew ? null : chatId, text, images, files);
      _reportRuns();
      _settleDrain();
    }

    // Before anything is saved: an image that can't be attached stops the
    // send.
    for (final image in labeled) {
      try {
        if (debug.attachDelay > Duration.zero) {
          await Future<void>.delayed(debug.attachDelay);
        }
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
        _toasts.add((
          chatId: '',
          title: "Couldn't attach ${gaiaImageToken(image.label)}",
          body: error is GaiaPipeException ? error.message : '$error',
          error: true,
          question: false,
        ));
        return undo();
      }
    }
    uploads.forEach(_deleteQuietly);
    if (labeled.isNotEmpty) {
      uploadingImages.removeAll(uploading);
      // A lightbox opened on one while it uploaded still asks by it.
      for (final (i, image) in imageParts.indexed) {
        _imageFiles[uploading[i]] = _imageFiles[image.mediaId]!;
      }
      question = _replace(
        question,
        question.copyWith(
          parts: [
            GaiaTextPart(prompt),
            ...imageParts,
            ...files,
            ...quotes,
            ?context,
          ],
          bumpVersion: false,
          touch: false,
        ),
      );
    }
    var tier = nextTier;
    // The router picks only a new chat's first tier, and never over the
    // user's own pick (§7.2).
    if (isNew && pickedTier == null && !debug.dummyMode) {
      if (_utility == null) debugPrint('[gaia] router: no utility model');
      tier = await _utility?.route(topic) ?? tier;
    } else {
      debugPrint(
        '[gaia] router: skipped, '
        '${debug.dummyMode
            ? 'dummy mode'
            : !isNew
            ? 'not a new chat'
            : 'tier picked: ${pickedTier!.name}'}',
      );
    }
    debugPrint('[gaia] router: sending on ${tier.name}');
    // Aborted, or the drain cancelled, while its images uploaded or its tier
    // was picked: no run starts.
    if (aborted || _drainCancelled) return undo();
    // After the router, so the reply's orb doesn't count it as bloom time.
    final now = utcNow();
    pickedTier = null;
    final agent = agentFor(tier);
    // Saved stamped with the reply, as it always was: a message later than
    // its chat's last has the main instance write the chat again, which
    // can land over this run's session.
    question = _replace(
      question,
      GaiaMessage(
        id: question.id,
        chatId: chatId,
        seq: question.seq,
        role: GaiaMessageRole.user,
        parts: question.parts,
        status: GaiaMessageStatus.complete,
        createdAt: now,
        updatedAt: now,
      ),
    );
    if (isNew) {
      // As it's listed now, so a rename while it was unsaved is kept.
      chat = (_chat(chatId) ?? chat).copyWith(tier: tier, lastMessageAt: now);
      chats = [for (final c in chats) c.id == chatId ? chat : c];
      try {
        await _pipe.request('putChat', {'chat': chat.toJson()});
      } on GaiaPipeException catch (error) {
        // The main instance is going away: no run whose chat can't be kept.
        debugPrint('[gaia] chat not saved, not sending: $error');
        _toasts.add((
          chatId: '',
          title: "Couldn't start the chat",
          body: error.message,
          error: true,
          question: false,
        ));
        return undo();
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
    final script = debug.scriptFor(prompt);
    final runner = agent == null ? null : _runners[agent.adapter];
    var reply = GaiaMessage(
      id: _uuid.v4(),
      chatId: chatId,
      seq: question.seq + 1,
      role: GaiaMessageRole.assistant,
      parts: const [],
      status: GaiaMessageStatus.streaming,
      createdAt: now,
      updatedAt: now,
      model: script == null ? agent?.model : 'gaia-debug-script',
      adapter: script == null ? agent?.adapter : null,
    );
    list.add(reply);
    _moveToTop(chatId, now);
    _reportRuns();
    notifyListeners();
    unawaited(_persist(question));
    unawaited(_persist(reply));
    // Ready for a later handoff; this turn's agent sees the images.
    if (script == null) unawaited(_caption([question]));

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
    // The window it was asked from goes ahead of it (§15.4), and the
    // messages attached to it (§9.3).
    // Its files' paths after it (§9.3).
    final asked = [
      ?context?.preamble,
      for (final quote in quotes) quote.preamble,
      // Empty when only files were sent.
      if (prompt.isNotEmpty) prompt,
      if (files.isNotEmpty) gaiaFilesPreamble(files),
    ].join('\n\n');
    Future<String> handedOver() async {
      if (script != null || agent == null || runner == null) return asked;
      List<GaiaMessage> unseen() => gaiaUnseenTurns(
        _messages[chatId] ?? list,
        lastSeq: session?.lastSeq ?? -1,
        beforeSeq: question.seq,
      );
      final captioning = unseen();
      if (captioning.isEmpty) return asked;
      // Images go as captions and files (§7.4): the captions first, for a
      // while, read back from the messages they were written to.
      await _caption(captioning).timeout(_captionWait, onTimeout: () {});
      final turns = unseen();
      final (older, recent) = gaiaSplitHandoff(turns);
      final summary = older.isEmpty
          ? null
          : await _utility?.summarize(gaiaTranscriptText(older));
      final ids = {
        for (final message in turns)
          for (final image in message.parts.whereType<GaiaImagePart>())
            image.mediaId,
      };
      final paths = await Future.wait(ids.map(imageFile));
      final imagePaths = Map.fromIterables(ids, paths);
      return '${gaiaHandoffPreamble(recent: recent, joining: session == null, summary: summary, omitted: summary == null ? older.length : 0, labels: {for (final a in agents) a.model: a.label}, older: older, files: imagePaths)}\n$asked';
    }

    final sent = await handedOver();
    // Where every file the chat has attached is, not just this message's:
    // the agent may go back to one. Those from another device aren't here.
    // Checked off the UI thread: an offline drive can take seconds to say.
    final directories = {
      for (final directory in {
        for (final message in _messages[chatId] ?? list)
          for (final file in message.parts.whereType<GaiaFilePart>())
            file.folder ? file.path : p.dirname(file.path),
      })
        if (await Directory(directory).exists()) directory,
    };
    var retried = false;
    String failed(Object error) => retried
        ? "This chat's earlier session wasn't found, and starting a new one "
              'failed too: $error'
        : '$error';
    final configDir = _claudeConfigDir;
    // Set once the reply is settled: a card voided as its run ends comes
    // too late to change it.
    var ended = false;
    void onEvent(GaiaAgentEvent event) {
      if (ended) return;
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
      // A card at once: it's what the Gaia page and other devices wait on.
      if (event is GaiaCardUpdate ||
          last == null ||
          DateTime.now().difference(last) > _persistEvery) {
        unawaited(_persist(reply));
      }
      if (event case GaiaCardUpdate(:final card) when card.isOpen) {
        _reportCard(chatId, card);
      }
    }

    // Gaia's tools for this turn (§5.3): cards in this reply, reads from
    // the main instance.
    final tools = GaiaChatTools(
      chatId: chatId,
      cards: cards,
      onCard: (card) => onEvent(GaiaCardUpdate(card)),
      read: (tool, arguments) async {
        try {
          return await _pipe.request('voyagerRead', {
                'tool': tool,
                'arguments': arguments,
              })
              as String;
        } on GaiaPipeException catch (error) {
          throw GaiaToolException(error.message);
        }
      },
      proposals: (
        prepare: (cardId, tool, arguments) async {
          try {
            return GaiaProposal.fromJson(
              ((await _pipe.request('prepareProposal', {
                        'cardId': cardId,
                        'tool': tool,
                        'arguments': arguments,
                      }))!
                      as Map)
                  .cast<String, Object?>(),
            );
          } on GaiaPipeException catch (error) {
            throw GaiaToolException(error.message);
          }
        },
        commit: (cardId, token, fields) async {
          try {
            final committed =
                (await _pipe.request('commitProposal', {
                          'cardId': cardId,
                          'token': token,
                          'fields': fields,
                        })
                        as Map)
                    .cast<String, Object?>();
            return (
              record: (committed['record']! as Map).cast<String, Object?>(),
              text: committed['text']! as String,
            );
          } on GaiaPipeException catch (error) {
            throw GaiaToolException(error.message);
          }
        },
        drop: (cardId) {
          _proposalEdits.remove(cardId);
          if (_pipe.connected) {
            unawaited(
              _pipe
                  .request('dropProposal', {'cardId': cardId})
                  .catchError((_) => null),
            );
          }
        },
      ),
      aborted: () => aborted,
      hold: _cardHold,
    );

    try {
      var result = script != null
          ? await _scripted.send(
              chatId: chatId,
              script: script,
              replyDelay: debug.replyDelay,
              streamSpeed: debug.streamSpeed,
              onEvent: onEvent,
              tools: tools,
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
              directories: directories,
              tools: tools,
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
          directories: directories,
          tools: tools,
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
      ended = true;
      // A turn can end with a call still held: Codex stops waiting on a
      // tool after about 30 s. Nothing is left to take a proposal's or a
      // permission's answer, so they're voided; a question stays open and,
      // answered later, goes as the next message.
      cards.voidAll(chatId: chatId);
      final parts = [
        for (final part in builder.finished)
          part is GaiaCardPart &&
                  part.isOpen &&
                  part.kind != GaiaCardKind.question
              ? part.decided(GaiaCardState.voided)
              : part,
      ];
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
                // Or a question card left open, its wait run out.
                needsInput:
                    gaiaEndsWithQuestion(
                      parts.whereType<GaiaTextPart>().lastOrNull?.text ?? '',
                    ) ||
                    parts.any(
                      (part) =>
                          part is GaiaCardPart &&
                          part.isOpen &&
                          part.kind == GaiaCardKind.question,
                    ),
              ),
      );
    } catch (error) {
      final stopped = _stopping.contains(chatId);
      // Its open cards go with it: nothing is left to answer them.
      ended = true;
      cards.voidAll(chatId: chatId);
      reply = _replace(
        reply,
        reply.copyWith(
          parts: [
            for (final part in builder.finished)
              part is GaiaCardPart && part.isOpen
                  ? part.decided(GaiaCardState.voided)
                  : part,
          ],
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
    if (reply.seq == 1 &&
        reply.status == GaiaMessageStatus.complete &&
        !debug.dummyMode) {
      unawaited(_retitle(chatId, topic, reply.text));
    }
    _settleDrain();
  }

  /// A send that didn't happen: its [text] and [images] go back in
  /// [chatId]'s draft, the text unless the user has typed again.
  void _giveBack(
    String? chatId,
    String text,
    List<GaiaDraftImage> images,
    List<GaiaFilePart> files,
  ) {
    if (chatId != currentChatId) {
      final had = _drafts[_keyOf(chatId)];
      final hadFiles = had?.files ?? const <GaiaFilePart>[];
      _drafts[_keyOf(chatId)] = (
        text: had == null || had.text.text.isEmpty
            ? TextEditingValue(text: text)
            : had.text,
        images: [...?had?.images, ...images],
        files: [
          ...hadFiles,
          for (final file in files)
            if (!hadFiles.any((had) => p.equals(had.path, file.path))) file,
        ],
      );
      return notifyListeners();
    }
    if (draft.text.isEmpty) draft.text = text;
    draftImages.addAll(images);
    // One attached again meanwhile is still one.
    draftFiles.addAll(
      files.where(
        (file) => !draftFiles.any((had) => p.equals(had.path, file.path)),
      ),
    );
    notifyListeners();
  }

  Future<void> stop(String chatId) async {
    if (!_running.contains(chatId)) return;
    _stopping.add(chatId);
    cards.voidAll(chatId: chatId);
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
    if (_window.foreground && chatId == currentChatId) return;
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
    _toast(
      chatId,
      title,
      body,
      error: reply.status == GaiaMessageStatus.error,
      question: reply.needsInput,
    );
  }

  /// A card raised while its chat isn't in view raises a toast as a
  /// finished run does (§14).
  void _reportCard(String chatId, GaiaCardPart card) {
    if (!_notifyOnDone || draining != null) return;
    if (_window.foreground && chatId == currentChatId) return;
    final String title;
    final String body;
    switch (card.kind) {
      case GaiaCardKind.question:
        title = 'Gaia has a question';
        body = card.question;
      case GaiaCardKind.permission:
        title = 'Gaia needs your permission';
        body = card.description.isNotEmpty ? card.description : card.tool;
      case GaiaCardKind.proposal:
        title = 'Gaia has something to save';
        body = gaiaProposalTitle(card.proposal!, card.proposal!.fields);
    }
    _toast(
      chatId,
      title,
      body.length > 120 ? '${body.substring(0, 120)}…' : body,
      question: true,
    );
  }

  /// In front, or floating, Gaia's own toast; otherwise a Windows one.
  void _toast(
    String chatId,
    String title,
    String body, {
    bool error = false,
    bool question = false,
  }) {
    final front = _window.foreground;
    final floating =
        _window.shown == GaiaMode.small || _window.shown == GaiaMode.large;
    final chatTitle = _chat(chatId)?.title ?? '';
    final toast = (
      chatId: chatId,
      title: title,
      body: chatTitle.isEmpty ? body : '$chatTitle: $body',
      error: error,
      question: question,
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
    // Their tool calls refuse, and the cards show voided (§15.7).
    cards.voidAll();
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

  /// Captions [messages]' images that have none (§7.4), a few at a time,
  /// and saves each message they're written to. A message already being
  /// captioned is waited on, not done again; an image that failed isn't
  /// tried again ([_captionFailed]).
  Future<void> _caption(List<GaiaMessage> messages) async {
    final utility = _utility;
    if (utility == null) return;
    final pending = [
      for (final message in messages)
        if (message.parts.any(
          (p) =>
              p is GaiaImagePart &&
              p.caption == null &&
              !_captionFailed.contains(p.mediaId),
        ))
          message,
    ];
    for (var i = 0; i < pending.length; i += _captionsAtOnce) {
      await Future.wait([
        for (final message in pending.skip(i).take(_captionsAtOnce))
          _captioning[message.id] ??= _captionOne(
            utility,
            message,
          ).whenComplete(() => _captioning.remove(message.id)),
      ]);
    }
  }

  Future<void> _captionOne(GaiaUtility utility, GaiaMessage message) async {
    final captions = <int, String>{};
    for (final image in message.parts.whereType<GaiaImagePart>()) {
      if (image.caption != null || _captionFailed.contains(image.mediaId)) {
        continue;
      }
      final path = await imageFile(image.mediaId);
      if (path == null) continue;
      final format = MediaImageFormat.fromPath(path);
      final caption = await utility.caption((
        label: image.label,
        path: path,
        mimeType: (format ?? MediaImageFormat.jpeg).mimeType,
      ));
      if (caption == null) {
        _captionFailed.add(image.mediaId);
      } else {
        captions[image.label] = caption;
      }
    }
    final current = _messages[message.chatId]
        ?.where((m) => m.id == message.id)
        .firstOrNull;
    if (captions.isEmpty || current == null) return;
    final updated = _replace(
      current,
      current.copyWith(
        parts: [
          for (final part in current.parts)
            switch (part) {
              GaiaImagePart(:final label) when captions.containsKey(label) =>
                part.withCaption(captions[label]!),
              _ => part,
            },
        ],
      ),
    );
    await _persist(updated);
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
