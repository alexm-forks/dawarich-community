import 'package:dawarich/core/di/providers/core_providers.dart';
import 'package:dawarich/core/di/providers/session_providers.dart';
import 'package:dawarich/core/di/providers/usecase_providers.dart';
import 'package:dawarich/features/tracking/data/alex_wifi_places_sync.dart';
import 'package:dawarich/features/tracking/data/preferences/alex_wifi_places.dart';
import 'package:dawarich/features/tracking/data/sources/alex_places_remote_source.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// alex-hack: link Wi-Fi access points (by BSSID) to manually created
/// Dawarich places. While connected to a linked access point, GPS is paused
/// and points are recorded at the place. Links are stored in the place's note
/// in Dawarich; the phone keeps a copy for the background tracker.
class WifiPlacesView extends ConsumerStatefulWidget {
  const WifiPlacesView({super.key});

  @override
  ConsumerState<WifiPlacesView> createState() => _WifiPlacesViewState();
}

class _WifiPlacesViewState extends ConsumerState<WifiPlacesView> {
  bool _loading = true;
  bool _busy = false;
  bool _enabled = true;
  CurrentWifi? _current;
  List<WifiPlaceLink> _links = const [];
  String? _syncError;

  Future<AlexWifiPlacesSync> _sync() async =>
      AlexWifiPlacesSync(AlexPlacesRemoteSource(
        await ref.read(dioClientProvider.future),
      ));

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    final bool enabled = await AlexWifiPlaces.enabled();
    final CurrentWifi? current = await AlexWifiPlaces.current();
    List<WifiPlaceLink> links = await AlexWifiPlaces.links();
    String? syncError;

    try {
      links = await (await _sync()).refresh();
    } catch (error) {
      syncError = '$error';
    }

