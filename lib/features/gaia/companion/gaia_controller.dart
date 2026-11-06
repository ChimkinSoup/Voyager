import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart'
    show TextEditingController, TextEditingValue, TextSelection;
import 'package:path/path.dart' as p;
import 'package:super_clipboard/super_clipboard.dart'
    show DataWriterItem, Formats, SystemClipboard;
import 'package:uuid/uuid.dart';
import 'package:voyager/core/sync/connectivity_status.dart';
import 'package:voyager/core/text/merge_aware_undo.dart';
import 'package:voyager/core/utils/ids.dart';
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
import 'package:win32/win32.dart' show AllowSetForegroundWindow;
import 'package:voyager/features/gaia/gaia_text_settings.dart';
import 'package:voyager/features/gaia/tools/gaia_mcp.dart';
import 'package:voyager/features/gaia/tools/gaia_proposals.dart';
import 'package:voyager/features/gaia/usage/gaia_usage.dart';
import 'package:voyager/features/gaia/usage/gaia_usage_limits.dart';
import 'package:voyager/features/gaia/utility/gaia_utility.dart';

const _uuid = Uuid();

/// How often a streaming reply is written through to the main instance. The
/// companion's own view updates on every delta.
const _persistEvery = Duration(seconds: 1);

/// How long a handoff waits for its images' captions before it goes with
/// the files alone; the captions carry on, for the next one.
const _captionWait = Duration(seconds: 20);

/// How long a chat this device ran sits idle before the memory curator
/// reads its new turns (§11).
const kGaiaCurateAfter = Duration(minutes: 10);

