import 'package:flutter/material.dart';
import 'package:segno/common/console_mode.dart';
import 'package:segno/common/on_screen_keyboard/on_screen_keyboard.dart';

/// Wraps the app and supplies an on-screen keyboard whenever a text field takes
/// focus on a build that has no physical one.
///
/// The console runs weston's `kiosk-shell`, which — unlike `desktop-shell` —
/// spawns no input panel, and the image ships no IME. So every `TextField` in
/// the app (renaming a track, naming a session, a Wi-Fi password) is dead on
/// that hardware unless the app draws its own keys.
///
/// It watches focus rather than wrapping fields, so no call site changes and
/// every future field is covered for free.
///
/// The keyboard's height is reported back through [MediaQuery]'s
/// `viewInsets.bottom` — the same channel a real soft keyboard uses. Every
/// `Scaffold`, `AlertDialog` and scroll view already knows how to get out of
/// the way of that, so existing layouts avoid the keyboard without being
/// touched.
class OnScreenKeyboardHost extends StatefulWidget {
  /// Creates an [OnScreenKeyboardHost] around [child].
  const OnScreenKeyboardHost({
    required this.child,
    this.enabled = kConsoleMode,
    super.key,
  });

  /// The app below the keyboard.
  final Widget child;

  /// Whether to supply a keyboard at all. Defaults to [kConsoleMode]: desktop
  /// builds have a real keyboard, and drawing a second one would be noise.
  final bool enabled;

  @override
  State<OnScreenKeyboardHost> createState() => _OnScreenKeyboardHostState();
}

class _OnScreenKeyboardHostState extends State<OnScreenKeyboardHost> {
  EditableText? _field;

  @override
  void initState() {
    super.initState();
    if (widget.enabled) FocusManager.instance.addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    if (widget.enabled) FocusManager.instance.removeListener(_onFocusChanged);
    super.dispose();
  }

  void _onFocusChanged() {
    final next = _focusedEditable();
    // STICKY. Only a different field replaces the current one; focus merely
    // leaving does not clear it.
    //
    // Pressing a key moves focus off the field for an instant — the keys are
    // ordinary buttons, and neither TextFieldTapRegion nor a non-focusable
    // Focus wrapper reliably prevents it. Clearing on focus loss therefore
    // destroys the target between the press and the callback, and every
    // keystroke lands on nothing.
    //
    // It is also the better behaviour here: a keyboard that vanishes halfway
    // through a Wi-Fi password because a stray tap moved focus is worse than
    // one that waits to be dismissed. [_done] is the way out.
    if (next == null) return;
    // Compared by CONTROLLER, not by widget instance: the EditableText widget
    // is rebuilt constantly, so comparing widgets would rebuild every frame.
    // The controller is what identifies where a keystroke lands.
    if (next.controller == _field?.controller &&
        next.readOnly == _field?.readOnly) {
      return;
    }
    setState(() => _field = next);
  }

  /// The [EditableText] the primary focus sits inside, or `null` when focus is
  /// somewhere that does not take text.
  ///
  /// Walks UP. A `TextField` gives its focus node to a `Focus` widget that
  /// `EditableText` builds BELOW itself, so the focused context is a
  /// descendant of the field, never the field and never above it (verified
  /// against the framework rather than assumed).
  ///
  /// Upwards-only also makes dismissal correct for free: once focus returns to
  /// a scope, nothing above it is an `EditableText`, so the keyboard closes
  /// instead of latching onto some unrelated field elsewhere in the tree.
  EditableText? _focusedEditable() {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context is! Element || !context.mounted) return null;

    final self = context.widget;
    if (self is EditableText) return self;

    EditableText? found;
    context.visitAncestorElements((element) {
      if (element.widget is EditableText) {
        found = element.widget as EditableText;
        return false;
      }
      return true;
    });
    return found;
  }

  bool get _readOnly => _field?.readOnly ?? false;

  TextEditingController? get _controller =>
      _readOnly ? null : _field?.controller;

  /// Replaces the current selection with [text].
  ///
  /// Goes through the controller rather than synthesising key events so the
  /// field's own `inputFormatters` and `onChanged` still run — a numeric field
  /// must reject letters the same way it would from a USB keyboard.
  void _insert(String text) {
    final controller = _controller;
    if (controller == null) return;
    final value = controller.value;
    final selection = value.selection;
    // A field that has never been touched reports an invalid selection;
    // appending is the only sane reading of "type here" in that state.
    final start = selection.isValid ? selection.start : value.text.length;
    final end = selection.isValid ? selection.end : value.text.length;
    controller.value = value.copyWith(
      text: value.text.replaceRange(start, end, text),
      selection: TextSelection.collapsed(offset: start + text.length),
      composing: TextRange.empty,
    );
  }

  void _backspace() {
    final controller = _controller;
    if (controller == null) return;
    final value = controller.value;
    final selection = value.selection;
    final end = selection.isValid ? selection.end : value.text.length;
    final start = selection.isValid && !selection.isCollapsed
        ? selection.start
        : end - 1;
    if (end <= 0 || start < 0) return;
    controller.value = value.copyWith(
      text: value.text.replaceRange(start, end, ''),
      selection: TextSelection.collapsed(offset: start),
      composing: TextRange.empty,
    );
  }

  void _done() {
    // The explicit way out, since the field is sticky. Unfocus first so the
    // field's own submit/validation paths (which hang off losing focus) run,
    // then drop the reference that keeps the keyboard on screen.
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _field = null);
  }

  @override
  Widget build(BuildContext context) {
    final field = _field;
    final open = widget.enabled && field != null && !_readOnly;
    if (!open) return widget.child;

    final layout = layoutForInputType(field.keyboardType);
    // Five rows of 54px keys plus 3px padding either side, plus the panel's
    // own 6px inset. Sized from the keys rather than guessed, so a key-height
    // change cannot silently overflow the panel.
    final rows = layout == OnScreenKeyboardLayout.numeric ? 5 : 4;
    final height = rows * (OnScreenKeyboard.keyHeight + 6) + 12;
    final media = MediaQuery.of(context);

    return Column(
      children: [
        Expanded(
          child: MediaQuery(
            // Report the keyboard the way the platform would, so every
            // Scaffold/dialog/scroll view already in the app moves out of its
            // way with no change at the call site.
            data: media.copyWith(
              viewInsets: media.viewInsets.copyWith(bottom: height),
            ),
            child: widget.child,
          ),
        ),
        // The keyboard must never take focus. A real soft keyboard is an OS
        // panel and cannot; these are ordinary buttons and will, which pulls
        // focus off the field between the press and the callback — so the
        // keystroke arrives with nothing to type into.
        //
        // TextFieldTapRegion additionally stops the tap reading as "outside
        // the field", which is what would otherwise dismiss the editing
        // session on the first key.
        TextFieldTapRegion(
          child: Focus(
            canRequestFocus: false,
            descendantsAreFocusable: false,
            skipTraversal: true,
            child: Material(
              key: const Key('onScreenKeyboard'),
              elevation: 8,
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: SafeArea(
                top: false,
                child: SizedBox(
                  height: height,
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: OnScreenKeyboard(
                      layout: layout,
                      onKey: _insert,
                      onBackspace: _backspace,
                      onDone: _done,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
