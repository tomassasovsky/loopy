import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:loopy/looper/fx_presets/fx_preset.dart';
import 'package:path_provider/path_provider.dart';

/// Loads factory racks from assets and user racks from app-support storage.
class FxPresetLibrary {
  FxPresetLibrary._({
    required this.factoryPresets,
    required List<FxPreset> userPresets,
    required File userFile,
  }) : _userPresets = userPresets,
       _userFile = userFile;

  /// Factory presets shipped in `assets/fx_racks/`.
  final List<FxPreset> factoryPresets;

  final List<FxPreset> _userPresets;
  final File _userFile;

  /// User-saved presets.
  List<FxPreset> get userPresets => List.unmodifiable(_userPresets);

  /// Loads factory + user libraries.
  static Future<FxPresetLibrary> load() async {
    final factory = await _loadFactory();
    final support = await getApplicationSupportDirectory();
    final file = File('${support.path}/fx_user_presets.json');
    final user = await _loadUser(file);
    return FxPresetLibrary._(
      factoryPresets: factory,
      userPresets: user,
      userFile: file,
    );
  }

  /// Persists a user [preset] (replace if id matches).
  Future<void> saveUserPreset(FxPreset preset) async {
    final idx = _userPresets.indexWhere((p) => p.id == preset.id);
    if (idx >= 0) {
      _userPresets[idx] = preset;
    } else {
      _userPresets.add(preset);
    }
    await _persistUser();
  }

  /// Deletes a user preset by [id].
  Future<void> deleteUserPreset(String id) async {
    _userPresets.removeWhere((p) => p.id == id);
    await _persistUser();
  }

  Future<void> _persistUser() async {
    await _userFile.parent.create(recursive: true);
    await _userFile.writeAsString(
      jsonEncode([for (final p in _userPresets) p.toJson()]),
    );
  }

  static Future<List<FxPreset>> _loadFactory() async {
    const paths = [
      'assets/fx_racks/vocal_air.json',
      'assets/fx_racks/guitar_drive.json',
      'assets/fx_racks/dub_echo.json',
    ];
    final out = <FxPreset>[];
    for (final path in paths) {
      try {
        final raw = await rootBundle.loadString(path);
        out.add(FxPreset.fromJson(jsonDecode(raw) as Map<String, dynamic>));
      } on Object {
        // Missing asset in tests — skip.
      }
    }
    return out;
  }

  static Future<List<FxPreset>> _loadUser(File file) async {
    if (!file.existsSync()) return [];
    try {
      final decoded = jsonDecode(file.readAsStringSync()) as List<dynamic>;
      return [
        for (final e in decoded) FxPreset.fromJson(e as Map<String, dynamic>),
      ];
    } on Object {
      return [];
    }
  }
}
