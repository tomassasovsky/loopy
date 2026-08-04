import 'package:flutter/widgets.dart';
import 'package:segno/l10n/gen/app_localizations.dart';

export 'package:segno/l10n/gen/app_localizations.dart';
export 'package:segno/l10n/localized.dart';

extension AppLocalizationsX on BuildContext {
  AppLocalizations get l10n => AppLocalizations.of(this);
}
