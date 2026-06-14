import 'package:equatable/equatable.dart';
import 'package:pedal_repository/src/pedal_button.dart';

/// A decoded input from the pedal, hardware-agnostic.
///
/// Produced by `PedalCodec.decode` from a raw MIDI message. The pedal cubit
/// turns these into looper commands, timing tap / long-press / double-tap from
/// the [ButtonPressed] / [ButtonReleased] timestamps.
sealed class PedalEvent extends Equatable {
  const PedalEvent();
}

/// A pedal button was pressed (MIDI NoteOn with velocity > 0).
final class ButtonPressed extends PedalEvent {
  /// Creates a [ButtonPressed] event.
  const ButtonPressed(this.button, {this.timestamp = Duration.zero});

  /// The button that was pressed.
  final PedalButton button;

  /// When the press was observed, relative to an arbitrary epoch.
  ///
  /// Set by the caller of `decode`; the codec itself does not read a clock.
  final Duration timestamp;

  @override
  List<Object?> get props => [button, timestamp];

  @override
  String toString() => 'ButtonPressed(${button.name}, $timestamp)';
}

/// A pedal button was released (MIDI NoteOff, or NoteOn with velocity 0).
final class ButtonReleased extends PedalEvent {
  /// Creates a [ButtonReleased] event.
  const ButtonReleased(this.button, {this.timestamp = Duration.zero});

  /// The button that was released.
  final PedalButton button;

  /// When the release was observed, relative to an arbitrary epoch.
  final Duration timestamp;

  @override
  List<Object?> get props => [button, timestamp];

  @override
  String toString() => 'ButtonReleased(${button.name}, $timestamp)';
}

/// The encoder was turned (relative MIDI CC).
///
/// [delta] is signed: positive is clockwise, negative is counter-clockwise.
final class EncoderDelta extends PedalEvent {
  /// Creates an [EncoderDelta] event.
  const EncoderDelta(this.delta);

  /// The signed number of detents turned since the previous message.
  final int delta;

  @override
  List<Object?> get props => [delta];

  @override
  String toString() => 'EncoderDelta($delta)';
}
