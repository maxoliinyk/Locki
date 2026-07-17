# App Review Notes

Locki is a private fog-of-war exploration map. Location is directly used to clear the textured map around streets the reviewer visits.

## Review flow

1. Open Map and tap **Enable Exploration**.
2. Grant **While Using the App** and **Precise Location**.
3. Use a simulated route or move with the device. Newly visited street-level coverage becomes visible.
4. Upgrade to **Always Location** in Settings to enable movement-driven background exploration without continuous navigation tracking.
5. Foreground exploration runs automatically while permission is available.
6. With Always Location, the default background mode uses significant movement updates without continuous navigation tracking.
7. **Continuous Background Exploration** is an optional, off-by-default Settings toggle. It provides precise background coverage, uses more battery, and displays the system location indicator.
8. Automatic Path Matching collects three or more accepted significant-change fixes before asking Apple Maps for walking, cycling, driving, or transit route candidates. A route clears only when the stored anchors support one high-confidence path.
9. Force-quitting prevents further capture until Locki is opened again.

## Privacy and battery behavior

- Accepted coordinates are converted immediately to compact explored-area bitmasks and the original sample is discarded.
- Significant-change fixes also create zoom-21 cell anchors with bucketed accuracy, speed, and course. These ordered anchors expire after six hours and are deleted after matching.
- Only the first and last quantized cells in a window are sent to Apple Maps to request route candidates. Intermediate anchors remain on-device for confidence scoring. Locki has no server and uses no third-party routing, analytics, advertising, or telemetry service.
- Returned route polylines are scored in memory, rasterized into coverage only when confidence is high, and never persisted.
- Locki does not retain raw coordinate trails or place names.
- Coverage and aggregate totals remain in the app's local SwiftData store.
- Inaccurate, approximate, stale, impossible-speed, and discontinuous samples are rejected.
- Stationary updates do not trigger repeated persistence writes or redraws.
