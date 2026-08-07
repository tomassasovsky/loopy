/// Which tab the Audio domain is showing.
///
/// Flutter-free, like `LoopTab`, `ControlTab` and `TracksTab` and for the same
/// reason: the value lives in `SettingsTrayState`, and the tray cubit must not
/// import a widget library to name something it only stores.
///
/// Two tabs, not three. There was a Status tab reporting what the rig was
/// doing; everything on it was either duplicated from [device] or belonged
/// beside the setting that decides it, and a figure shown in two places is one
/// that can disagree with itself. What it uniquely showed — a config in flight
/// — is a banner on [device] instead.
enum AudioTab {
  /// The device, its rate and buffer, what its inputs are called, and what the
  /// round trip measures.
  device,

  /// What pressing record does: the loop cap, quantize, overdub, sound-
  /// activated recording, and the default length.
  recording,
}
