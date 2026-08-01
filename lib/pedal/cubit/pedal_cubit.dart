import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:settings_repository/settings_repository.dart';

part 'pedal_state.dart';

/// The pedal LINK feature: binds the MIDI output device, keeps it bound
/// across hotplugs, and surfaces the picker state ([PedalState]) for the
/// settings UI. Nothing else.
///
/// The pedal's BEHAVIOR — decoding footswitch events into intents and
/// pushing projected LED frames — is `ControlCubit`'s job: both cubits sit
/// on the shared [PedalRepository] (events in / frames out for control,
/// binding for this one) and know nothing about each other.
class PedalCubit extends Cubit<PedalState> {
  /// Creates a [PedalCubit].
  ///
  /// [autoBindProductName] enables console auto-detect for the LED output: with
  /// no persisted device the cubit adopts the output whose name matches that
  /// USB product string. `null` (the default, and every desktop build) leaves
  /// binding entirely manual. Mirrors `MidiDeviceRepository`'s input-side
  /// flag — the pedal is one device on two links, so both have to resolve.
  PedalCubit({
    required PedalRepository pedal,
    required SettingsRepository settings,
    Duration pollInterval = const Duration(seconds: 2),
    String? autoBindProductName,
  }) : _pedal = pedal,
       _settings = settings,
       _autoBindProductName = autoBindProductName,
       super(const PedalState()) {
    _statusSub = _pedal.statusChanges.listen(_onBindStatus);
    // Seed the output set so the settings picker has it before the first
    // poll.
    _syncOutputs();
    // Hotplug auto-reconnect for the bound output (mirrors MidiSetupCubit).
    // Pass Duration.zero to disable the timer (tests drive [reconnect]).
    if (pollInterval > Duration.zero) {
      _pollTimer = Timer.periodic(pollInterval, (_) => reconnect());
    }
  }

  final PedalRepository _pedal;
  final SettingsRepository _settings;
  final String? _autoBindProductName;

  late final StreamSubscription<PedalBindStatus> _statusSub;

  // Hotplug reconnect for the bound output: the pinned device id and the poll
  // timer that re-binds it when it (re)appears. The enumerated set + bound id
  // live in PedalState (see _syncOutputs); Equatable dedups no-op refreshes.
  Timer? _pollTimer;
  String? _savedOutputId;

  /// Whether [_savedOutputId] came from auto-detect rather than from the
  /// persisted device or a user pick. Only an auto-bound pin is re-resolved.
  bool _autoBound = false;

  /// Set once the user has explicitly chosen "None", which auto-detect must not
  /// undo for the rest of the session.
  bool _autoBindSuppressed = false;

  Future<void>? _loadFuture;

  /// Loads the persisted pedal output and auto-binds it, and applies the
  /// persisted manual firmware version to the repository's target-version
  /// knob (R6). (The boot-default MODE and the undo long-press threshold are
  /// control state, restored by `ControlCubit.load`.)
  Future<void> load() => _loadFuture ??= _restore();

  Future<void> _restore() async {
    // Both reads are independent platform-channel round trips — start them
    // together so they overlap instead of stacking on the boot path.
    final firmwareVersionFuture = _settings.loadPedalFirmwareVersion();
    final savedFuture = _settings.loadPedalOutputDevice();

    // The firmware version gates what pushState encodes, so apply it before
    // any bind can start streaming frames. Unset (null) keeps the
    // repository's unknown ⇒ v2 floor.
    _applyFirmwareVersion(await firmwareVersionFuture);

    final saved = await savedFuture;
    if (saved == null) {
      // Nothing persisted: let auto-detect adopt the pedal and bind it, reusing
      // [reconnect]'s reconcile rather than repeating the bind here.
      if (_autoBindProductName != null) reconnect();
      return;
    }
    // Pin the saved output so the poll can reconnect it; bind now if present,
    // otherwise the poll binds it as soon as it appears.
    _savedOutputId = saved.id;
    if (_pedal.availableOutputs().any((d) => d.id == saved.id)) {
      _pedal.bind(saved.id);
    }
    _syncOutputs();
  }

  /// Folds the host's enumerated MIDI outputs and the bound destination into
  /// [PedalState], so the settings picker reads them from state rather than
  /// via read-through accessors. Equatable dedups when nothing changed.
  void _syncOutputs() {
    if (isClosed) return;
    emit(
      state.copyWith(
        availableOutputs: _pedal.availableOutputs(),
        boundOutputId: _pedal.boundOutputId,
        firmwareUpdateAvailable: _firmwareUpdateAvailable,
      ),
    );
  }

  /// Whether a REAL pedal is bound and the codec is downgrading what loopy
  /// sends it (flow err-4). Reads the repository's own resolved wire version
  /// rather than re-deriving the floor, so the banner follows whatever
  /// decides the version — the manual setting today, #331's identity reply
  /// later. The on-screen pedal is excluded: there is no firmware behind it
  /// to flash, so "update available" would be a lie even while it rehearses
  /// a pinned downgrade.
  bool get _firmwareUpdateAvailable =>
      _pedal.boundOutputId != null &&
      _pedal.boundOutputId != kSimulatorOutputId &&
      _pedal.targetProtocolVersion < PedalCodec.protocolVersionMax;

