import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:settings_repository/settings_repository.dart';
import 'package:update_repository/update_repository.dart';

part 'update_state.dart';

/// Drives the opt-in update UX: a passive read-only availability check that
/// powers the startup notification, plus the user-triggered download/stage and
/// apply. Nothing downloads or installs without an explicit call to
/// [startDownload] / [applyAndRestart]; only [check] runs automatically (and
/// only when [UpdateState.autoCheck] is on).
class UpdateCubit extends Cubit<UpdateState> {
  /// Creates an [UpdateCubit]. Off until [load] restores preferences and (when
  /// auto-check is on) runs the first check.
  UpdateCubit({
    required UpdateRepository updates,
    required SettingsRepository settings,
  }) : _updates = updates,
       _settings = settings,
       super(const UpdateState());

  final UpdateRepository _updates;
  final SettingsRepository _settings;
  Future<void>? _loadFuture;

  /// Restores persisted preferences and, if auto-check is enabled and the
  /// platform is supported, runs the first read-only check. Idempotent.
  Future<void> load() => _loadFuture ??= _restore();

  Future<void> _restore() async {
    final autoCheck = await _settings.loadUpdateAutoCheck();
    final dismissed = await _settings.loadDismissedUpdateVersions();
    final savedChannel = await _settings.loadUpdateChannel();
    if (savedChannel != null) {
      await _updates.setChannel(savedChannel);
    }
    final current = await _updates.currentVersion();
    if (isClosed) return;
    emit(
      state.copyWith(
        supported: _updates.isSupported,
        channel: _updates.channel,
        currentVersion: current,
        autoCheck: autoCheck,
        dismissed: dismissed,
      ),
    );
    if (autoCheck && _updates.isSupported) await check();
  }

  /// Runs a read-only availability check (no download, no install). No-op on an
  /// unsupported platform.
  Future<void> check() async {
    if (!_updates.isSupported) return;
    emit(state.copyWith(phase: UpdatePhase.checking, clearError: true));
    try {
      final manifest = await _updates.checkForUpdate();
      if (isClosed) return;
      if (manifest != null) {
        emit(
          state.copyWith(phase: UpdatePhase.available, available: manifest),
        );
        return;
      }
      // Nothing newer to download — but a prior stage may still be waiting for
      // "Restart to apply" (staged > current after reconcile clears rollbacks).
      final current = await _updates.currentVersion();
      final staged = await _updates.stagedVersion();
      if (isClosed) return;
      if (staged > current) {
        emit(
          state.copyWith(
            phase: UpdatePhase.staged,
            available: UpdateManifest(
              version: staged,
              bundle: '',
              sha256: '',
              channel: _updates.channel,
            ),
            currentVersion: current,
          ),
        );
        return;
      }
      emit(
        state.copyWith(
          phase: UpdatePhase.upToDate,
          clearAvailable: true,
          currentVersion: current,
        ),
      );
    } on Object catch (error) {
      if (!isClosed) {
        emit(state.copyWith(phase: UpdatePhase.error, errorMessage: '$error'));
      }
    }
  }

  /// Downloads and stages the available bundle to the inactive slot, tracking
  /// progress. Opt-in — call only from an explicit user action. No-op when no
  /// update is available.
  Future<void> startDownload() async {
    final manifest = state.available;
    if (manifest == null) return;
    emit(
      state.copyWith(
        phase: UpdatePhase.downloading,
        progress: 0,
        clearError: true,
      ),
    );
    try {
      await for (final progress in _updates.downloadAndStage(manifest)) {
        if (isClosed) return;
        emit(state.copyWith(progress: progress.clamp(0.0, 1.0)));
      }
      if (!isClosed) {
        emit(state.copyWith(phase: UpdatePhase.staged, progress: 1));
      }
    } on Object catch (error) {
      if (!isClosed) {
        emit(state.copyWith(phase: UpdatePhase.error, errorMessage: '$error'));
      }
    }
  }

  /// Restarts into the staged update (reboot on the appliance, relaunch on
  /// desktop). Opt-in — call only from an explicit user action.
  Future<void> applyAndRestart() => _updates.applyAndRestart();

  /// Records that the user dismissed the notification for [version], so it will
  /// not be shown again until a newer version appears.
  Future<void> dismiss(Version version) async {
    if (state.dismissed.contains(version)) return;
    final next = {...state.dismissed, version};
    emit(state.copyWith(dismissed: next));
    await _settings.saveDismissedUpdateVersions(next);
  }

  /// Sets and persists whether the passive check runs automatically.
  Future<void> setAutoCheck({required bool value}) async {
    if (value != state.autoCheck) emit(state.copyWith(autoCheck: value));
    await _settings.saveUpdateAutoCheck(value: value);
  }

  /// Switches between the experimental and production update channels.
  /// Persists the choice, writes the appliance override the OTA helper reads,
  /// clears any in-flight offer from the previous channel, and re-checks.
  /// No-op while a download is in progress.
  Future<void> setExperimentalChannel({required bool value}) async {
    if (state.phase == UpdatePhase.downloading) return;
    final channel = value ? 'experimental' : 'production';
    if (channel == state.channel) return;
    await _updates.setChannel(channel);
    await _settings.saveUpdateChannel(channel);
    if (isClosed) return;
    emit(
      state.copyWith(
        channel: channel,
        phase: UpdatePhase.idle,
        clearAvailable: true,
        clearError: true,
      ),
    );
    if (_updates.isSupported) await check();
  }
}
