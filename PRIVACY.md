# Orbit privacy

Orbit stores settings, battery history and saved app files locally. The established `com.kayhsen.NotchFlow` preferences/keychain identity remains for upgrade compatibility. Saved app files use Orbit folders after migration. A local app-group snapshot shares device names, identifiers, battery levels, charging state where available and timestamps with the widget extension; it does not contain full battery history or account credentials.

Nearby Bluetooth discovery is optional. It scans briefly, displays eligible device names and reads the standard Battery Service only from devices selected for tracking. Discovery candidates are held in memory with an expiry. Connections are bounded and closed after a read. The optional MobileDevice reader reads only already-trusted devices; it does not pair, install software, alter sync settings or collect phone content. Battery-device data is not uploaded by these readers.

Existing optional features may contact their selected services: music providers, artwork/lyrics services, weather, network integrations and configured AI usage providers. Their own privacy terms apply. OAuth tokens and configured credentials remain in existing local/keychain storage; the battery widgets do not receive them.

macOS permissions are requested by the features that need them, including Bluetooth, Accessibility, audio/camera, calendar/reminders, location and file access. Native battery dismissal uses advertised actions on narrowly matched Apple alerts. Orbit does not disable unrelated notifications or alter system notification preferences. Audio features process live audio without saving recordings.

Diagnostics are local until you explicitly export/share them. Review exported logs before sharing because they may include device names, paths and service error information. The public repository/source packages exclude private user-data snapshots and build diagnostics.
