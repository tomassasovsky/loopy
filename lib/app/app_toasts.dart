import 'package:flutter/material.dart';
import 'package:toastification/toastification.dart';

/// Stable toast ids used by the app shell (and widget tests).
abstract final class AppToastId {
  static const deviceLost = 'app_deviceLost_banner';
  static const deviceRestored = 'app_deviceRestored_snackbar';
  static const midiLost = 'app_midiLost_banner';
  static const midiRestored = 'app_midiRestored_snackbar';
  static const audioRecovery = 'app_audioRecovery_banner';
  static const update = 'app_update_banner';
  static const updateDismiss = 'app_update_banner_dismiss';
  static const updateAction = 'app_update_banner_update';
  static const waveformFailed = 'app_waveformWindowFailed_banner';
  static const singleDisplay = 'app_singleDisplay_banner';
}

final Map<String, ToastificationItem> _active = {};

/// Dismisses a previously shown app toast, if any.
/// Forgets every live toast without animating them out.
///
/// The registry below is module-level, so it survives between widget tests:
/// one test showing a toast makes the next test's identical toast a duplicate
/// and silently a no-op. Reset it in `setUp`.
@visibleForTesting
void resetAppToastsForTest() => _active.clear();

void dismissAppToast(String id) {
  final item = _active.remove(id);
  if (item != null) {
    toastification.dismiss(item);
  }
}

/// Shows a persistent (manual-dismiss) toast with optional trailing actions.
ToastificationItem showAppToast({
  required String id,
  required Widget title,
  Widget? description,
  Widget? icon,
  ToastificationType type = ToastificationType.info,
  List<Widget> actions = const [],
  Duration? autoCloseDuration,
}) {
  dismissAppToast(id);
  final item = toastification.showCustom(
    alignment: Alignment.topCenter,
    autoCloseDuration: autoCloseDuration,
    builder: (context, holder) {
      final theme = Theme.of(context);
      final scheme = theme.colorScheme;
      return KeyedSubtree(
        key: Key(id),
        child: Container(
          margin: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          constraints: const BoxConstraints(maxWidth: 520),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: scheme.outlineVariant),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.35),
                blurRadius: 18,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            children: [
              if (icon != null) ...[
                IconTheme(
                  data: IconThemeData(color: _accent(type, scheme), size: 22),
                  child: icon,
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: DefaultTextStyle(
                  style: theme.textTheme.bodyMedium!.copyWith(
                    color: scheme.onSurface,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      DefaultTextStyle.merge(
                        style: const TextStyle(fontWeight: FontWeight.w600),
                        child: title,
                      ),
                      if (description != null) ...[
                        const SizedBox(height: 2),
                        DefaultTextStyle.merge(
                          style: TextStyle(
                            color: scheme.onSurfaceVariant,
                            fontWeight: FontWeight.w400,
                          ),
                          child: description,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              ...actions.map(
                (action) => Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: action,
                ),
              ),
              IconButton(
                tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                onPressed: () {
                  dismissAppToast(id);
                  toastification.dismiss(holder);
                },
                icon: const Icon(Icons.close_rounded, size: 20),
              ),
            ],
          ),
        ),
      );
    },
  );
  _active[id] = item;
  return item;
}

/// Short-lived status toast (e.g. "reconnected").
void showAppSnackToast({
  required String id,
  required Widget title,
  Widget? icon,
  ToastificationType type = ToastificationType.success,
  Duration autoCloseDuration = const Duration(seconds: 3),
}) {
  showAppToast(
    id: id,
    title: title,
    icon: icon,
    type: type,
    autoCloseDuration: autoCloseDuration,
  );
}

Color _accent(ToastificationType type, ColorScheme scheme) {
  if (type == ToastificationType.success) return scheme.primary;
  if (type == ToastificationType.error) return scheme.error;
  if (type == ToastificationType.warning) return scheme.tertiary;
  return scheme.secondary;
}