    if (!mounted) return;
    setState(() {
      _enabled = enabled;
      _current = current;
      _links = links;
      _syncError = syncError;
      _loading = false;
    });
  }

  /// Runs a change against Dawarich, showing progress and any error.
  Future<bool> _change(
    Future<List<WifiPlaceLink>> Function(AlexWifiPlacesSync sync) action,
  ) async {
    setState(() => _busy = true);
    try {
      final List<WifiPlaceLink> links = await action(await _sync());
      await _applyToTracker();
      if (!mounted) return true;
      setState(() {
        _links = links;
        _syncError = null;
      });
      return true;
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Couldn\'t update Dawarich: $error')),
        );
      }
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  WifiPlaceLink? get _currentLink {
    final CurrentWifi? current = _current;
    if (current == null) return null;
    for (final WifiPlaceLink link in _links) {
      if (AlexWifiPlaces.normaliseBssid(link.bssid) == current.bssid) {
        return link;
      }
    }
    return null;
  }

  Future<void> _setEnabled(bool value) async {
    setState(() => _enabled = value);
    await AlexWifiPlaces.setEnabled(value);
    await _applyToTracker();
  }

  /// Applies a change to a running tracker straight away instead of at the
  /// next heartbeat (e.g. ends a pause when the switch is turned off).
  Future<void> _applyToTracker() async {
    try {
      final user = ref.read(authenticatedUserProvider);
      if (user == null) return;
      final service = await ref.read(pointAutomationServiceProvider.future);
      await service.checkWifiPlaceNow(user.id);
    } catch (error) {
      debugPrint('[WifiPlaces] Applying to tracker failed: $error');
    }
  }

  Future<void> _linkCurrent() async {
    final CurrentWifi? current = _current;
    if (current == null) return;

    final DawarichPlace? place = await showModalBottomSheet<DawarichPlace>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _PlacePickerSheet(),
    );
    if (place == null) return;

    final bool ok = await _change((sync) => sync.link(current, place));
    if (!ok || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Linked ${_wifiLabel(current.ssid)} to ${place.name}')),
    );
  }

  Future<void> _remove(WifiPlaceLink link) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove Wi-Fi link?'),
        content: Text(
          '${_wifiLabel(link.ssid)} (${link.bssid}) will no longer pause '
          'GPS at ${link.placeName}.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await _change((sync) => sync.unlink(link));
  }

  static String _wifiLabel(String ssid) => ssid.isEmpty ? 'This Wi-Fi' : ssid;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final WifiPlaceLink? currentLink = _currentLink;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Wi-Fi Places'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _loading || _busy ? null : _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
        bottom: _busy
            ? const PreferredSize(
                preferredSize: Size.fromHeight(4),
                child: LinearProgressIndicator(),
              )
            : null,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _refresh,
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 8),
                children: [
                  SwitchListTile(
                    title: const Text('Pause GPS on known Wi-Fi'),
                    subtitle: const Text(
                      'While connected to a linked access point, GPS stays off '
                      'and a point is recorded at the place every 15 min',
                    ),
                    value: _enabled,
                    onChanged: _setEnabled,
                  ),
                  if (_syncError != null)
                    ListTile(
                      leading: Icon(
                        Icons.cloud_off,
                        color: theme.colorScheme.error,
                      ),
                      title: const Text('Couldn\'t reach Dawarich'),
                      subtitle: Text(
                        'Showing the copy saved on this phone. $_syncError',
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  const Divider(),
                  _SectionHeader('Current Wi-Fi'),
                  if (_current == null)
                    const ListTile(
                      leading: Icon(Icons.wifi_off),
                      title: Text('Not connected to Wi-Fi'),
                      subtitle: Text(
                        'Or the access point can\'t be read: location '
                        'permission and location services are needed',
                      ),
                    )
                  else ...[
                    ListTile(
                      leading: const Icon(Icons.wifi),
                      title: Text(_wifiLabel(_current!.ssid)),
                      subtitle: Text(
                        currentLink == null
                            ? '${_current!.bssid}\nNot linked'
                            : '${_current!.bssid}\nLinked to ${currentLink.placeName}',
                      ),
                      isThreeLine: true,
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: FilledButton.icon(
                        onPressed: _busy ? null : _linkCurrent,
                        icon: const Icon(Icons.add_location_alt_outlined),
                        label: Text(currentLink == null
                            ? 'Link to a Dawarich place'
                            : 'Link to a different place'),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                      child: Text(
                        'Links are saved in the place\'s note in Dawarich, as '
                        'a "wifi: <BSSID> <name>" line. Only link fixed routers: '
                        'a phone hotspot or travel router moves with you and '
                        'would pin you to the place.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  const Divider(),
                  _SectionHeader('Known Wi-Fi (${_links.length})'),
                  if (_links.isEmpty)
                    const ListTile(
                      title: Text('No Wi-Fi linked yet'),
                    )
                  else
                    ..._links.map(
                      (link) => ListTile(
                        leading: const Icon(Icons.router_outlined),
                        title: Text(link.placeName),
                        subtitle: Text('${_wifiLabel(link.ssid)}\n${link.bssid}'),
                        isThreeLine: true,
                        trailing: IconButton(
                          tooltip: 'Remove',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: _busy ? null : () => _remove(link),
                        ),
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String text;

  const _SectionHeader(this.text);

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Text(
        text,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }
}

/// Lists the user's manually created Dawarich places to pick one.
class _PlacePickerSheet extends ConsumerStatefulWidget {
  const _PlacePickerSheet();

  @override
  ConsumerState<_PlacePickerSheet> createState() => _PlacePickerSheetState();
}

class _PlacePickerSheetState extends ConsumerState<_PlacePickerSheet> {
  late final Future<List<DawarichPlace>> _places = _load();
  String _filter = '';

  Future<List<DawarichPlace>> _load() async {
    final client = await ref.read(dioClientProvider.future);
    return AlexPlacesRemoteSource(client).manualPlaces();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.7,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: TextField(
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Search your places',
                  border: OutlineInputBorder(),
                ),
                onChanged: (value) =>
                    setState(() => _filter = value.trim().toLowerCase()),
              ),
            ),
            Expanded(
              child: FutureBuilder<List<DawarichPlace>>(
                future: _places,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snapshot.hasError) {
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          'Couldn\'t load places from Dawarich:\n${snapshot.error}',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    );
                  }

                  final List<DawarichPlace> places = (snapshot.data ?? const [])
                      .where((p) =>
                          _filter.isEmpty || p.name.toLowerCase().contains(_filter))
                      .toList();

                  if (places.isEmpty) {
                    return const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          'No matching places. Create one by hand in Dawarich '
                          'first.',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    );
                  }

                  return ListView.builder(
                    itemCount: places.length,
                    itemBuilder: (context, index) {
                      final DawarichPlace place = places[index];
                      return ListTile(
                        leading: const Icon(Icons.place_outlined),
                        title: Text(place.name),
                        subtitle: Text(
                          '${place.latitude.toStringAsFixed(5)}, '
                          '${place.longitude.toStringAsFixed(5)}',
                        ),
                        onTap: () => Navigator.pop(context, place),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
