import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:loopy/l10n/l10n.dart';
import 'package:loopy/looper/view/signal_graph/signal_style.dart';
import 'package:loopy/theme/surface_theme.dart';

/// Opens the plugin browser over the [LooperRepository]'s scan catalog and
/// resolves to the chosen [PluginDescriptor], or null if dismissed. Shared by
/// the FX rack's "add plugin" flow and the D-MISS relink action.
Future<PluginDescriptor?> showPluginBrowser(BuildContext context) {
  final catalog = context.read<LooperRepository>().pluginCatalog;
  return showDialog<PluginDescriptor>(
    context: context,
    builder: (_) => _PluginBrowserDialog(catalog: catalog),
  );
}

class _PluginBrowserDialog extends StatefulWidget {
  const _PluginBrowserDialog({required this.catalog});

  final PluginCatalog catalog;

  @override
  State<_PluginBrowserDialog> createState() => _PluginBrowserDialogState();
}

class _PluginBrowserDialogState extends State<_PluginBrowserDialog> {
  bool _scanning = false;
  String _query = '';
  List<PluginDescriptor> _plugins = const [];

  @override
  void initState() {
    super.initState();
    // Show any cached results immediately; scan on the first open.
    _plugins = widget.catalog.availablePlugins;
    if (_plugins.isEmpty) unawaited(_scan());
  }

  Future<void> _scan({bool rescan = false}) async {
    setState(() => _scanning = true);
    final found = await widget.catalog.scan(rescan: rescan);
    if (!mounted) return;
    setState(() {
      _plugins = found.where((p) => p.isAvailable).toList();
      _scanning = false;
    });
  }

  List<PluginDescriptor> get _filtered {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _plugins;
    return _plugins
        .where(
          (p) =>
              p.name.toLowerCase().contains(q) ||
              p.vendor.toLowerCase().contains(q),
        )
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    return Dialog(
      backgroundColor: surface.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: surface.line),
      ),
      child: SizedBox(
        width: 440,
        height: 520,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 10),
              child: Row(
                children: [
                  Text(
                    l10n.signalPluginBrowserTitle,
                    style: signalMono(
                      color: surface.textPrimary,
                      size: 14,
                      weight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    key: const Key('pluginBrowser_rescan'),
                    onPressed: _scanning
                        ? null
                        : () => unawaited(_scan(rescan: true)),
                    icon: const Icon(Icons.refresh, size: 16),
                    label: Text(
                      l10n.signalPluginRescan,
                      style: signalMono(color: surface.textSecondary),
                    ),
                  ),
                  IconButton(
                    key: const Key('pluginBrowser_close'),
                    icon: const Icon(Icons.close, size: 18),
                    color: surface.textTertiary,
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                key: const Key('pluginBrowser_search'),
                onChanged: (v) => setState(() => _query = v),
                style: signalMono(color: surface.textPrimary, size: 12),
                decoration: InputDecoration(
                  isDense: true,
                  prefixIcon: Icon(
                    Icons.search,
                    size: 16,
                    color: surface.textTertiary,
                  ),
                  hintText: l10n.signalPluginBrowserSearchHint,
                  hintStyle: signalMono(color: surface.textTertiary, size: 12),
                  filled: true,
                  fillColor: kSignalInset,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: kSignalLine2),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: kSignalLine2),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Expanded(child: _body(context)),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final filtered = _filtered;
    if (_scanning && _plugins.isEmpty) {
      return const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (filtered.isEmpty) {
      return Center(
        child: Text(
          l10n.signalPluginBrowserEmpty,
          style: signalMono(color: surface.textTertiary),
        ),
      );
    }
    return ListView.builder(
      key: const Key('pluginBrowser_list'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      itemCount: filtered.length,
      itemBuilder: (context, i) => _PluginRow(
        descriptor: filtered[i],
        onTap: () => Navigator.of(context).pop(filtered[i]),
      ),
    );
  }
}

/// One scanned plugin in the browser list: name, a format badge, and vendor.
class _PluginRow extends StatelessWidget {
  const _PluginRow({required this.descriptor, required this.onTap});

  final PluginDescriptor descriptor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final isVst3 = descriptor.format == PluginFormat.vst3;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: Key('pluginBrowser_row_${descriptor.id}'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                decoration: BoxDecoration(
                  color: surface.accent.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Text(
                  isVst3 ? 'VST3' : 'CLAP',
                  style: signalMono(
                    color: surface.accent,
                    size: 8.5,
                    tracking: 0.5,
                    weight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      descriptor.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: signalMono(
                        color: surface.textPrimary,
                        size: 12,
                        weight: FontWeight.w500,
                      ),
                    ),
                    if (descriptor.vendor.isNotEmpty)
                      Text(
                        descriptor.vendor,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: signalMono(
                          color: surface.textTertiary,
                          size: 9.5,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
