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
10. In Settings, enable **Save Location History**. Locki then retains filtered and quantized route points, infers visits and places, and fills the Journal and Stats tabs.
11. Detailed Background Tracking is enabled by default after history consent. The user can disable detailed background delivery or disable history without deleting existing data.
12. The user can delete timeline items, delete all history independently from fog coverage, or prepare a local JSON/GPX export.

## Privacy and battery behavior

- For fog exploration, accepted coordinates are converted to compact explored-area bitmasks.
- When Location History is enabled, accepted callbacks are filtered in memory. Selected route points are quantized and packed before persistence; unselected raw callbacks are discarded.
- Reduced route history, inferred visits, places, route patterns, corrections, and aggregates remain on device until the user deletes them.
- Significant-change fixes also create zoom-21 cell anchors with bucketed accuracy, speed, and course. These ordered anchors expire after six hours and are deleted after matching.
- Only the first and last quantized cells in a window are sent to Apple Maps to request route candidates. Intermediate anchors remain on-device for confidence scoring. Locki has no server and uses no third-party routing, analytics, advertising, or telemetry service.
- Returned route polylines are scored in memory, rasterized into coverage only when confidence is high, and never persisted.
- Locki does not retain an unfiltered raw GPS callback trail.
- Place inference and statistics run on device. Apple Maps receives an inferred place center only after the user taps **Identify This Place**.
- Coverage, reduced history, and aggregate totals remain in the app's local SwiftData store. Locki has no account or server.
- Inaccurate, approximate, stale, impossible-speed, and discontinuous samples are rejected.
- Stationary updates do not trigger repeated persistence writes or redraws.
- JSON/GPX export is created locally and shared only through a destination chosen by the user in the system share sheet.
