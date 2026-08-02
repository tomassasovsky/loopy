import 'package:bloc/bloc.dart';
import 'package:brightness_client/brightness_client.dart';
import 'package:loopy/appliance/software_brightness.dart';
import 'package:settings_repository/settings_repository.dart';

/// App-wide display brightness (`0..1`).
///
/// Always drives a Flutter software dim (see [SoftwareBrightness]). When the
/// appliance [BrightnessClient] reports DDC/CI support, also applies via the
/// host helper.
class DisplayBrightnessCubit extends Cubit<double> {
  /// Creates a [DisplayBrightnessCubit].
  DisplayBrightnessCubit({
    required SettingsRepository settings,
    BrightnessClient client = const UnsupportedBrightnessClient(),
  }) : _settings = settings,
       _client = client,
       super(0.8);

  final SettingsRepository _settings;
  final BrightnessClient _client;
  Future<void>? _loadFuture;
  bool _hardwareSupported = false;

  /// Restores the persisted level and probes DDC.
  Future<void> load() => _loadFuture ??= _restore();

  Future<void> _restore() async {
    final saved = await _settings.loadBrightness();
    _hardwareSupported = await _client.isSupported();
    if (isClosed) return;
    emit(clampDisplayBrightness(saved));
    await _applyHardware(clampDisplayBrightness(saved));
  }

  /// Sets brightness (`kMinDisplayBrightness..1`), persists it, dims in
  /// software (via listeners), and applies DDC when available.
  Future<void> setBrightness(double value) async {
    final clamped = clampDisplayBrightness(value);
    if (clamped != state) emit(clamped);
    await _settings.saveBrightness(clamped);
    await _applyHardware(clamped);
  }

  Future<void> _applyHardware(double value) async {
    if (!_hardwareSupported) return;
    try {
      await _client.set(value);
    } on Object {
      // Software dim still applies.
    }
  }
}