/// How far back, at start, the curator looks for chats whose wait a quit
/// cut short (§11): older turns are left unread.
const kGaiaCurateMissedWithin = Duration(days: 7);

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
    Future<void> Function(Uint8List png)? copyPng,
    String? draftDirectory,
    this._reach,
    this._usageSources = const {},
    @visibleForTesting this._usageEvery = const Duration(minutes: 10),
    @visibleForTesting this._runWorkedFor = const Duration(hours: 1),
    @visibleForTesting this._cardHold = kGaiaCardHold,
    @visibleForTesting this._curateAfter = kGaiaCurateAfter,
  }) : _clipboard = clipboard ?? _readClipboard,
       _copyPng = copyPng ?? _writeClipboardPng,
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

  /// Puts a finished crop on the clipboard.
  final Future<void> Function(Uint8List png) _copyPng;

  static Future<void> _writeClipboardPng(Uint8List png) async => SystemClipboard
      .instance
      ?.write([DataWriterItem()..add(Formats.png(png))]);

  /// Where the draft's images wait until they're sent.
  final String _draftDirectory;

  /// How long a card holds its tool call (§10.1).
  final Duration _cardHold;

  /// How long a chat sits idle before the memory curator reads it (§11).
  final Duration _curateAfter;

  /// The composer's text for the chat in view. Here rather than in the
  /// composer, so it outlives a mode change and a capture can add to it
  /// (§15.1).
  final draft = TextEditingController();

  /// [draft]'s undo history. One controller holds every chat's draft, so each
  /// chat's history is swapped in with its draft, or undo would put the last
  /// chat's text in this one.
  late final draftUndo = MergeAwareUndoController(draft);

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
  void _attachFile(String path, {bool capture = false}) {
    final label = _nextDraftLabel();
    draftImages.add(GaiaDraftImage(label: label, path: path));
    _insertInDraft(gaiaImageToken(label));
    notifyListeners();
    unawaited(_ingest(path, capture: capture));
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
  Future<void> _ingest(String path, {required bool capture}) async {
    var upload = path;
    try {
      // A capture is a BMP, which the media module doesn't take.
      if (capture) upload = await gaiaUploadablePath(path);
      final mediaId =
          (await _pipe.request('ingestImage', {'path': upload}))! as String;
      _ingested(path, mediaId);
    } catch (error) {
      debugPrint('[gaia] draft image not kept: $error');
    } finally {
      if (upload != path) unawaited(_deleteQuietly(upload));
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

  /// Each capture that brings Gaia up with it, over which no dialog or menu
  /// is left open. Sync, so they're gone before the overlay's first frame.
  Stream<void> get captures => _captures.stream;
  final _captures = StreamController<void>.broadcast(sync: true);

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
    _captures.add(null);
    // Over a crop's overlay, what the window was is still what was before it.
    final overCrop = cropping != null;
    _discardCrop();
    _dropPickUp();
    final shown = overCrop
        ? _beforeCrop
        : _enlargedForEditor
        ? GaiaMode.small
        : _window.shown;
    _enlargedForEditor = false;
    if (params['kind'] == 'screen') {
      _attachFile(await _intoDrafts(path), capture: true);
      return _show(shown ?? GaiaMode.small);
    }
    _beforeCrop = shown;
    if (!overCrop) _cropBehind = shown != null && !_window.foreground;
    cropping = (path: path, frame: frame);
    _pipe.notify('cropping', {'active': true});
    onScreen.value = true;
    await _window.show(GaiaMode.overlay, () {
      layout = GaiaMode.overlay;
      notifyListeners();
    }, frame: cropping!.frame);
  }

  /// The overlay's crop is done: [region], in the capture's pixels, joins
  /// the draft and goes on the clipboard; null cancels. The window goes back
  /// to how it was, and a crop begun from hidden opens the small floater
  /// with it.
  Future<void> finishCrop(Rect? region) async {
    final capture = cropping;
    if (capture == null) return;
    cropping = null;
    _pipe.notify('cropping', {'active': false});
    try {
      if (region != null) {
        // Off screen while it renders, not the chat stretched over the
        // monitor.
        _window.hide(between: true);
        final png = await gaiaRenderPng(capture.path, crop: region);
        await attachImage(png);
        await _copyCrop(png);
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

  /// A clipboard that won't open (another process can hold it) costs the
  /// copy, not the crop: it's in the draft already.
  Future<void> _copyCrop(Uint8List png) async {
    try {
      await _copyPng(png);
    } on Exception catch (error) {
      debugPrint('[gaia] crop not copied: $error');
      _toasts.add((
        chatId: '',
        title: 'Image not copied',
        body: "It's in the draft, but not on the clipboard.",
        error: true,
        question: false,
      ));
    }
  }

  /// A crop left behind by another hotkey: its capture isn't wanted.
  void _discardCrop() {
    final capture = cropping;
    if (capture == null) return;
    cropping = null;
    _pipe.notify('cropping', {'active': false});
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
    _enlargedForEditor = true;
    await _show(GaiaMode.large);
    return true;
  }

  /// Unless a capture has taken the window since: it closed the editor,
  /// and goes back to the small floater itself.
  Future<void> restoreSmall() async {
    if (!_enlargedForEditor) return;
    _enlargedForEditor = false;
    await _show(GaiaMode.small);
  }

  /// Large only for the annotation editor, small underneath.
  var _enlargedForEditor = false;

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
      // A space the insert put beside it goes too: the one before, or at
      // the start, the one after.
      var start = at;
      var end = at + token.length;
      if (at > 0 && text[at - 1] == ' ') {
        start--;
      } else if (end < text.length && text[end] == ' ') {
        end++;
      }
      draft.value = TextEditingValue(
        text: text.replaceRange(start, end, ''),
        selection: TextSelection.collapsed(offset: start),
      );
    }
    // Its undo steps hold the token, of an image that's gone.
    draftUndo.reset();
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
  /// from the text on either side by a space.
  void _insertInDraft(String text) {
    final value = draft.value;
    final at = value.selection.isValid
        ? value.selection.end
        : value.text.length;
    final before = value.text.substring(0, at);
    final after = value.text.substring(at);
    var insert = before.isEmpty || before.trimRight() != before
        ? text
        : ' $text';
    if (after.trimLeft() == after) insert = '$insert ';
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

  /// The control attached with `/this` (§15.5): a chip on the draft, which
  /// the next message takes with it.
  GaiaElementPart? draftControl;

  void dropDraftControl() {
    draftControl = null;
    notifyListeners();
  }

  /// What the last summon pointed at, kept for `/this`: the control and a
  /// crop around it, or why there's nothing to attach.
  GaiaElementPart? _pointed;
  String? _pointedCrop;
  String? _pointedRefused;

  /// Set while the main instance is cropping the last summon's control.
  Completer<void>? _pointedReading;

  void _dropPointed() {
    if (_pointedCrop case final crop?) unawaited(_deleteQuietly(crop));
    _pointed = null;
    _pointedCrop = null;
    _pointedRefused = null;
  }

  void _onPointed(Map<String, Object?> params) {
    _dropPointed();
    if (params['reading'] == true) {
      _pointedReading ??= Completer<void>();
      return;
    }
    _pointedReading?.complete();
    _pointedReading = null;
    _pointed = switch (params['control']) {
      final Map<Object?, Object?> json =>
        GaiaPart.fromJson(json.cast()) as GaiaElementPart,
      _ => null,
    };
    _pointedCrop = params['crop'] as String?;
    _pointedRefused = params['refused'] as String?;
  }

  /// `/this` (§15.5): the summon's control joins the draft as a chip, with
  /// its crop as an image. False, with a toast saying why, when it can't:
  /// aborted (§15.7), a sensitive field, an excluded or unknown app, or Voyager
  /// with its vault unlocked (§15.6), or nothing under the cursor. Used once:
  /// pointing again takes another summon.
  Future<bool> attachThis() async {
    if (_pointedReading case final reading?) {
      // A little past the main instance's own limits on the read and the crop,
      // 8 s each, in case it never says.
      await reading.future.timeout(
        const Duration(seconds: 18),
        onTimeout: () {},
      );
      _pointedReading = null;
    }
    if (aborted) {
      await _onRefused();
      return false;
    }
    final control = _pointed;
    if (control == null) {
      final (title, body) = switch (_pointedRefused) {
        'sensitive' => (
          "Can't attach that control",
          "It's a password, card or one-time code field.",
        ),
        'excluded' => (
          "Can't attach that control",
          "Its app or site is on Gaia's exclusion list.",
        ),
        'unknown' => (
          "Can't attach that control",
          "Gaia can't tell what app or site it's in, so can't check the "
              'exclusion list.',
        ),
        'vault' => (
          "Can't attach that control",
          "Voyager's secure vault is unlocked.",
        ),
        _ => (
          'Nothing to attach',
          'Point at a control, then summon Gaia with its hotkey.',
        ),
      };
      _note(title, body, error: true);
      return false;
    }
    final crop = _pointedCrop;
    _pointed = null;
    _pointedCrop = null;
    draftControl = control;
    notifyListeners();
    if (crop != null) {
      try {
        _attachFile(await _intoDrafts(crop), capture: true);
      } on FileSystemException catch (error) {
        // Swept with the other captures after an hour: the chip still says
        // what it was.
        debugPrint('[gaia] /this crop not attached: $error');
      }
    }
    return true;
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

  /// Each chat's [draftUndo] history while another chat is in view, by
  /// [_keyOf] its chat. For this run of the app only.
  final _draftHistories = <String, SavedUndoHistory>{};

  /// [chatId]'s draft's key, here and in the main instance's store.
  static String _keyOf(String? chatId) => chatId ?? GaiaDraft.newChatId;

  /// A chat, or a new one, has been brought into view this run.
  var _chatViewed = false;

  /// Brings [chatId] into view with its own draft, the one in view put
  /// away for when its chat is back.
  void _viewChat(String? chatId) {
    _chatViewed = true;
    if (chatId == currentChatId) return;
    _newChatSeesScreen = false;
    _newChatCanControl = false;
    seeScreenWarning = false;
    _draftHistories[_keyOf(currentChatId)] = draftUndo.saveHistory();
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
    final history = _draftHistories.remove(_keyOf(chatId));
    history == null ? draftUndo.reset() : draftUndo.restoreHistory(history);
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

  /// At most a save a second: the controller notifies on every card and
  /// tool update of a streaming reply too, which would otherwise put it off
  /// for a whole reply.
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
    draftControl = message.parts.whereType<GaiaElementPart>().firstOrNull;
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

  /// Gaia opened by [onHotkey], or [focusComposer]: the composer takes the
  /// focus, to type straight away.
  Stream<void> get summoned => _summoned.stream;
  final _summoned = StreamController<void>.broadcast();

  /// A click somewhere in Gaia: the composer takes the focus back.
  void focusComposer() => _summoned.add(null);

  /// Each CLI's `--version` by adapter, and how the companion ends:
  /// parameters for tests.
  final Map<String, Future<GaiaCliVersion?> Function()> _cliVersions;
  final void Function(int code) _exit;

  var aborted = false;
  var chats = <GaiaChat>[];

  /// Voyager's accent, as ARGB: the theme follows it.
  final accent = ValueNotifier(0xFF7C9EFF);

  /// The composer's share of Voyager's settings: Vim, autocorrect,
  /// snippets and the dictionary (§9.5).
  final textSettings = ValueNotifier(GaiaTextSettings.off);

  /// On screen and in front, from the window's focus and blur; the
  /// starfield drifts only then.
  final focused = ValueNotifier(false);

  /// Whether the window is shown at all, in any mode. Off, every ticker
  /// is muted: a hidden window's tree stays alive, and the buttons' glow
  /// rings would otherwise keep asking for frames at the display's rate.
  final onScreen = ValueNotifier(false);

  /// Bumped, instead of notifying, as a reply's text streams in: only the
  /// messages show it, and rebuilding the sidebar and composer for every
  /// chunk made streaming stutter.
  final streamed = ValueNotifier(0);

  /// The main instance's device, whose native sessions this companion runs.
  var _deviceId = '';

  /// Whether a run that finishes while Gaia is hidden raises a toast (§14).
  var _notifyOnDone = true;

  /// The configured agents and which tier points at which (§7.1).
  var agents = kGaiaDefaultAgents;
  var tiers = kGaiaDefaultTiers;

  /// The tier a new chat starts on (§7.2): the default, else the last used.
  var lastTier = GaiaTier.standard;
  GaiaTier? defaultTier;

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

  /// Connects to a host, or throws: [connectivity]'s probe. Null, as in
  /// tests, for no probing at all.
  final Future<void> Function(String host)? _reach;

  /// Whether the next tier's CLI can reach its API, for the header's
  /// offline icon. Probed by the companion itself: the main instance's own
  /// check asks after Firestore, and pauses while Voyager is in the
  /// background, which is where it is whenever Gaia is up.
  ConnectivityStatusController? get connectivity => _connectivity;
  ConnectivityStatusController? _connectivity;
  String? _probedHost;

  /// Starts [connectivity] over whenever the next tier's CLI talks to
  /// another host, so one host's answer never shows under another CLI's
  /// name. Paced by [onScreen]: the companion's app lifecycle doesn't say
  /// whether a window or floater is showing.
  void _followProbedHost() {
    final reach = _reach;
    if (reach == null) return;
    final host = kGaiaClis[agentFor(nextTier)?.adapter]?.apiHost;
    if (host == _probedHost) return;
    _probedHost = host;
    _connectivity?.dispose();
    _connectivity = host == null
        ? null
        : ConnectivityStatusController(
            probe: () => reach(host),
            visible: onScreen,
          );
  }

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

  /// Each running chat's tools for its turn.
  final _turnTools = <String, GaiaChatTools>{};

  /// A send still attaching its images, picking its tier or taking its
  /// lease, by chat: no run to stop yet, so a stop takes the send back.
  final _cancelSend = <String, void Function()>{};
  final _running = <String>{};

  /// A stopped message still being taken back from its session (§9.6), by
  /// chat: run once the chat has stopped, and a send to it waits for it.
  final _takingBack = <String, Future<void>>{};

  /// Chats sent to while [_takingBack]: the stopped message isn't put back
  /// in the draft then.
  final _takeBackSuperseded = <String>{};
  final _lastPersist = <String, DateTime>{};

  /// Chats this device ran a turn in, each curated once it's been idle for
  /// [kGaiaCurateAfter] (§11).
  final _curateSoon = <String, Timer>{};

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
  ///
  /// [remoteChat] is the card's chat when the phone answers it (§12.2):
  /// a late answer goes there, not to the chat in view.
  Future<bool> answerCard(
    GaiaCardPart card, {
    String text = '',
    String? remoteChat,
  }) async {
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
    if (aborted ||
        draining != null ||
        (remoteChat == null ? currentRunning : _running.contains(remoteChat))) {
      return false;
    }
    _cardPicks.remove(card.id);
    await _decideStored(card.decided(GaiaCardState.accepted, answer));
    final reply = [
      'Re: ${card.question}',
      if (selected.isNotEmpty) selected.join(', '),
      if (text.trim().isNotEmpty) text.trim(),
    ].join('\n');
    if (remoteChat == null) {
      await send(reply);
      return true;
    }
    // The phone's command settles once the reply is under way, not when it
    // ends. Not sent, it isn't answered: the card opens again.
    var queued = false;
    final why = await _sendRemote(
      reply,
      chatId: remoteChat,
      onQueued: () => queued = true,
    );
    if (why == null || queued) return true;
    await _decideStored(card);
    throw GaiaPipeException(why);
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

  /// Approves control [card]'s steps (§15.6): all that are left with [once],
  /// otherwise its next one. Gaia is in front to do it, and passes that on, so
  /// the main instance can bring the target window up.
  void approveControl(GaiaCardPart card, {required bool once}) {
    AllowSetForegroundWindow(_anyProcess);
    cards.decide(card.id, GaiaCardState.accepted, {'once': once});
    notifyListeners();
  }

  /// `ASFW_ANY`, which the win32 package has no name for.
  static const _anyProcess = 0xFFFFFFFF;

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
    addListener(_followProbedHost);
    _followProbedHost();
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
    if (hello['text'] case final Map json) {
      textSettings.value = GaiaTextSettings.fromJson(json.cast());
    }
    _deviceId = hello['deviceId']! as String;
    await _applySettings((hello['settings']! as Map).cast<String, Object?>());
    if (_usageSources.isNotEmpty) {
      _usageTimer ??= Timer.periodic(_usageEvery, (_) {
        _usageSources.keys.expand(accountsFor).forEach(_readUsage);
      });
    }
    await _refresh();
    await _loadDrafts();
    unawaited(_loadQueue());
    unawaited(_curateMissed());
  }

  Future<void> _checkCli() async {
    cliVersions = {
      for (final MapEntry(:key, :value) in _cliVersions.entries)
        key: await value(),
    };
    cliChecked = true;
    notifyListeners();
    _readMissingUsage();
  }

  Future<void> _applySettings(Map<String, Object?> settings) async {
    _notifyOnDone = settings['notifyOnDone'] != false;
    _utility?.apply(settings);
    agents = gaiaAgentsFromJson(settings['agents']);
    tiers = gaiaTiersFromJson(settings['tiers']);
    lastTier = gaiaTierFromName(settings['lastTier']) ?? GaiaTier.standard;
    defaultTier = gaiaTierFromName(settings['defaultTier']);
    commands = gaiaCommandsFromJson(settings['commands']);
    keybinds = gaiaKeybindsFromJson(settings['keybinds']);
    _claudeConfigDir = settings['claudeConfigDir'] as String? ?? '';
    accounts = gaiaAccountsFromJson(settings['accounts']);
    _currentAccounts = gaiaCurrentAccountsFromJson(settings['currentAccounts']);
    final dirs = {
      for (final adapter in const [kGaiaClaudeCodeAdapter, kGaiaCodexAdapter])
        for (final account in accountsFor(adapter)) account.key: account.dir,
    };
    // A login no longer here, or on another folder: unknown until it's read.
    for (final MapEntry(:key, :value) in _usageDirs.entries) {
      if (dirs[key] == value) continue;
      usage.remove(key);
      usageHealth.remove(key);
      _usageCheckedAt.remove(key);
      _runAuth.remove(key);
      _runWorkedAt.remove(key);
      _limitHits.remove(key);
    }
    _usageDirs = dirs;
    _settingsApplied = true;
    notifyListeners();
    _readMissingUsage();
    for (final MapEntry(key: adapter, value: runner) in _runners.entries) {
      // None stored isn't a removal, as the last account can't be removed:
      // settings that lost the list mustn't cost every other account's login.
      if (runner case final GaiaAccountKeeper keeper
          when accounts.any((account) => account.adapter == adapter)) {
        unawaited(keeper.keepAccounts(accountsFor(adapter)));
      }
    }
    final instructions = settings['gaiaMd'] as String? ?? '';
    await Future.wait([
      for (final runner in _runners.values)
        runner.setInstructions(instructions),
    ]);
  }

  /// Every adapter's stored accounts; read through [accountsFor].
  var accounts = const <GaiaAccount>[];
  var _currentAccounts = const <String, String>{};

  /// [adapter]'s accounts in order (§6.1).
  List<GaiaAccount> accountsFor(String adapter) =>
      gaiaAccountsFor(adapter, accounts, _claudeConfigDir);

  /// The account [adapter]'s next message runs on (§6.5).
  GaiaAccount currentAccount(String adapter) =>
      gaiaCurrentAccount(adapter, accounts, _currentAccounts, _claudeConfigDir);

  /// Moves [adapter] to [account], for every chat: each resumes a copy of its
  /// session there on its next message (§6.5). A run already going finishes
  /// where it started.
  void switchAccount(String adapter, GaiaAccount account) {
    if (currentAccount(adapter) == account) return;
    _currentAccounts = {..._currentAccounts, adapter: account.id};
    notifyListeners();
    unawaited(
      _request('setCurrentAccount', {
        'adapter': adapter,
        'account': account.id,
      }),
    );
  }

  /// Whether switching accounts needs the user's yes: the current chat has a
  /// reply, whose prompt cache would be lost (§6.5).
  bool get accountSwitchNeedsConfirm =>
      messages.any((message) => message.role == GaiaMessageRole.assistant);

  /// Each account's usage by [GaiaAccount.key], as last read or as its last
  /// run said (§6.2).
  final usage = <String, GaiaUsage>{};

  /// How each account's last read ended (§6.4); none before the first.
  final usageHealth = <String, GaiaUsageHealth>{};
  final _usageCheckedAt = <String, DateTime>{};
  final _runAuth = <String, GaiaRunAuth>{};
  final _runWorkedAt = <String, DateTime>{};
  final Duration _runWorkedFor;
  final _usageReading = <String>{};
  final Map<String, GaiaUsageSource> _usageSources;
  final Duration _usageEvery;
  Timer? _usageTimer;

  /// Which accounts to read aren't known before the first settings.
  var _settingsApplied = false;
  var _claudeConfigDir = '';

  /// Each account's folder by [GaiaAccount.key], to tell when it changes.
  var _usageDirs = const <String, String>{};

  /// How long a failed read may leave the last numbers up before they're
  /// called offline: a blip, or the endpoint's own 429s, shouldn't take the
  /// ring away.
  static const _usageGrace = Duration(minutes: 30);

  /// What to say instead of the numbers of [account], by default [adapter]'s
  /// current one (§6.4); null while they're current.
  String? usageUntracked(String adapter, [GaiaAccount? account]) {
    final shown = account ?? currentAccount(adapter);
    final health = usageHealth[shown.key];
    if (health == null || health == GaiaUsageHealth.ok) return null;
    return gaiaUsageMessage(
      adapter,
      health,
      _usageCheckedAt[shown.key],
      account: accountsFor(adapter).length > 1 ? shown : null,
    );
  }

  /// Reads every account whose adapter has an agent and that has no reading
  /// yet.
  void _readMissingUsage() {
    for (final account in _usageSources.keys.expand(accountsFor)) {
      if (!usageHealth.containsKey(account.key)) {
        unawaited(_readUsage(account));
      }
    }
  }

  /// What [key]'s runs say of its login. One that worked says so only for a
  /// while: the login may have lapsed since (§6.4).
  GaiaRunAuth _runsSay(String key) {
    final runs = _runAuth[key] ?? GaiaRunAuth.unknown;
    final worked = _runWorkedAt[key];
    return runs == GaiaRunAuth.working &&
            worked != null &&
            DateTime.now().difference(worked) >= _runWorkedFor
        ? GaiaRunAuth.unknown
        : runs;
  }

  Future<void> _readUsage(GaiaAccount account) async {
    final adapter = account.adapter;
    final key = account.key;
    final source = _usageSources[adapter];
    if (source == null ||
        !_settingsApplied ||
        aborted ||
        !cliChecked ||
        cliVersions[adapter] == null ||
        agents.every((agent) => agent.adapter != adapter) ||
        !_usageReading.add(key)) {
      return;
    }
    GaiaUsageRead read;
    try {
      read = await source.read(runs: _runsSay(key), account: account);
    } catch (error) {
      // Nothing a source didn't foresee says anything of the account.
      debugPrint('[gaia] $adapter usage read failed: $error');
      read = const GaiaUsageRead(GaiaUsageHealth.offline);
    } finally {
      _usageReading.remove(key);
    }
    // On another folder by now, or removed: this says nothing of what's there.
    if (_usageDirs[key] != account.dir) {
      for (final now in accountsFor(adapter)) {
        if (now.key == key) return _readUsage(now);
      }
      return;
    }
    final now = DateTime.now();
    final checkedAt = _usageCheckedAt[key];
    if (read.usage case final fresh?) {
      usage[key] = fresh;
      usageHealth[key] = GaiaUsageHealth.ok;
      _usageCheckedAt[key] = now;
      if (_limitHits.containsKey(key) && _limitHits[key] == null) {
        _limitHits[key] = _soonestReset(key);
      }
    } else if (read.health == GaiaUsageHealth.offline &&
        usageHealth[key] == GaiaUsageHealth.ok &&
        checkedAt != null &&
        now.difference(checkedAt) < _usageGrace) {
      return;
    } else {
      usage.remove(key);
      usageHealth[key] = read.health;
    }
    _usageChanged();
  }

  void _usageChanged() {
    _limitDismissed.removeWhere((key) => !_limitReached(key));
    _watchResets();
    notifyListeners();
    if (!_pipe.connected) return;
    _pipe.notify('usage', {
      for (final key in {...usage.keys, ...usageHealth.keys})
        key: GaiaAccountUsage(
          health: usageHealth[key],
          usage: usage[key],
          checkedAt: _usageCheckedAt[key],
        ).toJson(),
    });
  }

  /// Accounts a run failed on with the provider's limit error (§6.5), until
  /// the time given, the account's soonest reset. With none known, the first
  /// read that gives one sets it; until then, or a run on it working, it's out.
  final _limitHits = <String, DateTime?>{};

  /// Accounts whose decision card was dismissed, until a limit is hit again or
  /// they recover.
  final _limitDismissed = <String>{};
  Timer? _resetTimer;

  bool _hitLimit(String key) {
    if (!_limitHits.containsKey(key)) return false;
    final until = _limitHits[key];
    return until == null || DateTime.now().isBefore(until);
  }

  /// Whether anything still says account [key] is out, for any model.
  bool _limitReached(String key) =>
      _hitLimit(key) ||
      (usage[key]?.windows.any((window) => window.usedNow >= 1) ?? false);

  DateTime? _soonestReset(String key) {
    final now = DateTime.now();
    return usage[key]?.windows
        .map((window) => window.resetsAt)
        .nonNulls
        .where((at) => at.isAfter(now))
        .minOrNull;
  }

  void _recordLimitHit(GaiaAccount account) {
    _limitHits[account.key] = _soonestReset(account.key);
    _limitDismissed.remove(account.key);
    _watchResets();
  }

  /// Wakes at the next reset of a used-up window or limit hit, so a card
  /// goes when it does rather than at the next poll.
  void _watchResets() {
    _resetTimer?.cancel();
    final now = DateTime.now();
    final next = [
      ..._limitHits.values.nonNulls,
      for (final known in usage.values)
        for (final window in known.windows)
          if (window.used >= 1) ?window.resetsAt,
    ].where((at) => at.isAfter(now)).minOrNull;
    if (next == null) return;
    _resetTimer = Timer(next.difference(now), _usageChanged);
  }

  /// [account]'s numbers while they can be believed (§6.4).
  GaiaUsage? _trackedUsage(GaiaAccount account) =>
      usageUntracked(account.adapter, account) == null
      ? usage[account.key]
      : null;

  /// Whether [account] can't run [model] (§6.5).
  bool _exhausted(GaiaAccount account, String model) {
    if (_hitLimit(account.key)) return true;
    final known = _trackedUsage(account);
    return known != null && gaiaFullWindows(known, model).isNotEmpty;
  }

  bool _low(GaiaAccount account, String model) {
    final known = _trackedUsage(account);
    return known != null && gaiaLowWindow(known, model) != null;
  }

  /// [from]'s adapter's other accounts that could run [model], those known to
  /// have headroom first, then those with no numbers, then the low. A signed
  /// out one couldn't run anything.
  List<GaiaAccount> _withHeadroom(GaiaAccount from, String model) {
    int rank(GaiaAccount account) => _low(account, model)
        ? 2
        : _trackedUsage(account) == null
        ? 1
        : 0;
    return [
      for (final account in accountsFor(from.adapter))
        if (account != from &&
            !_exhausted(account, model) &&
            usageHealth[account.key] != GaiaUsageHealth.signedOut)
          account,
    ]..sort((a, b) => rank(a) - rank(b));
  }

  /// The debug menu's made-up banner or card, in place of the real ones until
  /// it's closed. Never saved, and nothing it offers is acted on.
  GaiaLimitPreview? limitPreview;

  /// Where Gaia's client area starts on screen, in physical pixels.
  ({int x, int y}) get windowOrigin => _window.clientOrigin;

  void previewLimit(GaiaLimitPreview? preview) {
    limitPreview = preview;
    notifyListeners();
  }

  /// The warning over the composer, when the next message's account is low
  /// but not out (§6.5).
  GaiaLowUsage? get lowUsage {
    if (limitPreview case final preview?) return preview.low;
    final agent = agentFor(nextTier);
    if (agent == null) return null;
    final account = currentAccount(agent.adapter);
    final known = _trackedUsage(account);
    if (known == null || _exhausted(account, agent.model)) return null;
    final window = gaiaLowWindow(known, agent.model);
    if (window == null) return null;
    final name = accountsFor(agent.adapter).length > 1
        ? '${agent.label} (${account.label})'
        : agent.label;
    return GaiaLowUsage(
      adapter: agent.adapter,
      text: gaiaLowText(name, window),
      switchTo: _withHeadroom(
        account,
        agent.model,
      ).where((other) => !_low(other, agent.model)).firstOrNull,
    );
  }

  /// The decision card in place of the composer, when the next message's
  /// account is out (§6.5). Never mid-run: that run finishes on its account.
  GaiaLimitCard? get limitCard {
    if (limitPreview case final preview?) return preview.card;
    final agent = agentFor(nextTier);
    if (agent == null || currentRunning) return null;
    final account = currentAccount(agent.adapter);
    if (_limitDismissed.contains(account.key) ||
        !_exhausted(account, agent.model)) {
      return null;
    }
    final accounts = _withHeadroom(account, agent.model);
    final tiers = accounts.isNotEmpty
        ? const <GaiaTier>[]
        : [
            for (final tier in GaiaTier.values)
              if (agentFor(tier) case final other?
                  when other.adapter != agent.adapter &&
                      _runners.containsKey(other.adapter) &&
                      cliVersions[other.adapter] != null &&
                      usageHealth[currentAccount(other.adapter).key] !=
                          GaiaUsageHealth.signedOut &&
                      !_exhausted(currentAccount(other.adapter), other.model))
                tier,
          ];
    final resets = <({GaiaAccount account, DateTime? at})>[
      for (final each in accountsFor(agent.adapter))
        if (_exhausted(each, agent.model))
          (account: each, at: _resetOf(each, agent.model)),
    ];
    int unknownLast(DateTime? a, DateTime? b) =>
        a == null ? (b == null ? 0 : 1) : (b == null ? -1 : a.compareTo(b));
    resets.sort((a, b) => unknownLast(a.at, b.at));
    return GaiaLimitCard(
      agent: agent,
      account: account,
      named: accountsFor(agent.adapter).length > 1,
      accounts: accounts,
      tiers: tiers,
      resets: resets,
      resend: _interruptedQuestion != null,
    );
  }

  /// When [account] can run [model] again, if it's out and that's known: once
  /// every used-up window has reset.
  DateTime? _resetOf(GaiaAccount account, String model) {
    final full = switch (_trackedUsage(account)) {
      final known? => gaiaFullWindows(known, model),
      null => const <GaiaUsageWindow>[],
    };
    return full.map((window) => window.resetsAt).nonNulls.maxOrNull ??
        (_hitLimit(account.key) ? _limitHits[account.key] : null);
  }

  void dismissLimitCard() {
    if (limitPreview != null) return previewLimit(null);
    final agent = agentFor(nextTier);
    if (agent == null) return;
    _limitDismissed.add(currentAccount(agent.adapter).key);
    notifyListeners();
  }

  /// The prompt of the run a limit stopped, when that's the current chat's
  /// last reply.
  GaiaMessage? get _interruptedQuestion {
    final list = messages;
    if (list.length < 2) return null;
    final reply = list.last;
    final question = list[list.length - 2];
    return reply.role == GaiaMessageRole.assistant &&
            reply.status == GaiaMessageStatus.error &&
            gaiaRunLimited(reply.error ?? '') &&
            question.role == GaiaMessageRole.user
        ? question
        : null;
  }

  /// Sends the prompt the interrupted run was answering again, as it went
  /// (§6.5), leaving the draft alone.
  Future<void> resendInterrupted() async {
    final question = _interruptedQuestion;
    if (question == null) return;
    final images = <GaiaDraftImage>[];
    for (final image in question.parts.whereType<GaiaImagePart>()) {
      final path = await imageFile(image.mediaId);
      if (path == null) {
        for (final copied in images) {
          unawaited(_deleteQuietly(copied.path));
        }
        return _note(
          "Couldn't send it again",
          'An image in it is not on this device.',
          error: true,
        );
      }
      // A send deletes its images' files once it's done.
      final copy = p.join(_draftDirectory, '${_uuid.v4()}.img');
      await Directory(_draftDirectory).create(recursive: true);
      await File(path).copy(copy);
      images.add(GaiaDraftImage(label: image.label, path: copy));
    }
    await send(
      question.text,
      images: images,
      files: question.parts.whereType<GaiaFilePart>().toList(),
      resent: (
        quotes: question.parts.whereType<GaiaQuotePart>().toList(),
        context: question.parts.whereType<GaiaContextPart>().firstOrNull,
        control: question.parts.whereType<GaiaElementPart>().firstOrNull,
      ),
    );
  }

  /// The current chat's last reply that said its context (§7.5).
  GaiaMessage? get _contextReply => messages.reversed
      .where((message) => message.contextTokens != null)
      .firstOrNull;

  /// The current chat's context at [_contextReply].
  int? get contextTokens => _contextReply?.contextTokens;

  /// The window [contextTokens] fills: its reply's model's.
  int? get contextWindow => _contextReply?.contextWindow;

  /// Whether switching the current chat to [tier] needs the user's yes
  /// (§7.5): a change after the chat's first reply.
  bool switchNeedsConfirm(GaiaTier tier) =>
      tier != nextTier &&
      messages.any((message) => message.role == GaiaMessageRole.assistant);

  /// The tier the next message in the current chat goes to (§7.2).
  GaiaTier get nextTier =>
      pickedTier ?? currentChat?.tier ?? defaultTier ?? lastTier;

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
      case 'split':
        unawaited(
          _onSplit((
            left: params['left']! as int,
            top: params['top']! as int,
            width: params['width']! as int,
            height: params['height']! as int,
          )),
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
      case 'pointed':
        _onPointed(params);
      case 'refused':
        unawaited(_onRefused(vault: params['reason'] == 'vault'));
      case 'recheckUsage':
        for (final account in _usageSources.keys.expand(accountsFor)) {
          if (account.key == params['key']) unawaited(_readUsage(account));
        }
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
      case 'text':
        textSettings.value = GaiaTextSettings.fromJson(params);
      case 'settings':
        unawaited(_applySettings(params));
      case 'changed':
        unawaited(_refresh().then((_) => _drainIdle()));
      case 'drafts':
        unawaited(_loadDrafts());
      case 'queue':
        unawaited(_loadQueue());
      // Rearmed from the phone (§12.2).
      case 'rearmed':
        aborted = false;
        notifyListeners();
    }
  }

  Future<Object?> _onRequest(String method, Map<String, Object?> params) async {
    switch (method) {
      case 'abort':
        await _abort();
        return null;
      case 'stop':
        await stop(params['chatId']! as String, why: params['why'] as String?);
        return null;
      case 'drain':
        return _drain();
      case 'remote':
        return _onRemote(params);
      default:
        throw GaiaPipeException('unknown method $method');
    }
  }

  /// Each chat as last fetched, with the JSON it came from. A reply saving
  /// as it streams has the main instance send every chat again each
  /// second; one unchanged is given back as it was, so the sidebar's tile
  /// for it isn't built again.
  final _fetchedChats = <String, (String, GaiaChat)>{};

  GaiaChat _fetchedChat(Map<String, Object?> json) {
    final id = json['id']! as String;
    final encoded = jsonEncode(json);
    if (_fetchedChats[id] case (final was, final chat) when was == encoded) {
      return chat;
    }
    final chat = GaiaChat.fromJson(json);
    _fetchedChats[id] = (encoded, chat);
    return chat;
  }

  /// Chats and messages changed in the main instance: written here, synced
  /// from another device, or pinned, renamed or deleted on the Gaia page.
  /// A chat running here keeps the messages it is writing.
  Future<void> _refresh() async {
    // An image that wasn't here may be now. One still being asked about
    // isn't waited on.
    var changed = _missingImages.isNotEmpty;
    _missingImages
      ..forEach(_imageFiles.remove)
      ..clear();
    final list = (await _pipe.request('chats'))! as List;
    final saved = [
      for (final chat in list)
        _fetchedChat((chat as Map).cast<String, Object?>()),
    ];
    final ids = {for (final chat in saved) chat.id};
    _fetchedChats.removeWhere((id, _) => !ids.contains(id));
    final was = chats;
    // A new chat isn't saved until its first message's images are attached.
    chats = [
      for (final chat in chats)
        if (_running.contains(chat.id) && !saved.any((c) => c.id == chat.id))
          chat,
      ...saved,
    ]..sort(_listed);
    final current = currentChatId;
    if (current != null &&
        !_running.contains(current) &&
        !chats.any((chat) => chat.id == current)) {
      _viewChat(null);
      // What was typed in it goes to a new chat, as a failed new chat's does.
      if (_drafts.remove(current) case final typed?) {
        _giveBack(null, typed.text.text, typed.images, typed.files);
      }
      changed = true;
    }
    _messages.removeWhere(
      (chatId, _) => !_running.contains(chatId) && chatId != currentChatId,
    );
    _draftHistories.removeWhere(
      (key, _) =>
          key != GaiaDraft.newChatId && !chats.any((chat) => chat.id == key),
    );
    // Not for a refresh that changed nothing shown, as each of a streaming
    // reply's saves brings: it would rebuild all of Gaia every second.
    if (changed ||
        chats.length != was.length ||
        chats.indexed.any((entry) => !identical(entry.$2, was[entry.$1]))) {
      notifyListeners();
    }
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

  /// A capture hotkey while aborted (§15.7), or with [vault] unlocked (§15.6):
  /// Gaia comes up saying so.
  Future<void> _onRefused({bool vault = false}) async {
    _toasts.add((
      chatId: '',
      title: vault ? "Can't capture the screen" : 'Gaia is aborted',
      body: vault
          ? "Voyager's secure vault is unlocked. Lock it to use this."
          : 'Re-arm it to use this.',
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
    // Pressed again, each closes, but only when in front: up without the
    // focus, as a floater raised for a card is, or behind another app, it's
    // brought to the front instead. Before going to a waiting chat, so
    // closing leaves the chat as it was.
    final closes =
        _window.foreground &&
        ((key == 'small' && shown == GaiaMode.small) ||
            (key == 'large' && shown == GaiaMode.large) ||
            (pressed &&
                shown == GaiaMode.window &&
                (key == 'window' ||
                    (key == 'fullScreen' && _window.fullScreen))));
    if (closes) {
      // A floater closes rather than going back to the Gaia window it was
      // opened over, which the next press would turn back into the floater.
      if (key == shown?.name) _returnTo = null;
      return dismiss();
    }
    await _openWaitingChat();
    switch (key) {
      case 'small':
        _returnTo = shown == GaiaMode.window ? GaiaMode.window : _returnTo;
        await _show(GaiaMode.small);
      case 'large':
        _returnTo = shown == GaiaMode.window ? GaiaMode.window : _returnTo;
        await _show(GaiaMode.large);
      case 'window':
        await openWindow();
      case 'fullScreen':
        await _openLastChat();
        _returnTo = null;
        await _show(GaiaMode.window, fullScreen: true);
    }
    _summoned.add(null);
  }

  /// Summoned with a card waiting on the user in another chat, Gaia goes to
  /// the chat of the one raised last, to answer it at once. Not away from a
  /// chat in view that's running: its toast and spinner point to the card.
  Future<void> _openWaitingChat() async {
    final waiting = cards.waitingChats;
    if (waiting.isEmpty || waiting.contains(currentChatId) || currentRunning) {
      return;
    }
    await selectChat(waiting.last);
  }

  /// The split hotkey: the host has moved the other window, and [half] is
  /// the Gaia window's.
  Future<void> _onSplit(GaiaFrame half) async {
    if (cropping != null) return finishCrop(null);
    _dropPickUp();
    _returnTo = null;
    await _show(GaiaMode.window, frame: half, fullScreen: false);
    _summoned.add(null);
  }

  /// The chat left in view stays there. Nothing has been in view yet this
  /// run, as after a restart: the one last active, since what was in view
  /// isn't kept across runs. A new chat's draft is something in view.
  Future<void> _openLastChat() async {
    if (currentChatId != null ||
        _chatViewed ||
        chats.isEmpty ||
        draft.text.isNotEmpty ||
        draftImages.isNotEmpty ||
        draftFiles.isNotEmpty) {
      return;
    }
    await selectChat(
      chats
          .reduce((a, b) => b.lastMessageAt.isAfter(a.lastMessageAt) ? b : a)
          .id,
    );
  }

  /// Leaves full screen, for where the Gaia window was before it.
  Future<void> leaveFullScreen() => _show(GaiaMode.window, fullScreen: false);

  bool get fullScreen => _window.fullScreen;

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

  Future<void> _show(
    GaiaMode mode, {
    bool behind = false,
    GaiaFrame? frame,
    bool? fullScreen,
    bool activate = true,
  }) {
    if (currentChatId == null && !debug.dummyMode) _utility?.warm();
    onScreen.value = true;
    return _window.show(
      mode,
      () {
        layout = mode;
        notifyListeners();
      },
      behind: behind,
      frame: frame,
      fullScreen: fullScreen,
      activate: activate,
    );
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
    // Its undo steps hold the text that just left, without its images.
    _draftHistories.remove(from);
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
    draftUndo.reset();
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

  /// A new chat with [at]'s chat's messages up to [at], which then goes its
  /// own way (GAIA_FORKING_HLD.md §2), opened. The copies get new ids but
  /// keep their seqs. Where the source's Claude Code session here has the
  /// copied turns, the fork's first send forks that session (§5); otherwise
  /// it hands the copied turns over (§6). Not at a reply still streaming,
  /// which no fork copies (§3).
  Future<void> forkChat(GaiaMessage at) async {
    // One at a time: finding the cut can wait seconds on a prompt just sent.
    if (_forking) return;
    _forking = true;
    try {
      await _forkChat(at);
    } finally {
      _forking = false;
    }
  }

  bool _forking = false;

  Future<void> _forkChat(GaiaMessage at) async {
    final source = _chat(at.chatId);
    final list = _messages[at.chatId];
    final point = list?.where((m) => m.id == at.id).firstOrNull;
    if (source == null ||
        point == null ||
        point.status == GaiaMessageStatus.streaming) {
      return;
    }
    final copied = [
      for (final message in list!)
        if (message.seq <= point.seq && !message.isDeleted) message,
    ];
    // Its stored ids come once they're attached.
    if (copied.any(
      (message) => message.parts.any(
        (part) =>
            part is GaiaImagePart && uploadingImages.contains(part.mediaId),
      ),
    )) {
      return _note(
        "Couldn't fork the chat",
        'Its images are still being attached. Try again in a moment.',
        error: true,
      );
    }
    final record = await _forkRecord(source, point, list);
    final now = utcNow();
    final forkId = _uuid.v4();
    final fork = GaiaChat(
      id: forkId,
      title: '${source.title} (fork)',
      createdAt: now,
      updatedAt: now,
      lastMessageAt: now,
      tier: source.tier,
      // The copies are the source's to curate, whether its curator has read
      // them yet or not: each fork reading them again saved their memories
      // once per fork (BUG-369).
      curatedSeq: point.seq,
      fork: record,
    );
    final copies = [
      for (final message in copied)
        GaiaMessage.fromJson({
          ...message.toJson(),
          'id': _uuid.v4(),
          'chatId': forkId,
          'updatedAt': now.toIso8601String(),
          // So a fork of this fork finds it in a native session (§5.2).
          'origin': message.entryId,
          // Its own cards: answering one doesn't answer the source's.
          'parts': [
            for (final part in message.parts)
              part is GaiaCardPart
                  ? {...part.toJson(), 'id': _uuid.v4()}
                  : part.toJson(),
          ],
        }),
    ];
    try {
      await _pipe.request('forkChat', {
        'chat': fork.toJson(),
        'messages': [for (final message in copies) message.toJson()],
      });
    } on GaiaPipeException catch (error) {
      return _note("Couldn't fork the chat", error.message, error: true);
    }
    chats = [fork, ...chats]..sort(_listed);
    _messages[forkId] = copies;
    await selectChat(forkId);
  }

  /// The native session a fork of [source] at [point] starts from on this
  /// device (GAIA_FORKING_HLD.md §5.5): the source's Claude Code session here
  /// that has every turn up to the fork, cut where they end (§5.2). Null when
  /// there's none, and the fork hands its turns over instead (§6).
  Future<GaiaForkRecord?> _forkRecord(
    GaiaChat source,
    GaiaMessage point,
    List<GaiaMessage> list,
  ) async {
    const adapter = kGaiaClaudeCodeAdapter;
    final runner = _runners[adapter];
    if (runner is! GaiaSessionForker) return null;
    // What the fork's session knows: up to the message before a prompt
    // forked at, which its first send then names (§3). A reply cut short
    // counts as forking at its prompt: the session holds the CLI's
    // placeholder for that turn, not the partial text shown, so the first
    // send hands both over (BUG-368).
    final cutShort =
        point.role != GaiaMessageRole.user &&
        const {
          GaiaMessageStatus.cancelled,
          GaiaMessageStatus.interrupted,
          GaiaMessageStatus.aborted,
        }.contains(point.status);
    final prompt = cutShort
        ? list.lastWhereOrNull(
            (m) => m.role == GaiaMessageRole.user && m.seq < point.seq,
          )
        : null;
    final lastSeq = point.role == GaiaMessageRole.user
        ? point.seq - 1
        : prompt != null
        ? prompt.seq - 1
        : point.seq;
    // The last prompt that session answered, which it must have.
    final answered = list.lastWhereOrNull(
      (m) => m.role == GaiaMessageRole.user && m.seq <= lastSeq,
    );
    if (answered == null) return null;
    GaiaAccount? account;
    GaiaAgentSession? session;
    for (final candidate in accountsFor(adapter)) {
      final mine =
          source.agentSessions[gaiaSessionKey(
            _deviceId,
            adapter: adapter,
            account: candidate.id,
          )];
      if (mine != null &&
          mine.lastSeq >= lastSeq &&
          (session == null || mine.lastSeq > session.lastSeq)) {
        account = candidate;
        session = mine;
      }
    }
    // A fork not sent in yet: its own record's source session, cut no later
    // than that record's cut, which is as far as the copies go (§10.5).
    String? endAt;
    if (source.fork case final pending?
        when session == null && pending.lastSeq >= lastSeq) {
      account = _accountForKey(adapter, pending.sessionKey);
      session = GaiaAgentSession(
        sessionId: pending.sourceSessionId,
        lastSeq: pending.lastSeq,
      );
      endAt = pending.keepAt;
    }
    if (account == null || session == null) return null;
    // A turn running here on that session: its prompt may not have reached
    // the session's file yet. A fork's first turn runs on a session of its
    // own.
    final live = endAt == null && _running.contains(source.id)
        ? list.lastWhereOrNull(
            (m) =>
                m.status == GaiaMessageStatus.streaming &&
                m.adapter == adapter &&
                m.account == account!.id,
          )
        : null;
    final livePrompt = live == null
        ? null
        : list.lastWhereOrNull(
            (m) => m.role == GaiaMessageRole.user && m.seq < live.seq,
          );
    final String? keepAt;
    try {
      keepAt = await (runner as GaiaSessionForker).forkCut(
        chatId: source.id,
        sessionId: session.sessionId,
        account: account,
        after: answered.entryId,
        next: [
          for (final message in list)
            if (message.role == GaiaMessageRole.user && message.seq > lastSeq)
              message.entryId,
        ],
        awaiting: livePrompt != null && livePrompt.seq > lastSeq
            ? livePrompt.entryId
            : null,
        endAt: endAt,
      );
    } on FileSystemException catch (error) {
      debugPrint('[gaia] fork of ${source.id} not native: $error');
      return null;
    }
    if (keepAt == null) return null;
    return GaiaForkRecord(
      sessionKey: gaiaSessionKey(
        _deviceId,
        adapter: adapter,
        account: account.id,
      ),
      sourceSessionId: session.sessionId,
      keepAt: keepAt,
      lastSeq: lastSeq,
    );
  }

  /// The fork record [chatId]'s first send on [to] forks with (§5.3), the
  /// source session copied to [to] first when it's another account's
  /// (§5.4). Null for none, as on another adapter, whose session the record
  /// isn't for; one whose session can't be had on [to] is dropped.
  Future<GaiaForkRecord?> _forkFor(
    String chatId,
    GaiaAgentRunner runner,
    GaiaAccount to,
  ) async {
    final fork = _chat(chatId)?.fork;
    if (fork == null) return null;
    final from = _accountForKey(to.adapter, fork.sessionKey);
    if (from == null) return null;
    if (from.id == to.id) return fork;
    // A chat already followed the source session to [to]: that copy is the
    // newer one, and copying over it would lose its later turns.
    final toKey = gaiaSessionKey(
      _deviceId,
      adapter: to.adapter,
      account: to.id,
    );
    if (chats.any(
      (chat) => chat.agentSessions[toKey]?.sessionId == fork.sourceSessionId,
    )) {
      return fork;
    }
    try {
      if (runner is GaiaSessionCopier &&
          await (runner as GaiaSessionCopier).copySession(
            sessionId: fork.sourceSessionId,
            from: from,
            to: to,
          )) {
        return fork;
      }
    } on FileSystemException catch (error) {
      debugPrint('[gaia] fork source not copied to ${to.label}: $error');
    }
    _dropFork(chatId);
    return null;
  }

  /// [adapter]'s account here whose session key is [key].
  GaiaAccount? _accountForKey(String adapter, String key) =>
      accountsFor(adapter)
          .where(
            (account) =>
                gaiaSessionKey(
                  _deviceId,
                  adapter: adapter,
                  account: account.id,
                ) ==
                key,
          )
          .firstOrNull;

  /// Forgets [chatId]'s fork record: its session was made, or can't be.
  void _dropFork(String chatId) {
    chats = [
      for (final c in chats) c.id == chatId ? c.copyWith(clearFork: true) : c,
    ];
    unawaited(_request('dropFork', {'chatId': chatId}));
  }

  /// Pins or unpins [chatId], moving it in the list at once.
  Future<void> setPinned(String chatId, bool pinned) async {
    chats = [
      for (final c in chats) c.id == chatId ? c.copyWith(pinned: pinned) : c,
    ]..sort(_listed);
    notifyListeners();
    await _request('setPinned', {'chatId': chatId, 'pinned': pinned});
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

  /// The chat and the JSON of the messages [_load] last fetched. A reply
  /// saving as it streams elsewhere refreshes the shown chat each second;
  /// one that came back unchanged isn't drawn again.
  (String, String)? _loaded;

  Future<void> _load(String chatId) async {
    final list = (await _pipe.request('messages', {'chatId': chatId}))! as List;
    // A run that started meanwhile has the newer list.
    if (_running.contains(chatId)) return;
    final loaded = (chatId, jsonEncode(list));
    if (loaded == _loaded && _messages.containsKey(chatId)) return;
    _loaded = loaded;
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
      case GaiaBuiltin.remember:
        await remember('');
      case GaiaBuiltin.queue:
        await enqueue('');
      case GaiaBuiltin.queuePop:
        await popQueue(send: false);
      case GaiaBuiltin.queuePopSend:
        await popQueue(send: true);
      case GaiaBuiltin.drain:
        await toggleDrain();
      case GaiaBuiltin.thisControl:
        await attachThis();
    }
  }

  /// Every waiting prompt (§13), in order; the global queue's have no chat.
  var queue = const <GaiaQueueItem>[];

  /// [chatId]'s waiting prompts, in order.
  List<GaiaQueueItem> queueFor(String? chatId) => [
    for (final item in queue)
      if (item.chatId == chatId) item,
  ];

  Future<void> _loadQueue() async {
    try {
      final listed = await _pipe.request('queue', {'all': true});
      if (listed is! List) return;
      queue = [
        for (final json in listed)
          GaiaQueueItem.fromJson((json as Map).cast<String, Object?>()),
      ];
      notifyListeners();
      _drainIdle();
    } on GaiaPipeException catch (error) {
      debugPrint('[gaia] queue not read: $error');
    }
  }

  void _note(String title, String body, {bool error = false}) => _toasts.add((
    chatId: '',
    title: title,
    body: body,
    error: error,
    question: false,
  ));

  /// `/queue <text>` (§13): [text] at the end of [chatId]'s queue, the
  /// chat in view's by default, or the global one before a chat starts.
  Future<void> enqueue(String text, {String? chatId}) async {
    if (text.trim().isEmpty) {
      return _note('Nothing to queue', 'Type it after /queue.');
    }
    final to = chatId ?? currentChatId;
    try {
      await _pipe.request('enqueue', {'chatId': to, 'text': text.trim()});
      await _loadQueue();
      final waiting = queueFor(to).length;
      _note(
        'Queued',
        waiting == 1 ? '1 prompt waiting.' : '$waiting prompts waiting.',
      );
    } on GaiaPipeException catch (error) {
      if (draft.text.isEmpty) draft.text = '/queue $text';
      _note("Couldn't queue that", error.message, error: true);
    }
  }

  /// `/queue-pop` puts the chat in view's next prompt in the composer to
  /// review; `/queue-pop!` sends it (§13).
  Future<void> popQueue({required bool send}) async {
    final GaiaQueueItem? next;
    try {
      next = switch (await _pipe.request('queuePop', {
        'chatId': currentChatId,
      })) {
        final Map json => GaiaQueueItem.fromJson(json.cast()),
        _ => null,
      };
    } on GaiaPipeException catch (error) {
      return _note("Couldn't read the queue", error.message, error: true);
    }
    unawaited(_loadQueue());
    if (next == null) return _note('Nothing queued', 'This chat has no queue.');
    if (send) return this.send(next.text);
    draft.text = draft.text.isEmpty ? next.text : '${draft.text}\n${next.text}';
    notifyListeners();
  }

  /// `/drain` (§13): the chat in view's drain mode on or off.
  Future<void> toggleDrain() async {
    final chat = currentChat;
    if (chat == null) {
      return _note('No chat yet', 'Drain mode is for a chat that has begun.');
    }
    final drain = !chat.drain;
    chats = [
      for (final c in chats) c.id == chat.id ? c.copyWith(drain: drain) : c,
    ];
    notifyListeners();
    await _request('setDrain', {'chatId': chat.id, 'drain': drain});
    _note(
      drain ? 'Drain mode on' : 'Drain mode off',
      drain
          ? 'Queued prompts go one after another as replies finish.'
          : 'Queued prompts wait to be sent.',
    );
    if (drain && !_running.contains(chat.id)) _drainNext(chat.id);
  }

  /// A new chat's *can see screen*, until its first message makes it one.
  var _newChatSeesScreen = false;

  /// Turned on just now: the warning stays beside the toggle (§15.6) until
  /// the next message, or the toggle or the chat changes.
  var seeScreenWarning = false;

  /// *Can see screen* (§15.6) for the chat in view, on this device.
  bool get canSeeScreen => switch (currentChat) {
    final chat? => chat.grants[_deviceId]?.seeScreen ?? false,
    null => _newChatSeesScreen,
  };

  Future<void> toggleSeeScreen() async {
    final chat = currentChat;
    final on = !canSeeScreen;
    seeScreenWarning = on;
    if (chat == null) {
      _newChatSeesScreen = on;
      notifyListeners();
      return;
    }
    chats = [
      for (final c in chats)
        c.id == chat.id
            ? c.copyWith(
                grants: {
                  ...c.grants,
                  _deviceId: GaiaGrant(
                    seeScreen: on,
                    canControl: c.grants[_deviceId]?.canControl ?? false,
                    // Auto needs reading (GAIA_AUTONOMY_HLD.md §4).
                    auto: on && (c.grants[_deviceId]?.auto ?? false),
                    at: utcNow(),
                  ),
                },
              )
            : c,
    ];
    notifyListeners();
    await _request('setSeeScreen', {'chatId': chat.id, 'on': on});
  }

  /// A new chat's *can control*, until its first message makes it one. Never
  /// Auto (GAIA_AUTONOMY_HLD.md §4).
  var _newChatCanControl = false;

  /// *Can control* (§15.6) for the chat in view, on this device.
  bool get canControl => switch (currentChat) {
    final chat? => chat.grants[_deviceId]?.canControl ?? false,
    null => _newChatCanControl,
  };

  /// The hand (GAIA_AUTONOMY_HLD.md §4) for the chat in view, on this device.
  GaiaHand get hand => switch (currentChat?.grants[_deviceId]) {
    final grant? when grant.isAuto => GaiaHand.auto,
    _ => canControl ? GaiaHand.ask : GaiaHand.off,
  };

  /// Whether Auto's notice has been confirmed on this device (§4).
  Future<bool> autoConsented() async {
    try {
      return await _pipe.request('autoConsented') == true;
    } on GaiaPipeException {
      return false;
    }
  }

  /// Sets the hand. A new chat never starts in Auto, and the main instance
  /// refuses Auto until its notice is [consented] to, once per device (§4).
  Future<void> setHand(GaiaHand to, {bool consented = false}) async {
    final chat = currentChat;
    if (to == hand) return;
    if (chat == null) {
      if (to == GaiaHand.auto) return;
      _newChatCanControl = to == GaiaHand.ask;
      notifyListeners();
      return;
    }
    final grant = chat.grants[_deviceId];
    final auto = to == GaiaHand.auto;
    chats = [
      for (final c in chats)
        c.id == chat.id
            ? c.copyWith(
                grants: {
                  ...c.grants,
                  _deviceId: GaiaGrant(
                    seeScreen: auto || (grant?.seeScreen ?? false),
                    canControl: to != GaiaHand.off,
                    auto: auto,
                    at: utcNow(),
                  ),
                },
              )
            : c,
    ];
    notifyListeners();
    if (to == GaiaHand.off) {
      await _request('setCanControl', {'chatId': chat.id, 'on': false});
    } else if (auto || (grant?.auto ?? false)) {
      await _request('setAuto', {
        'chatId': chat.id,
        'on': auto,
        'consented': consented,
      });
      if (!auto && !(grant?.canControl ?? false)) {
        await _request('setCanControl', {'chatId': chat.id, 'on': true});
      }
    } else {
      await _request('setCanControl', {'chatId': chat.id, 'on': true});
    }
  }

  /// In drain mode, [chatId]'s next prompt goes once its reply finished
  /// cleanly (§13): not after an error, a stop or Abort, nor while a card
  /// waits on the user.
  void _drainNext(String chatId, [GaiaMessage? reply]) {
    final chat = _chat(chatId);
    if (chat == null || !chat.drain || aborted || draining != null) return;
    if (_running.contains(chatId) || queueFor(chatId).isEmpty) return;
    if (reply != null && !_endedCleanly(reply)) return;
    if (!_drainPopping.add(chatId)) return;
    unawaited(() async {
      try {
        // Idle, it goes by the chat's last message as saved: what's in
        // memory here may not have the reply another device stopped. Before
        // the lease: one taken for a chat that can't go is only let go again,
        // on every change.
        if (reply == null && !await _lastEndedCleanly(chatId)) return;
        // The lease before the pop: a prompt popped for a chat another
        // desktop runs would only go back in the queue, which starts this
        // over. That desktop drains the chat itself; if it lets go first, its
        // reply syncing here brings this back.
        if (await _takeLease(chatId) != null) return;
        final popped = aborted || _running.contains(chatId)
            ? null
            : await _pipe
                  .request('queuePop', {'chatId': chatId})
                  .catchError((Object _) => null);
        if (popped is! Map) {
          if (!_running.contains(chatId)) {
            unawaited(_request('releaseLease', {'chatId': chatId}));
          }
          return;
        }
        unawaited(_loadQueue());
        await _sendPopped(GaiaQueueItem.fromJson(popped.cast()), chatId);
      } finally {
        _drainPopping.remove(chatId);
      }
    }());
  }

  /// [send] for a message that isn't this desktop's draft. Gives back null
  /// once its reply is under way, or why it didn't start.
  Future<String?> _sendRemote(
    String text, {
    required String chatId,
    GaiaTier? tier,
    bool fromQueue = false,
    void Function()? onQueued,
  }) {
    final started = Completer<String?>();
    unawaited(
      send(
        text,
        remote: (chatId: chatId, tier: tier),
        started: started,
        fromQueue: fromQueue,
        onQueued: onQueued,
      ).catchError((Object error) {
        debugPrint('[gaia] send to $chatId failed: $error');
        if (!started.isCompleted) started.complete('$error');
      }),
    );
    return started.future;
  }

  /// Sends [item], just taken off [chatId]'s queue. One that doesn't start
  /// goes back at the front (§13): it's marked sent, which stays, so nothing
  /// else would ever send it. Gives back why it didn't start.
  Future<String?> _sendPopped(GaiaQueueItem item, String chatId) async {
    var queued = false;
    final why = await _sendRemote(
      item.text,
      chatId: chatId,
      fromQueue: true,
      onQueued: () => queued = true,
    );
    if (why != null && !queued && item.text.trim().isNotEmpty) {
      try {
        await _pipe.request('enqueue', {
          'chatId': chatId,
          'text': item.text,
          'front': true,
        });
        unawaited(_loadQueue());
      } on GaiaPipeException catch (error) {
        debugPrint('[gaia] queued prompt not put back: $error');
      }
    }
    return why;
  }

  /// A reply that finished as it should, with no card waiting.
  bool _endedCleanly(GaiaMessage reply) =>
      reply.status == GaiaMessageStatus.complete &&
      !reply.parts.any((p) => p is GaiaCardPart && p.isOpen);

  /// Whether [chatId] may go on: no messages, or a last reply that ended
  /// cleanly. A question last means its reply is still running somewhere.
  Future<bool> _lastEndedCleanly(String chatId) async {
    try {
      final list =
          (await _pipe.request('messages', {'chatId': chatId}))! as List;
      if (list.isEmpty) return true;
      final last = GaiaMessage.fromJson(
        (list.last as Map).cast<String, Object?>(),
      );
      return last.role == GaiaMessageRole.assistant && _endedCleanly(last);
    } on GaiaPipeException {
      return false;
    }
  }

  /// Chats [_drainNext] is taking a prompt off the queue for.
  final _drainPopping = <String>{};

  /// Drain mode switched on from another device, or a prompt queued from
  /// one, for a chat sitting idle here: it starts without a reply ending.
  void _drainIdle() {
    for (final chat in chats) {
      if (chat.drain) _drainNext(chat.id);
    }
  }

  /// `/remember <text>` (§11): [text] saved as a memory, active at once,
  /// since the user wrote it. Not saved, it goes back in the draft.
  Future<void> remember(String text) async {
    void toast(String title, String body, {bool error = false}) => _toasts.add((
      chatId: '',
      title: title,
      body: body,
      error: error,
      question: false,
    ));
    if (text.trim().isEmpty) {
      return toast('Nothing to remember', 'Type it after /remember.');
    }
    try {
      final reply =
          (await _pipe.request('remember', {
                'chatId': currentChatId,
                'text': text.trim(),
              }))!
              as Map;
      reply['saved'] == true
          ? toast('Remembered', text.trim())
          : toast('Already remembered', text.trim());
    } on GaiaPipeException catch (error) {
      if (draft.text.isEmpty) draft.text = '/remember $text';
      toast("Couldn't remember that", error.message, error: true);
    }
  }

  /// "Add to dictionary" from the composer: the main instance adds [word]
  /// to the user's dictionary, which comes back as [textSettings].
  Future<void> addWord(String word) async {
    try {
      await _pipe.request('addWord', {'word': word});
    } on GaiaPipeException catch (error) {
      _toasts.add((
        chatId: '',
        title: "Couldn't add that word",
        body: error.message,
        error: true,
        question: false,
      ));
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
  ///
  /// [remote] is a message a paired device sent (§12.2), to that chat, a
  /// new one by that id when there's none: it has no draft, quotes or
  /// window, leaves the chat in view as it is, and goes on [remote]'s tier
  /// if it names one. [started] completes once its reply is under way, with
  /// null, or with why it didn't start. [fromQueue] is a prompt just taken
  /// off its queue: if it has to wait, it waits at the front. [resent] is a
  /// prompt being sent again, already expanded, with its own quotes and window
  /// in place of the draft's.
  Future<void> send(
    String text, {
    List<GaiaDraftImage> images = const [],
    List<GaiaFilePart> files = const [],
    ({String chatId, GaiaTier? tier})? remote,
    Completer<String?>? started,
    void Function()? onQueued,
    bool fromQueue = false,
    ({
      List<GaiaQuotePart> quotes,
      GaiaContextPart? context,
      GaiaElementPart? control,
    })?
    resent,
  }) async {
    void notStarted(String why) {
      if (started != null && !started.isCompleted) started.complete(why);
    }

    if (remote == null && resent == null) {
      if (gaiaBuiltinIn(text) case final builtin?) return runBuiltin(builtin);
      if (gaiaRememberText(text) case final memory?) return remember(memory);
    }
    var prompt = resent != null
        ? text.trim()
        : (await _expand(text.trim())).trim();
    if (prompt.isEmpty &&
        images.isEmpty &&
        files.isEmpty &&
        (remote != null || (resent?.quotes ?? draftQuotes).isEmpty)) {
      return notStarted('There is nothing to send.');
    }
    final targetId = remote?.chatId ?? currentChatId;
    // A chat sent to before its messages came: they're numbered on from.
    if (targetId case final id?
        when !_messages.containsKey(id) && !_running.contains(id)) {
      await _load(id);
    }
    // After a stopped message's take-back, which then leaves it in the chat.
    if (targetId case final id? when _takingBack.containsKey(id)) {
      _takeBackSuperseded.add(id);
      await _takingBack[id];
    }
    // A remote message to a chat that's running, or just starting, waits
    // in its queue (§13).
    if (remote != null &&
        !aborted &&
        _running.contains(remote.chatId) &&
        prompt.isNotEmpty) {
      try {
        await _pipe.request('enqueue', {
          'chatId': remote.chatId,
          'text': prompt,
          'front': fromQueue,
        });
      } on GaiaPipeException catch (error) {
        return notStarted(error.message);
      }
      unawaited(_loadQueue());
      onQueued?.call();
      return notStarted('Queued.');
    }
    if (aborted ||
        draining != null ||
        (targetId != null && _running.contains(targetId))) {
      notStarted(
        aborted
            ? 'Gaia is aborted.'
            : draining != null
            ? 'Gaia is closing for an update.'
            : 'This chat is already running.',
      );
      if (remote != null) return;
      return _giveBack(currentChatId, text, images, files);
    }
    var chat = remote == null ? currentChat : _chat(remote.chatId);
    final isNew = chat == null;
    // Claimed now, so a second send can't start while this one's images
    // upload or its tier is picked.
    final chatId = chat?.id ?? remote?.chatId ?? _uuid.v4();
    _running.add(chatId);
    // Read once it's idle again.
    _curateSoon.remove(chatId)?.cancel();
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
        : (resent?.quotes ?? draftQuotes).first.text;
    // The summon's window goes with this message only. A remote one has
    // neither, nor quotes: they're the desktop's draft's.
    final context = resent != null
        ? resent.context
        : remote == null
        ? windowContext
        : null;
    final control = resent != null
        ? resent.control
        : remote == null
        ? draftControl
        : null;
    final quotes =
        resent?.quotes ??
        (remote == null ? [...draftQuotes] : <GaiaQuotePart>[]);
    if (remote == null && resent == null) {
      windowContext = null;
      draftControl = null;
      draftQuotes.clear();
    }
    final sentAt = utcNow();
    if (remote == null) seeScreenWarning = false;
    if (chat == null) {
      chat = GaiaChat(
        id: chatId,
        title: _firstLineTitle(prompt, files, quotes),
        createdAt: sentAt,
        updatedAt: sentAt,
        lastMessageAt: sentAt,
        tier:
            remote?.tier ??
            (remote == null ? nextTier : defaultTier ?? lastTier),
        grants: remote == null && (_newChatSeesScreen || _newChatCanControl)
            ? {
                _deviceId: GaiaGrant(
                  seeScreen: _newChatSeesScreen,
                  canControl: _newChatCanControl,
                  at: sentAt,
                ),
              }
            : const {},
      );
      if (remote == null) {
        _newChatSeesScreen = false;
        _newChatCanControl = false;
      }
      chats = [chat, ...chats]..sort(_listed);
      // A remote chat is listed, but the one in view stays.
      if (remote == null) currentChatId = chatId;
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
        ?control,
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
    // This send's entry in [_cancelSend], set below.
    void Function()? cancel;
    // The images [undo] puts back: once sent, copies of the stored ones, as
    // the draft's own files are gone by then.
    var imagesBack = images;

    // The send didn't happen: the question comes off the chat, and a new
    // chat with it, and it all goes back in the draft; a remote one's
    // sender is told [why].
    void undo([String why = "It didn't start.", bool giveBack = true]) {
      // Only its own: a resend after a stop has its own.
      if (identical(_cancelSend[chatId], cancel)) _cancelSend.remove(chatId);
      // A stop that came once the run was to have it: there's no run.
      _stopping.remove(chatId);
      notStarted(why);
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
      if (remote != null || !giveBack) {
        _reportRuns();
        return _settleDrain();
      }
      windowContext = context;
      draftControl = control;
      // Less any attached again meanwhile.
      draftQuotes.insertAll(0, [
        for (final quote in quotes)
          if (!draftQuotes.any(
            (q) => q.role == quote.role && q.text == quote.text,
          ))
            quote,
      ]);
      _giveBack(isNew ? null : chatId, text, imagesBack, files);
      _reportRuns();
      _settleDrain();
    }

    // Stopped before its run started: undone at once, and each step still
    // under way when it was quits once it's done, leaving nothing behind.
    var stopped = false;
    _cancelSend[chatId] = cancel = () {
      stopped = true;
      undo('Stopped.');
      notifyListeners();
    };

    // Before anything is saved: an image that can't be attached stops the
    // send.
    for (final image in labeled) {
      try {
        if (debug.attachDelay > Duration.zero) {
          await Future<void>.delayed(debug.attachDelay);
        }
        if (stopped) break;
        // Edits are flattened now (§9.4), and a capture is a BMP, which the
        // media module doesn't take.
        final upload = await gaiaUploadablePath(image.path, edits: image.edits);
        if (upload != image.path) uploads.add(upload);
        if (stopped) break;
        final stored =
            (await _pipe.request('attachImage', {
                  'chatId': chatId,
                  'path': upload,
                }))!
                as Map;
        if (stopped) {
          unawaited(
            _request('detachImage', {'referenceId': stored['referenceId']}),
          );
          break;
        }
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
        if (stopped) return;
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
    if (stopped) return;
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
            ?control,
          ],
          bumpVersion: false,
          touch: false,
        ),
      );
    }
    var tier = remote == null
        ? nextTier
        : remote.tier ?? chat.tier ?? defaultTier ?? lastTier;
    // The router picks only a new chat's first tier, and never over the
    // user's own pick (§7.2).
    if (isNew &&
        (remote == null ? pickedTier == null : remote.tier == null) &&
        !debug.dummyMode) {
      if (_utility == null) debugPrint('[gaia] router: no utility model');
      tier = await _utility?.route(topic) ?? tier;
    } else {
      debugPrint(
        '[gaia] router: skipped, '
        '${debug.dummyMode
            ? 'dummy mode'
            : !isNew
            ? 'not a new chat'
            : 'tier picked: ${(remote?.tier ?? pickedTier)!.name}'}',
      );
    }
    debugPrint('[gaia] router: sending on ${tier.name}');
    if (stopped) return;
    // Aborted, or the drain cancelled, while its images uploaded or its tier
    // was picked: no run starts.
    if (aborted || _drainCancelled) return undo('Gaia is aborted.');
    // One device runs a chat at a time (§8): another running it keeps it.
    final heldBy = await _takeLease(chatId);
    if (stopped) {
      // Not if a resend since has the chat running on the same lease.
      if (heldBy == null && !_running.contains(chatId)) {
        unawaited(_request('releaseLease', {'chatId': chatId}));
      }
      return;
    }
    // Past here a stop is the run's.
    _cancelSend.remove(chatId);
    if (heldBy != null) {
      // It waits in the chat's queue instead (§8, §13), text alone: images,
      // files, quotes and the summon's window belong to this device's draft,
      // which gets them back.
      if (!isNew &&
          images.isEmpty &&
          files.isEmpty &&
          quotes.isEmpty &&
          context == null &&
          prompt.isNotEmpty) {
        try {
          await _pipe.request('enqueue', {
            'chatId': chatId,
            'text': prompt,
            'front': fromQueue,
          });
          unawaited(_loadQueue());
          // Before undo says it didn't start, so the sender hears it's queued.
          onQueued?.call();
          undo('This chat is running on $heldBy.', false);
          _note(
            'Queued: running on $heldBy',
            'It goes once $heldBy finishes, or send it from the queue.',
          );
          return;
        } on GaiaPipeException catch (error) {
          debugPrint('[gaia] not queued: $error');
        }
      }
      if (remote == null) {
        _note(
          'Running on $heldBy',
          'This chat is running on another device. Send again once it '
              'finishes.',
          error: true,
        );
      }
      return undo('This chat is running on $heldBy.');
    }
    // After the router, so the reply's orb doesn't count it as bloom time.
    final now = utcNow();
    if (remote == null) pickedTier = null;
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
        unawaited(_request('releaseLease', {'chatId': chatId}));
        _toasts.add((
          chatId: '',
          title: "Couldn't start the chat",
          body: error.message,
          error: true,
          question: false,
        ));
        return undo(error.message);
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
    // Fixed for the run: a switch while it goes applies to the next message.
    final account = agent == null ? null : currentAccount(agent.adapter);
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
      account: script == null ? account?.id : null,
    );
    list.add(reply);
    _moveToTop(chatId, now);
    _reportRuns();
    // Sent from this desktop: the chat's no longer a phone's to hear about.
    if (remote == null) _pipe.notify('localRun', {'chatId': chatId});
    notifyListeners();
    unawaited(_persist(question));
    unawaited(_persist(reply));
    if (started != null && !started.isCompleted) started.complete(null);
    // Ready for a later handoff; this turn's agent sees the images.
    if (script == null) unawaited(_caption([question]));

    final builder = GaiaTurnBuilder();
    var session = agent == null
        ? null
        : chat.agentSessions[gaiaSessionKey(
            _deviceId,
            adapter: agent.adapter,
            account: account!.id,
          )];
    // A fork's first send here: a native session made from its source
    // chat's, which knows the chat up to the record's lastSeq
    // (GAIA_FORKING_HLD.md §5.3).
    GaiaForkRecord? fork;
    // Here at once, so a next message straight away resumes it; the main
    // instance's copy follows. A null [sessionId] drops the chat's.
    void recordSession(String adapter, String? sessionId) {
      final key = gaiaSessionKey(
        _deviceId,
        adapter: adapter,
        account: account!.id,
      );
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
          'account': account.id,
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
      ?control?.preamble,
      for (final quote in quotes) quote.preamble,
      // Empty when only files were sent.
      if (prompt.isNotEmpty) prompt,
      if (files.isNotEmpty) gaiaFilesPreamble(files),
    ].join('\n\n');
    Future<String> handedOver() async {
      if (script != null || agent == null || runner == null) return asked;
      List<GaiaMessage> unseen() => gaiaUnseenTurns(
        _messages[chatId] ?? list,
        lastSeq: session?.lastSeq ?? fork?.lastSeq ?? -1,
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
      return '${gaiaHandoffPreamble(recent: recent, joining: session == null && fork == null, summary: summary, omitted: summary == null ? older.length : 0, labels: {for (final a in agents) a.model: a.label}, older: older, files: imagePaths)}\n$asked';
    }

    var retried = false;
    String failed(Object error) {
      final text = gaiaRunErrorText('$error', account);
      return retried
          ? "This chat's earlier session wasn't found, and starting a new one "
                'failed too: $text'
          : text;
    }

    // Set once the reply is settled: a card voided as its run ends comes
    // too late to change it.
    var ended = false;
    // The reply's next save, when the last change came too soon after one.
    Timer? persistSoon;
    // The runner was handed the turn, so a stop may need it taken back.
    var runnerHeard = false;
    // A stop gave the message back (§9.6), or why its session kept it.
    var takenBack = false;
    String? keptBecause;
    // The draft's images, should the session's take-back, run once the
    // chat has stopped, give the message back.
    List<GaiaDraftImage>? takeBackCopies;
    void onEvent(GaiaAgentEvent event) {
      if (ended) return;
      // Kept as it comes, so a turn stopped later still counts. One from a
      // run on the account before a config dir change isn't this one's.
      if (event case GaiaUsageUpdate(
        usage: final turnUsage,
      ) when account != null && _usageDirs[account.key] == account.dir) {
        usage[account.key] =
            usage[account.key]?.updatedBy(turnUsage) ?? turnUsage;
        _usageCheckedAt[account.key] = DateTime.now();
        _usageChanged();
      }
      if (!builder.apply(event)) return;
      reply = _replace(
        reply,
        reply.copyWith(parts: _keepChecks(reply, builder.parts)),
        textOnly: event is GaiaTextDelta,
      );
      final last = _lastPersist[reply.id];
      // A card at once: it's what the Gaia page and other devices wait on.
      if ((event is GaiaCardUpdate && event.saveNow) ||
          last == null ||
          DateTime.now().difference(last) > _persistEvery) {
        persistSoon?.cancel();
        persistSoon = null;
        unawaited(_persist(reply));
      } else {
        // Saved once the second is up, so a change with nothing after it,
        // such as a tool's command just before a long run, isn't left
        // unsaved until the next event.
        persistSoon ??= Timer(
          _persistEvery - DateTime.now().difference(last),
          () {
            persistSoon = null;
            if (!ended) unawaited(_persist(reply));
          },
        );
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
          return await _pipe.request(
                isGaiaMemoryTool(tool) ? 'memoryTool' : 'voyagerRead',
                {'tool': tool, 'arguments': arguments, 'chatId': chatId},
              )
              as String;
        } on GaiaPipeException catch (error) {
          throw GaiaToolException(error.message);
        }
      },
      screen: (tool, arguments) async {
        try {
          final answer =
              ((await _pipe.request('osRead', {
                        'chatId': chatId,
                        'tool': tool,
                        'arguments': arguments,
                      }))!
                      as Map)
                  .cast<String, Object?>();
          return GaiaToolResult(
            text: answer['text']! as String,
            isError: false,
            image: answer['image'] as String?,
            mimeType: answer['mimeType'] as String?,
          );
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
      control: (
        plan: (cardId, tool, arguments) async {
          try {
            return ((await _pipe.request('osPlan', {
                      'chatId': chatId,
                      'cardId': cardId,
                      'tool': tool,
                      'arguments': arguments,
                    }))!
                    as Map)
                .cast<String, Object?>();
          } on GaiaPipeException catch (error) {
            throw GaiaToolException(error.message);
          }
        },
        run: (cardId, {required once}) async {
          try {
            return ((await _pipe.request('osRun', {
                      'chatId': chatId,
                      'cardId': cardId,
                      'once': once,
                    }))!
                    as Map)
                .cast<String, Object?>();
          } on GaiaPipeException catch (error) {
            throw GaiaToolException(error.message);
          }
        },
        drop: (cardId) {
          if (_pipe.connected) {
            unawaited(
              _pipe
                  .request('osDrop', {'cardId': cardId})
                  .catchError((_) => null),
            );
          }
        },
      ),
      aborted: () => aborted,
      // Asked at each CLI prompt (GAIA_AUTONOMY_HLD.md §5.7), where it counts.
      isAuto: () async {
        try {
          return await _pipe.request('isAuto', {'chatId': chatId}) == true;
        } on GaiaPipeException {
          return false;
        }
      },
      // An Auto turn's activity row changes with each step, and is saved as
      // the reply streams (§7).
      onActivity: (card) => onEvent(GaiaCardUpdate(card, saveNow: false)),
      resume: () {
        if (_pipe.connected) {
          unawaited(
            _pipe
                .request('osResume', {'chatId': chatId})
                .catchError((_) => null),
          );
        }
      },
      hold: _cardHold,
    );
    _turnTools[chatId] = tools;

    try {
      // Moved here from another account (§6.5): a copy of its newest session
      // here, caught up from there, rather than a transcript. Back on an
      // account it already has one on, it resumes that (§7.4).
      if (session == null && script == null && runner != null) {
        fork = await _forkFor(chatId, runner, account!);
        if (fork == null) {
          session = await _followSession(chatId, runner, account);
        }
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
      // Stopped while its chat was saved or its context gathered: no runner
      // had started to hear it, so it ends here, cancelled.
      if (_stopping.contains(chatId)) throw StateError('Stopped.');
      // From here a stop's turn may be in the agent's session (§9.6).
      runnerHeard = script == null && runner != null;
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
              // A resumed session keeps the index it started with, and a
              // fork its source's.
              sessionInstructions: session == null && fork == null
                  ? await _memoryIndex()
                  : '',
              account: account,
              promptId: question.id,
              fork: fork == null
                  ? null
                  : (sessionId: fork.sourceSessionId, keepAt: fork.keepAt),
              onEvent: onEvent,
            );
      // A resume that found no session, say one under another Claude config
      // folder, or a fork that couldn't be made (GAIA_FORKING_HLD.md §6):
      // once more as a new session with the chat handed over. So is a fork
      // whose first turn failed with nothing to show, as one cut from before
      // a compaction might: forking again would only fail the same way. Not
      // one stopped by a usage limit or a login, which isn't the cut's doing:
      // it keeps the record, and the next send forks again.
      if ((session != null || fork != null) &&
          (!result.sessionFound ||
              (fork != null &&
                  result.isError &&
                  builder.finished.isEmpty &&
                  !gaiaRunLimited(result.text) &&
                  !gaiaRunAuthFailed(result.text))) &&
          !_stopping.contains(chatId)) {
        // Dropped first: a retry that dies still leaves it gone. A fork's
        // falls back with nothing said.
        if (fork != null) {
          fork = null;
          _dropFork(chatId);
        } else {
          session = null;
          retried = true;
          recordSession(agent!.adapter, null);
        }
        result = await runner!.send(
          chatId: chatId,
          sessionId: null,
          model: agent!.model,
          prompt: await handedOver(),
          images: imageInputs,
          directories: directories,
          tools: tools,
          sessionInstructions: await _memoryIndex(),
          account: account,
          promptId: question.id,
          onEvent: onEvent,
        );
      }
      // An earlier take-back, or the fork, that didn't hold (§9.6).
      if (result.notice case final notice?) {
        _note(
          fork != null
              ? "This fork may not match what it shows"
              : "A stopped message wasn't fully taken back",
          notice,
          error: true,
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
      // Made: from here it's an ordinary chat's session. One that failed
      // straight away isn't kept, and the next send forks again.
      if (fork != null && keep && result.sessionId.isNotEmpty) {
        _dropFork(chatId);
      }
      ended = true;
      if (account != null && runner != null && script == null) {
        // Compared with a usage source's 401 (§6.4).
        if (!result.isError) {
          _runAuth[account.key] = GaiaRunAuth.working;
          _runWorkedAt[account.key] = DateTime.now();
          _limitHits.remove(account.key);
          _limitDismissed.remove(account.key);
        } else if (gaiaRunAuthFailed(result.text)) {
          _runAuth[account.key] = GaiaRunAuth.failing;
        } else if (gaiaRunLimited(result.text)) {
          _recordLimitHit(account);
        }
        unawaited(_readUsage(account));
      }
      // A turn can end with a call still held: Codex stops waiting on a
      // tool after about 30 s. Nothing is left to take a proposal's or a
      // permission's answer, so they're voided; a question stays open and,
      // answered later, goes as the next message.
      cards.voidAll(chatId: chatId);
      final parts = _keepChecks(reply, [
        for (final part in builder.finished)
          part is GaiaCardPart &&
                  part.isOpen &&
                  part.kind != GaiaCardKind.question
              ? part.decided(GaiaCardState.voided)
              : part,
      ]);
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
                contextWindow: result.contextWindow,
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
      // A fork whose first turn died: the next send hands the chat over
      // rather than forking again into the same failure. A stop isn't the
      // fork's doing, and keeps it; nor is a usage limit or a login.
      if (fork != null &&
          !stopped &&
          !gaiaRunLimited('$error') &&
          !gaiaRunAuthFailed('$error')) {
        _dropFork(chatId);
      }
      // Its open cards go with it: nothing is left to answer them. Before
      // anything's awaited, so a late event can't change what's decided.
      ended = true;
      // Stopped before anything showed, with nothing typed since: the
      // message goes back to the composer, once its session no longer has
      // it (§9.6). Otherwise it stays, as any stopped message does.
      if (stopped &&
          !aborted &&
          !_drainCancelled &&
          remote == null &&
          builder.finished.isEmpty &&
          _draftEmpty(chatId)) {
        final copies = await _draftCopies(images, imageInputs);
        if (copies != null && runnerHeard && session != null) {
          // Once the run has ended: a stop doesn't wait on it.
          takeBackCopies = copies;
        } else if (copies != null && _draftEmpty(chatId)) {
          imagesBack = copies;
          takenBack = true;
        } else {
          copies?.forEach((image) => unawaited(_deleteQuietly(image.path)));
        }
      }
      if (account != null && script == null) {
        if (gaiaRunLimited('$error')) {
          _recordLimitHit(account);
        } else if (gaiaRunAuthFailed('$error')) {
          // Compared with a usage source's 401 (§6.4).
          _runAuth[account.key] = GaiaRunAuth.failing;
          unawaited(_readUsage(account));
        }
      }
      cards.voidAll(chatId: chatId);
      reply = _replace(
        reply,
        reply.copyWith(
          parts: _keepChecks(reply, [
            for (final part in builder.finished)
              part is GaiaCardPart && part.isOpen
                  ? part.decided(GaiaCardState.voided)
                  : part,
          ]),
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
      _turnTools.remove(chatId);
      persistSoon?.cancel();
      _lastPersist.remove(reply.id);
      _reportRuns();
      notifyListeners();
    }
    if (takeBackCopies case final copies?) {
      final done = Completer<void>();
      _takingBack[chatId] = done.future;
      String? why;
      try {
        why = await runner!.takeBack(chatId);
      } catch (error) {
        why = '$error';
      } finally {
        _takingBack.remove(chatId);
        done.complete();
      }
      final superseded = _takeBackSuperseded.remove(chatId);
      if (why == null && !superseded && _draftEmpty(chatId)) {
        imagesBack = copies;
        takenBack = true;
      } else {
        // Typed or sent since: it stays, though the session no longer has it.
        keptBecause =
            why ??
            "Something was typed or sent since, so it wasn't put back in the "
                "draft. The agent's session no longer has it.";
        for (final image in copies) {
          unawaited(_deleteQuietly(image.path));
        }
      }
    }
    if (takenBack) {
      // Off the chat everywhere, and a new chat with it; back in the draft.
      list.removeWhere((message) => message.id == reply.id);
      unawaited(
        _request('takeBack', {
          'messages': [question.toJson(), reply.toJson()],
          'chat': isNew,
        }),
      );
      undo('Stopped.');
      return notifyListeners();
    }
    await _persist(reply);
    if (keptBecause case final why?) {
      _note('The stopped message stays in the chat', why, error: true);
    }
    _reportDone(chatId, reply);
    if (reply.status == GaiaMessageStatus.complete &&
        !debug.dummyMode &&
        _awaitsTitle(chatId, reply)) {
      unawaited(_retitle(chatId, topic, reply.text));
    }
    if (reply.status == GaiaMessageStatus.complete &&
        script == null &&
        !debug.dummyMode) {
      _curateLater(chatId, _curateAfter);
    }
    _settleDrain();
    _drainNext(chatId, reply);
  }

  /// Copies [chatId]'s newest session on another of [to]'s adapter's accounts
  /// into [to]; the session to resume, or null when there's none to follow,
  /// and the chat is handed over to a new one (§7.4).
  Future<GaiaAgentSession?> _followSession(
    String chatId,
    GaiaAgentRunner runner,
    GaiaAccount to,
  ) async {
    final chat = _chat(chatId);
    if (chat == null || runner is! GaiaSessionCopier) return null;
    GaiaAccount? from;
    GaiaAgentSession? newest;
    for (final account in accountsFor(to.adapter)) {
      final session =
          chat.agentSessions[gaiaSessionKey(
            _deviceId,
            adapter: to.adapter,
            account: account.id,
          )];
      if (session != null &&
          account.id != to.id &&
          (newest == null || session.lastSeq > newest.lastSeq)) {
        from = account;
        newest = session;
      }
    }
    if (from == null || newest == null) return null;
    try {
      final copied = await (runner as GaiaSessionCopier).copySession(
        sessionId: newest.sessionId,
        from: from,
        to: to,
      );
      return copied ? newest : null;
    } on FileSystemException catch (error) {
      debugPrint('[gaia] session not copied to ${to.label}: $error');
      return null;
    }
  }

  /// Curates [chatId] after [wait], in place of any wait it had.
  void _curateLater(String chatId, Duration wait) {
    _curateSoon.remove(chatId)?.cancel();
    late final Timer timer;
    timer = Timer(wait, () {
      if (_curateSoon[chatId] == timer) _curateSoon.remove(chatId);
      unawaited(_curate(chatId));
    });
    _curateSoon[chatId] = timer;
  }

  /// This device's last turn in [chat] when it ran the chat's last turn,
  /// which stands in for the run lease (§11); null when another device did.
  int? _ranLast(GaiaChat chat) {
    var last = -1;
    var mine = -1;
    for (final MapEntry(:key, :value) in chat.agentSessions.entries) {
      last = max(last, value.lastSeq);
      if (key.startsWith('$_deviceId/')) mine = max(mine, value.lastSeq);
    }
    return mine < last ? null : mine;
  }

  /// Chats this device ran last whose newest turns the curator hasn't read,
  /// their wait cut short by a quit (§11): each is curated once the rest of
  /// its wait has passed, those already due one at a time.
  Future<void> _curateMissed() async {
    if (debug.dummyMode) return;
    final now = DateTime.now();
    final due = <String>[];
    for (final chat in chats) {
      final idle = now.difference(chat.lastMessageAt);
      if (idle > kGaiaCurateMissedWithin || _curateSoon.containsKey(chat.id)) {
        continue;
      }
      final mine = _ranLast(chat);
      if (mine == null || mine <= chat.curatedSeq) continue;
      if (idle < _curateAfter) {
        _curateLater(chat.id, _curateAfter - idle);
      } else {
        due.add(chat.id);
      }
    }
    for (final chatId in due) {
      await _curate(chatId);
    }
  }

  /// The memory index for a new session (§11): the active memories as
  /// they are now, which the session keeps; a memory saved later is
  /// reached through `memory_search`. Empty when the main instance can't
  /// say.
  Future<String> _memoryIndex() async {
    try {
      return await _pipe.request('memoryIndex') as String? ?? '';
    } on GaiaPipeException catch (error) {
      debugPrint('[gaia] memory index: $error');
      return '';
    }
  }

  /// The memory curator (§11): the utility model reads [chatId]'s turns
  /// since it last did, and what it finds goes to the inbox, or straight in
  /// with auto-accept on. Only the device that ran the chat's last turn
  /// curates it, so two never propose the same. A failure leaves the turns
  /// for next time.
  Future<void> _curate(String chatId) async {
    final utility = _utility;
    // A chat deleted while it waited is left alone, and one another device
    // went on with is its to curate.
    final chat = _chat(chatId);
    if (utility == null ||
        chat == null ||
        _ranLast(chat) == null ||
        aborted ||
        _running.contains(chatId)) {
      return;
    }
    final from = chat.curatedSeq;
    final List<GaiaMessage> turns;
    final String index;
    try {
      final listed =
          (await _pipe.request('messages', {'chatId': chatId}))! as List;
      turns = [
        for (final json in listed)
          if (GaiaMessage.fromJson((json as Map).cast<String, Object?>())
              case final message
              when message.seq > from &&
                  message.status != GaiaMessageStatus.streaming)
            message,
      ];
      if (turns.isEmpty) return;
      index = await _pipe.request('memoryIndex') as String? ?? '';
    } on GaiaPipeException catch (error) {
      debugPrint('[gaia] curator: $error');
      return;
    }
    final found = await utility.curate(gaiaTranscriptText(turns), index);
    // Sent again meanwhile: its next idle reads these turns too.
    if (found == null || _running.contains(chatId)) return;
    final seq = turns.last.seq;
    debugPrint('[gaia] curator: ${found.length} from $chatId up to $seq');
    try {
      await _pipe.request('curated', {
        'chatId': chatId,
        'seq': seq,
        'memories': [
          for (final memory in found)
            {'text': memory.text, 'tags': memory.tags},
        ],
      });
    } on GaiaPipeException catch (error) {
      // Not marked read: the next idle reads these turns again.
      debugPrint('[gaia] curator: $error');
      return;
    }
    chats = [
      for (final c in chats)
        c.id == chatId && c.curatedSeq < seq ? c.copyWith(curatedSeq: seq) : c,
    ];
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

  /// Whether [chatId]'s composer is empty: a stopped message given back
  /// (§9.6) mustn't land over what's been typed since.
  bool _draftEmpty(String chatId) {
    if (chatId == currentChatId) {
      return draft.text.isEmpty && draftImages.isEmpty && draftFiles.isEmpty;
    }
    final had = _drafts[_keyOf(chatId)];
    return had == null ||
        (had.text.text.isEmpty && had.images.isEmpty && had.files.isEmpty);
  }

  /// A sent message's [images] again for the draft, under their draft
  /// labels: copies of the stored files [sent] went as, edits applied, since
  /// the draft's own were deleted once sent. Null when one can't be copied.
  Future<List<GaiaDraftImage>?> _draftCopies(
    List<GaiaDraftImage> images,
    List<GaiaImageInput> sent,
  ) async {
    final copies = <GaiaDraftImage>[];
    try {
      for (final (i, image) in images.indexed) {
        final copy = p.join(_draftDirectory, '${_uuid.v4()}.img');
        await Directory(_draftDirectory).create(recursive: true);
        await File(sent[i].path).copy(copy);
        copies.add(GaiaDraftImage(label: image.label, path: copy));
      }
      return copies;
    } on FileSystemException catch (error) {
      debugPrint('[gaia] stopped message kept, an image is gone: $error');
      for (final copied in copies) {
        unawaited(_deleteQuietly(copied.path));
      }
      return null;
    }
  }

  /// Takes [chatId]'s run lease (§8) through the main instance: null when
  /// this device may run it, else the name of the one running it. A main
  /// instance that can't say lets the run go ahead.
  Future<String?> _takeLease(String chatId) async {
    try {
      final reply = await _pipe.request('takeLease', {'chatId': chatId});
      return (reply as Map?)?['heldBy'] as String?;
    } on GaiaPipeException catch (error) {
      debugPrint('[gaia] lease not checked: $error');
      return null;
    }
  }

  /// A command from a paired device (§12.2), verified and claimed by the
  /// main instance. Throws a [GaiaPipeException] saying why it can't run.
  Future<Object?> _onRemote(Map<String, Object?> params) async {
    final chatId = params['chatId'] as String?;
    final payload =
        (params['payload'] as Map?)?.cast<String, Object?>() ??
        const <String, Object?>{};
    switch (params['type']) {
      case 'prompt':
        final text = payload['text'] as String? ?? '';
        if (chatId == null) throw GaiaPipeException('No chat given.');
        var queued = false;
        final why = await _sendRemote(
          text,
          chatId: chatId,
          tier: gaiaTierFromName(payload['tier']),
          onQueued: () => queued = true,
        );
        if (why != null && !queued) throw GaiaPipeException(why);
        return queued ? {'queued': true} : {'started': true};
      case 'queuePop':
        if (chatId == null || _running.contains(chatId)) {
          throw GaiaPipeException('That chat is running; it goes next.');
        }
        final popped = await _pipe.request('queuePop', {'chatId': chatId});
        if (popped is! Map) throw GaiaPipeException('Nothing is queued.');
        unawaited(_loadQueue());
        final item = GaiaQueueItem.fromJson(popped.cast());
        if (await _sendPopped(item, chatId) case final why?) {
          throw GaiaPipeException(why);
        }
        return {'started': true};
      case 'answer':
        return _remoteAnswer(chatId, payload);
      case 'cancel':
        if (chatId == null || !_running.contains(chatId)) {
          throw GaiaPipeException('Nothing is running in that chat.');
        }
        await stop(chatId);
        return null;
      default:
        throw GaiaPipeException('Unknown command ${params['type']}.');
    }
  }

  /// A card answered on the phone (§12.2): as its own buttons would. A
  /// proposal is accepted as proposed: the phone has no editor.
  Future<Object?> _remoteAnswer(
    String? chatId,
    Map<String, Object?> payload,
  ) async {
    final cardId = payload['cardId'] as String?;
    if (chatId != null && !_messages.containsKey(chatId)) await _load(chatId);
    final card = [
      for (final message in _messages[chatId] ?? const <GaiaMessage>[])
        ...message.parts.whereType<GaiaCardPart>(),
    ].where((card) => card.id == cardId).firstOrNull;
    if (card == null || !card.isOpen) {
      throw GaiaPipeException('That card was already decided.');
    }
    final text = payload['text'] as String? ?? '';
    if (payload['decision'] == 'reject') {
      rejectCard(card, message: text);
      return null;
    }
    switch (card.kind) {
      case GaiaCardKind.question:
        final selected = {
          ...((payload['selected'] as List?) ?? const []).cast<String>(),
        };
        _cardPicks[card.id] = {
          for (final (i, option) in card.options.indexed)
            if (selected.contains(option.label)) i,
        };
        if (!await answerCard(card, text: text, remoteChat: chatId)) {
          throw GaiaPipeException('Pick an option or write an answer.');
        }
      case GaiaCardKind.permission:
        if (!cards.isWaiting(card.id)) {
          throw GaiaPipeException('That request is no longer waiting.');
        }
        allowCard(card);
      case GaiaCardKind.proposal:
        if (!acceptProposal(card)) {
          throw GaiaPipeException(
            gaiaProposalProblem(card.proposal!, proposalFields(card)) ??
                'That proposal is no longer waiting.',
          );
        }
      case GaiaCardKind.control:
        // The phone can say no. Yes takes someone at this screen, who can see
        // the border and press Esc (§15.6).
        throw GaiaPipeException(
          'Real input on this desktop is approved at the desktop.',
        );
    }
    return null;
  }

  Future<void> stop(String chatId, {String? why}) async {
    if (_cancelSend.remove(chatId) case final cancel?) return cancel();
    if (!_running.contains(chatId)) return;
    _stopping.add(chatId);
    if (why != null) _turnTools[chatId]?.logStopped(why);
    cards.voidAll(chatId: chatId);
    if (_pipe.connected) {
      unawaited(
        _pipe.request('osStop', {'chatId': chatId}).catchError((_) => null),
      );
    }
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
      case GaiaCardKind.control:
        title = 'Gaia asks to control the screen';
        body = '${card.input['window'] ?? ''}';
    }
    _toast(
      chatId,
      title,
      body.length > 120 ? '${body.substring(0, 120)}…' : body,
      question: true,
    );
    unawaited(_attend(chatId));
  }

  /// A card opened in [chatId] while the user is in another app: Gaia comes
  /// up on that chat, in front of the app, but without the focus, so the
  /// keys they're typing never land on the card. Hidden, it comes up as the
  /// small floater. Not over a crop or the pick-up pill, nor away from
  /// another chat in view that's running: its toast is enough.
  Future<void> _attend(String chatId) async {
    // Checked again once the chat has loaded: the user may have moved.
    bool away() =>
        !_window.foreground &&
        cropping == null &&
        !_pickingUp &&
        _window.shown != GaiaMode.overlay &&
        _window.shown != GaiaMode.pickUp;
    if (!away()) return;
    if (chatId != currentChatId) {
      if (currentRunning) return;
      await selectChat(chatId);
      if (!away()) return;
    }
    if (_window.shown == null) return _show(GaiaMode.small, activate: false);
    _window.attend();
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
    _newChatSeesScreen = false;
    _newChatCanControl = false;
    seeScreenWarning = false;
    _dropPointed();
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

  /// The main instance's order: pinned first, then the most recent.
  static int _listed(GaiaChat a, GaiaChat b) {
    if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
    final recent = b.lastMessageAt.compareTo(a.lastMessageAt);
    return recent != 0 ? recent : a.id.compareTo(b.id);
  }

  /// To the top of its own kind: an unpinned chat stays below the pinned.
  void _moveToTop(String chatId, DateTime at) {
    chats = [
      for (final c in chats) c.id == chatId ? c.copyWith(lastMessageAt: at) : c,
    ]..sort(_listed);
  }

  /// Swaps [updated] in for [old] in its chat's list, and redraws.
  /// [textOnly]: only its text changed, which [streamed] tells.
  GaiaMessage _replace(
    GaiaMessage old,
    GaiaMessage updated, {
    bool textOnly = false,
  }) {
    final list = _messages[old.chatId];
    final index = list?.indexWhere((m) => m.id == old.id) ?? -1;
    if (index >= 0) list![index] = updated;
    if (textOnly) {
      // Only the shown chat's messages are drawn.
      if (old.chatId == currentChatId) streamed.value++;
    } else {
      notifyListeners();
    }
    return updated;
  }

  /// A streaming reply's [parts] as its run rebuilt them, with the ticks
  /// the user has made on it meanwhile ([toggleCheck]), part by part.
  List<GaiaPart> _keepChecks(GaiaMessage reply, List<GaiaPart> parts) =>
      gaiaKeepChecks(parts, gaiaChecksOf(_shown(reply)?.parts ?? const []));

  /// [message] as it's shown now.
  GaiaMessage? _shown(GaiaMessage message) =>
      _messages[message.chatId]?.where((m) => m.id == message.id).firstOrNull;

  /// Ticks or unticks task [task] in [message]'s text part [part], and
  /// saves it: shown only, never sent to Gaia. Shown at once; stored by the
  /// main instance, whose ticks a streaming reply's writes keep. Sent as
  /// the state it's shown in, not a flip, so a tick from the Gaia page this
  /// hasn't taken up yet isn't undone; shown back as it was if not saved.
  Future<void> toggleCheck(GaiaMessage message, int part, int task) async {
    final current = _shown(message);
    if (current?.parts.elementAtOrNull(part) case final GaiaTextPart text?) {
      final flipped = !text.checks.contains(task);
      _replace(
        current!,
        current.copyWith(
          parts: gaiaWithCheck(current.parts, part, task, flipped),
        ),
      );
      final turn = _checkTurns[message.id] = (_checkTurns[message.id] ?? 0) + 1;
      try {
        final stored = await _pipe.request('toggleCheck', {
          'messageId': message.id,
          'part': part,
          'task': task,
          'flipped': flipped,
        });
        if (_checkTurns[message.id] == turn) _adoptChecks(message, stored);
      } on GaiaPipeException catch (error) {
        debugPrint('[gaia] tick not saved: $error');
        final shown = _shown(message);
        if (_checkTurns[message.id] == turn && shown != null) {
          _replace(
            shown,
            shown.copyWith(
              parts: gaiaWithCheck(shown.parts, part, task, !flipped),
            ),
          );
        }
      }
    }
  }

  /// Ticks sent to the main instance, by message id: what a write gives
  /// back is taken up only if no tick went after it ([_adoptChecks]).
  final _checkTurns = <String, int>{};

  /// [message] shown with the ticks the main instance has [stored] for it,
  /// as [gaiaChecksToJson] made them: the Gaia page's among them.
  void _adoptChecks(GaiaMessage message, Object? stored) {
    final current = _shown(message);
    if (stored == null || current == null) return;
    final parts = gaiaKeepChecks(current.parts, gaiaChecksFromJson(stored));
    final was = gaiaChecksOf(current.parts);
    final now = gaiaChecksOf(parts);
    if ([
      for (var i = 0; i < was.length; i++) i,
    ].every((i) => setEquals(was[i], now[i]))) {
      return;
    }
    _replace(
      current,
      current.copyWith(parts: parts, bumpVersion: false, touch: false),
      textOnly: true,
    );
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

  /// A new chat's title until the utility model gives it one (§5.1). Its
  /// images' tokens are in it; its files aren't.
  String _firstLineTitle(
    String prompt,
    List<GaiaFilePart> files,
    List<GaiaQuotePart> quotes,
  ) {
    final firstLine = prompt.isNotEmpty
        ? prompt.split('\n').first
        : files.isNotEmpty
        ? p.basename(files.first.path)
        : quotes.first.text.trim().split('\n').first;
    return firstLine.length > 60 ? '${firstLine.substring(0, 60)}…' : firstLine;
  }

  /// Whether [reply] is the chat's first to finish, a failed or stopped one
  /// before it not counting, with the title still the first message's first
  /// line: any other title is the user's own name for it.
  bool _awaitsTitle(String chatId, GaiaMessage reply) {
    final list = _messages[chatId];
    if (list == null) return false;
    final answered = list.any(
      (message) =>
          message.role == GaiaMessageRole.assistant &&
          message.seq < reply.seq &&
          message.status == GaiaMessageStatus.complete,
    );
    if (answered) return false;
    final first = list.first;
    return _chat(chatId)?.title ==
        _firstLineTitle(
          first.text,
          first.parts.whereType<GaiaFilePart>().toList(),
          first.parts.whereType<GaiaQuotePart>().toList(),
        );
  }

  /// The utility model's title for a chat's first answered exchange, over the
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
    final turn = _checkTurns[message.id];
    try {
      final stored = await _pipe.request('putMessage', {
        'message': message.toJson(),
      });
      if (_checkTurns[message.id] == turn) _adoptChecks(message, stored);
    } on GaiaPipeException catch (error) {
      debugPrint('[gaia] message not saved: $error');
    }
  }
}
