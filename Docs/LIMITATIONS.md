# Technical limitations and how the app handles them

| Area | Limitation | What the app does |
|---|---|---|
| Hardware | LiDAR is only on Pro iPhones (12 Pro and later) and iPad Pro (2020 and later). There is no App Store capability key for LiDAR. | Declares `arkit` only. Checks at runtime and explains the result on the Compatibility screen. Library, viewer and export keep working without LiDAR. |
| Simulator | ARKit and RoomPlan do not run in the Simulator. | Capture reports "unsupported". Everything else, including all tests, runs in the Simulator. |
| Accuracy | LiDAR depth noise is roughly 1–2 cm at under 1 m and grows with distance. RoomPlan dimensions are estimates. Dark, shiny, transparent and mirrored surfaces return poor or no depth. | Only high-confidence depth samples are used. Repeated observations are fused. Readouts are limited to sensible precision (for example 0.1 cm, never µm). The UI states the scans are not for professional metrology. |
| Coverage | ARKit and RoomPlan do not report a "% complete". | No percentage is shown. The UI shows measured values: fused points, reconstructed surface area (sum of `ARMeshAnchor` triangles), RoomPlan element counts, and the live mesh overlay. |
| Object isolation | Scene reconstruction captures the whole environment within range. | The preset's depth range limits capture (Object ≤ 1.5 m, Space ≤ 4.5 m). Background segmentation and cropping are not automatic. |
| Textures | ARKit gives per-anchor geometry, not textured meshes. Building UV atlases from camera frames is outside the native APIs. | Color is stored per vertex and per point from the real camera image. PLY has native RGB. OBJ uses the `v x y z r g b` extension. USD uses `primvars:displayColor` through a `UsdPrimvarReader`. Viewers that ignore vertex colors show the material color. |
| RoomPlan export | `CapturedRoom.export` produces USDZ only. | USDZ uses Apple's file unchanged. OBJ and PLY are generated from the same parametric elements, with documented thicknesses: walls 10 cm, inserts 12 cm, floors 2 cm. |
| Model I/O | USD export support varies by OS, and Model I/O cannot author `UsdGeomPoints`. | A validated fallback chain: direct USDZ, then USDC + packager, then the USDA writer. Point-cloud-only scans always use the USDA writer, which writes Points prims. |
| AR Quick Look | Quick Look does not render point primitives. | Point-cloud USDZ files are still valid USD and open in USD tools such as Blender and usdview. For Quick Look, export scans that include a mesh. |
| Pause/resume | After a pause, ARKit has to relocalize. If it cannot, the session restarts tracking. | Resume reruns without reset options. Guidance shows "Relocalizing". Reset is offered if tracking does not recover. Room scans have no pause, because RoomPlan's stop ends the session. |
| Memory | Large scans can exceed the jetsam limit. | A point budget per preset, `os_proc_available_memory()` checks, a memory-warning handler, a 400k-triangle mesh budget, and processing refuses to start when headroom is too low. |
| Auth backend | No backend ships with the app. | Local on-device accounts by default, plus a REST adapter enabled by configuration. See BACKEND_INTEGRATION.md. |
| Cloud sync | Not implemented, because it needs your storage provider. | `CloudSyncService` protocol, `SyncState` on every scan, and a disabled default implementation. |