  /// Binds the pedal output to [device] and persists the choice.
  ///
  /// Switching to a DIFFERENT device drops the manual firmware version back
  /// to unknown: the version is one setting, not one per device, and what one
  /// pedal's firmware speaks says nothing about the next one's. Carrying it
  /// over would encode at the old pedal's version — silently downgrading a
  /// newer pedal's frames, and telling the user to flash firmware it already
  /// runs — so the R6 v2 floor takes over until they say otherwise.
  Future<void> selectOutput(PedalOutput device) async {
    // Only when REPLACING one pedal with another — a first bind keeps a
    // version the user set before picking the device.
    final replacingDevice =
        _savedOutputId != null && _savedOutputId != device.id;
    _savedOutputId = device.id;
    // An explicit pick takes the pin away from auto-detect.
    _autoBound = false;
    _pedal.bind(device.id);
    if (replacingDevice && state.firmwareVersion != null) {
      await selectFirmwareVersion(null);
    }
    _syncOutputs();
    await _settings.savePedalOutputDevice(id: device.id, name: device.name);
  }

  /// Unbinds the pedal output and clears the saved device.
  ///
  /// Drops the manual firmware version with it, for the same reason
  /// [selectOutput] does when replacing a pedal: once no device is selected
  /// there is nothing the version describes, and keeping it would let the
  /// NEXT pedal bound inherit this one's protocol — `selectOutput` cannot
  /// catch that, since by then it has no previous device to compare against.
  Future<void> selectNone() async {
    _savedOutputId = null;
    // "None" outranks auto-detect, or the next poll would re-adopt the pedal
    // the user just unbound. Session-scoped: the cleared device is what
    // persists, so a relaunch starts auto-detect over.
    _autoBound = false;
    _autoBindSuppressed = true;
    _pedal.unbind();
    if (state.firmwareVersion != null) await selectFirmwareVersion(null);
    _syncOutputs();
    await _settings.clearPedalOutputDevice();
    if (!isClosed) emit(state.copyWith(boundOutputId: null));
  }

  /// Records what wire-protocol version the pedal's firmware speaks
  /// ([version] `null` = unknown), persists it, and applies it to the
  /// repository's target-version knob.
  ///
  /// The manual pre-#331 version-discovery gate (R6): unknown keeps outbound
  /// frames at the v2 safety floor — the repository never encodes v3 at a
  /// pedal not known to speak it.
  Future<void> selectFirmwareVersion(int? version) async {
    _applyFirmwareVersion(version);
    if (version == null) {
      await _settings.clearPedalFirmwareVersion();
    } else {
      await _settings.savePedalFirmwareVersion(version);
    }
  }

  /// The one seam that applies a firmware version: repository knob first
  /// (it gates what the next pushed frame encodes), then the state mirror.
  /// Every current and future source of a version — the persisted setting
  /// in [load], the picker via [selectFirmwareVersion], #331's identity
  /// reply later — must route through here so the pairing cannot diverge.
  void _applyFirmwareVersion(int? version) {
    _pedal.firmwareProtocolVersion = version;
    if (!isClosed) {
      emit(
        state.copyWith(
          firmwareVersion: version,
          firmwareUpdateAvailable: _firmwareUpdateAvailable,
        ),
      );
    }
  }

  /// Hotplug poll: re-enumerates the host's MIDI outputs and reconciles the
  /// pinned pedal output — (re)binds it when it appears (launch, replug, or a
  /// retry after a failed open) and drops the stale handle when it vanishes,
  /// so the LED-feedback link survives unplugs without relaunching loopy.
  /// Mirrors `MidiSetupCubit.refresh`; runs on the poll timer and is callable
  /// directly.
  void reconnect() {
    if (isClosed) return;
    final outputs = _pedal.availableOutputs();
    _maybeAutoPin(outputs);
    final saved = _savedOutputId;
    if (saved != null) {
      final present = outputs.any((d) => d.id == saved);
      if (present && _pedal.boundOutputId != saved) {
        _pedal.bind(saved); // (re)connect on appear / replug / retry
      } else if (!present && _pedal.boundOutputId == saved) {
        _pedal.unbind(); // pinned device vanished: drop the stale port handle
      }
    }
    // Reflect the (possibly changed) output set + bound id into state; the
    // settings picker re-renders only when one of them actually changed.
    _syncOutputs();
  }

  /// Console auto-detect: pins the output whose name matches the configured USB
  /// product string, so [reconnect]'s existing reconcile binds it on the same
  /// tick. Sets the pin only — never persists it.
  ///
  /// Not persisted for the same reason the input side isn't: the per-OS id is
  /// not stable across a replug, and a saved stale id would leave the pedal
  /// permanently unbound on a console that has no picker to fix it with. An
  /// auto-bound pin that has vanished is therefore re-resolved by name rather
  /// than waited on.
  ///
  /// A persisted or user-picked device always wins.
  void _maybeAutoPin(List<PedalOutput> outputs) {
    final productName = _autoBindProductName;
    if (productName == null || _autoBindSuppressed) return;
    final pinned = _savedOutputId;
    if (pinned != null) {
      if (!_autoBound) return;
      if (outputs.any((o) => o.id == pinned)) return;
    }

    PedalOutput? match;
    for (final output in outputs) {
      if (midiDeviceNameMatches(output.name, productName)) {
        match = output;
        break;
      }
    }
    if (match == null || match.id == pinned) return;

    _autoBound = true;
    _savedOutputId = match.id;
  }

  void _onBindStatus(PedalBindStatus status) {
    if (isClosed) return;
    // A bind/unbind changes which device's wire version applies, so the
    // update flag is re-derived with the status it rides in on.
    emit(
      state.copyWith(
        bindStatus: status,
        firmwareUpdateAvailable: _firmwareUpdateAvailable,
      ),
    );
  }

  @override
  Future<void> close() async {
    _pollTimer?.cancel();
    await _statusSub.cancel();
    // Darken the pedal on shutdown (no-op when not bound), then release the
    // transport — this cubit is the pedal repository's lifecycle owner.
    _pedal.pushState(PedalStateFrame.blank(goodbye: true));
    await _pedal.dispose();
    return super.close();
  }
}
