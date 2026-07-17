# App Review Notes

Locki is a private fog-of-war exploration map. Location is directly used to clear the textured map around streets the reviewer visits.

## Review flow

1. Open Map and tap **Enable Exploration**.
2. Grant **While Using the App** and **Precise Location**.
3. Use a simulated route or move with the device. Newly visited street-level coverage becomes visible.
4. In Settings, enable **Save Location History**, then grant **Always Location**, **Precise Location**, and **Motion & Fitness** when requested in that setup context.
5. **Efficient** is the default history mode. It combines significant-change and visit delivery, monitored place boundaries, motion evidence, opportunistic Background App Refresh, and short one-shot fixes. It does not hold continuous GPS in the background, so routes can contain gaps.
6. **Detailed** is an optional mode. It retains a background activity session and continuous navigation-quality updates for fuller route and speed detail, uses more battery, and can display the system location indicator.
7. The Settings readiness section reports Always/Precise permission, Background App Refresh, Motion permission, Low Power Mode impact, and the last passive/refresh result.
8. A credible stay appears on the map as **Checking this place** after three minutes. Known-place stays confirm after five minutes; unknown stays confirm after ten minutes with location or motion corroboration. Confirmed stays show **You're staying here for…** and can open named place details.
9. Foreground exploration runs automatically while permission is available. Reduced Accuracy pauses street-level exploration and new nearby-place creation while retaining unambiguous lower-quality known-place evidence.
10. Automatic Path Matching collects three or more accepted movement fixes before asking Apple Maps for walking, cycling, driving, or transit route candidates. A route clears only when the stored anchors support one high-confidence path.
11. Background App Refresh and Core Location event delivery are opportunistic. Low Power Mode and system scheduling can reduce update frequency. Force-quitting prevents further capture until Locki is opened again.
12. The user can disable history without deleting existing data, delete timeline items or all history independently from fog coverage, and prepare a local JSON/GPX export.

## Privacy and battery behavior

- For fog exploration, accepted coordinates are converted to compact explored-area bitmasks.
- When Location History is enabled, accepted callbacks are filtered in memory. Selected route points are quantized and packed before persistence; unselected raw callbacks are discarded.
- Reduced route history, inferred visits, places, route patterns, corrections, and aggregates remain on device until the user deletes them.
- Significant-change fixes also create zoom-21 cell anchors with bucketed accuracy, speed, and course. These ordered anchors expire after six hours and are deleted after matching.
- Only the first and last quantized cells in a window are sent to Apple Maps to request route candidates. Intermediate anchors remain on-device for confidence scoring. Locki has no server and uses no third-party routing, analytics, advertising, or telemetry service.
- Returned route polylines are scored in memory, rasterized into coverage only when confidence is high, and never persisted.
- Locki does not retain an unfiltered raw GPS callback trail.
- Place inference and statistics run on device. Apple Maps receives an inferred place center only after the user taps **Identify This Place**.
- Motion classifications are used only as on-device evidence for staying, walking, cycling, and driving. They are not uploaded or retained as a raw activity diary.
- Tracking-health diagnostics in UserDefaults contain only status labels, counters, and timestamps—never coordinates, trails, or place names.
- Coverage, reduced history, and aggregate totals remain in the app's local SwiftData store. Locki has no account or server.
- Inaccurate, approximate, stale, impossible-speed, and discontinuous samples are rejected.
- Stationary updates do not trigger repeated persistence writes or redraws.
- JSON/GPX export is created locally and shared only through a destination chosen by the user in the system share sheet.
