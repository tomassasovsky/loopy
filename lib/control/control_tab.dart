/// Which face the console's Control domain is showing.
///
/// The reorganised IA (#498) puts the two things that drive the looper from
/// outside it — the hardware footswitches and an external MIDI controller —
/// under one rail entry, because they are the same question asked twice.
///
/// Flutter-free, like `NetworkTab`: the tray cubit holds the selected tab and
/// must not import a widget library to name a value it stores.
enum ControlTab {
  /// The four footswitches and what they are assigned to.
  pedal,

  /// The MIDI device, and the global mappings from its controls to the rig.
  midi,
}
