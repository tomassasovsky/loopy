/// The bidirectional MIDI foot-pedal feature: the behavior cubit and its
/// settings UI. loopy owns all pedal state and pushes LED frames back over the
/// `pedal_repository` transport.
library;

export 'cubit/pedal_cubit.dart';
export 'view/pedal_settings_section.dart';
