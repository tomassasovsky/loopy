import 'package:flutter_test/flutter_test.dart';
import 'package:loopy/theme/app_theme.dart';
import 'package:loopy/theme/surface_theme.dart';
import 'package:routing_graph/routing_graph.dart';

void main() {
  group('AppTheme', () {
    void expectRoutingGraphMatchesSurface(RoutingGraphTheme? rg) {
      expect(rg, isNotNull, reason: 'RoutingGraphTheme must be registered');
      const surface = SurfaceTheme.dark;
      // Anti-drift: every neutral routing-graph token is mapped straight from
      // the app's SurfaceTheme.dark, so the two can never diverge silently.
      expect(rg!.background, surface.background);
      expect(rg.surface, surface.surface);
      expect(rg.card, surface.card);
      expect(rg.cardHigh, surface.cardHigh);
      expect(rg.line, surface.line);
      expect(rg.textPrimary, surface.textPrimary);
      expect(rg.textSecondary, surface.textSecondary);
      expect(rg.textTertiary, surface.textTertiary);
    }

    test(
      'bigPicture registers RoutingGraphTheme mapped from SurfaceTheme.dark',
      () {
        expectRoutingGraphMatchesSurface(
          AppTheme.bigPicture.extension<RoutingGraphTheme>(),
        );
      },
    );
  });
}
