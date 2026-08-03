import 'package:equatable/equatable.dart';

/// One track's line on the 7" performance readout.
class ReadoutTrack extends Equatable {
  /// Creates a [ReadoutTrack].
  const ReadoutTrack({
    required this.name,
    required this.state,
    this.muted = false,
    this.pending = false,
    this.selected = false,
  });

  /// Rebuilds a track from [map] as pushed across the window channel.
  factory ReadoutTrack.fromMap(Map<Object?, Object?> map) => ReadoutTrack(
    name: map['name'] as String? ?? '',
    state: map['state'] as String? ?? 'empty',
    muted: map['muted'] as bool? ?? false,
    pending: map['pending'] as bool? ?? false,
    selected: map['selected'] as bool? ?? false,
  );

  /// Display name.
  final String name;

  /// `TrackState.name` — carried as a token rather than the enum because the
  /// sub-window is a separate engine and the payload crosses a method channel.
  final String state;

  /// Muted right now.
  final bool muted;

  /// A quantized action is armed and waiting for the loop boundary — the
  /// single most useful thing to see from across a stage.
  final bool pending;

  /// The cursor's track.
  final bool selected;

  /// Channel-encodable form.
  Map<String, Object?> toMap() => {
    'name': name,
    'state': state,
    'muted': muted,
    'pending': pending,
    'selected': selected,
  };

  @override
  List<Object?> get props => [name, state, muted, pending, selected];
}

/// Everything the 7" screen shows besides the waveform.
///
/// A value type on purpose: the main window pushes this only when it *changes*
/// (see `WaveformWindowService.pushReadout`), rather than riding the waveform's
/// per-frame timer, so `==` is what keeps the channel quiet while a loop plays
/// unchanged.
class PerformanceReadout extends Equatable {
  /// Creates a [PerformanceReadout].
  const PerformanceReadout({
    this.tracks = const [],
    this.tempoBpm = 0,
    this.tsNum = 4,
    this.tsDen = 4,
    this.loopBars = 0,
    this.isRunning = false,
    this.mode = 'record',
  });

  /// Rebuilds a readout from [map] as pushed across the window channel.
  factory PerformanceReadout.fromMap(Map<Object?, Object?> map) {
    final tracks = map['tracks'];
    return PerformanceReadout(
      tracks: [
        if (tracks is List)
          for (final track in tracks)
            if (track is Map<Object?, Object?>) ReadoutTrack.fromMap(track),
      ],
      tempoBpm: (map['tempoBpm'] as num? ?? 0).toDouble(),
      tsNum: map['tsNum'] as int? ?? 4,
      tsDen: map['tsDen'] as int? ?? 4,
      loopBars: map['loopBars'] as int? ?? 0,
      isRunning: map['isRunning'] as bool? ?? false,
      mode: map['mode'] as String? ?? 'record',
    );
  }

  /// One entry per track, in channel order.
  final List<ReadoutTrack> tracks;

  /// Live tempo.
  final double tempoBpm;

  /// Time-signature numerator.
  final int tsNum;

  /// Time-signature denominator.
  final int tsDen;

  /// Master loop length in bars, `0` when nothing defines it yet.
  final int loopBars;

  /// Transport running.
  final bool isRunning;

  /// `InteractionMode.token` — what a track press means right now.
  final String mode;

  /// Channel-encodable form.
  Map<String, Object?> toMap() => {
    'tracks': [for (final track in tracks) track.toMap()],
    'tempoBpm': tempoBpm,
    'tsNum': tsNum,
    'tsDen': tsDen,
    'loopBars': loopBars,
    'isRunning': isRunning,
    'mode': mode,
  };

  @override
  List<Object?> get props => [
    tracks,
    tempoBpm,
    tsNum,
    tsDen,
    loopBars,
    isRunning,
    mode,
  ];
}
