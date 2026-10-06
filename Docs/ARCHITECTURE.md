# Architecture

## Layers

| Layer | Location | Rules |
|---|---|---|
| Views | `Features/*View*.swift`, `UI/` | Layout and bindings only. No ARKit, file system or database calls. |
| View models | `Features/*` (`@Observable @MainActor`) | Screen state and user intents. They talk to services through protocols. |
| Domain services | `Services/`, `Processing/`, `Export/` | Orchestration such as save = commit files + persist metadata, or process → stage → thumbnail. |
| Engines | `Scanning/*`, `Viewer/`, `Packages/ScanCore` | Real capture, geometry, measurement and export algorithms. |
| Infrastructure | `Persistence/`, `Storage/`, `Authentication/` | SwiftData, file system, Keychain, network. |

`AppContainer` (`Application/AppContainer.swift`) is the composition root.
`AppModel` is the app state machine (Launch → Onboarding → Capability Check
→ Login/Local → Home) and owns the `NavigationStack` path (`[Route]`).

## The two capture pipelines

```
ROOM (RoomPlan)                                    OBJECT / SPATIAL (ARKit)
────────────────                                   ──────────────────────────
RoomCaptureViewController                          ObjectScanSession (ARSessionDelegate on a private queue)
  RoomCaptureView + RoomCaptureSession               ARWorldTrackingConfiguration
  instructions → ScanFeedback                         + smoothedSceneDepth / sceneDepth
  live CapturedRoom counts                            + sceneReconstruction .mesh(WithClassification)
        │                                              ├─ DepthPointSampler: depth+confidence+YCbCr → world points
        │ CapturedRoomData                             ├─ PointCloudAccumulator (actor, VoxelGrid fusion, budget)
        ▼                                              ├─ ARMeshAnchor tracking + surface area
RoomScanProcessor                                      └─ ScanFeedbackAnalyzer (tracking/speed/distance)
  RoomBuilder(.beautifyObjects)                              │ ObjectCaptureResult (raw mesh + voxel grid)
  CapturedRoom ─► RoomModelConverter ─► RoomModel             ▼
  CapturedRoom.export(.parametric) ─► room.usdz       ObjectScanProcessingPipeline (ScanCore)
  CapturedRoom JSON (Codable)                           filter points → weld/clean/decimate mesh
        │                                               → normals → colorize → normal transfer
        └──────────────► ScanGeometry ◄─────────────────────┘
                             │
             ScanGeometryCodec (geometry.lsgeo) + thumbnail → staging dir → ScanLibraryService.save
```

Both pipelines end in the same `ScanGeometry`, so the viewer, the measurement
engine, persistence and all exporters stay pipeline-agnostic. Each pipeline
keeps its own controller, processor and capture-specific types, which keeps
the codebase from tangling.

## Internal 3D representation (ScanCore)

* `PointCloud`: positions, optional RGB, optional normals (world space, meters).
* `TriangleMesh`: positions, optional normals and colors, `UInt32` indices.
* `RoomModel`: `RoomElement`s (kind, category, dimensions, `Transform3D`,
  confidence, parent).
* `ScanGeometry`: any combination of the three above, plus derived bounds,
  the exportable mesh and named groups.
* `geometry.lsgeo`: compact versioned binary format with bulk arrays (fast
  load) and a JSON section for the room model.

## Concurrency and performance

* ARSession callbacks run on a dedicated serial queue. ARFrames are never
  retained: depth and color are copied out synchronously.
* Depth sampling runs at 5 Hz with a pixel stride (Standard: 4, High: 2) and
  high confidence only. That is about 3k points per sample.
* Fusion uses a `VoxelGrid` inside an actor. It averages repeated
  observations, and memory is bounded by a hard point budget plus an
  `os_proc_available_memory()` headroom check. Memory warnings stop
  accumulation.
* Mesh surface area is recomputed at most once per second, and only for anchors
  that changed.
* Status reaches the UI at about 10 Hz.
* Processing runs off the main actor and is cancellable. Every heavy loop calls
  `Task.checkCancellation()`.
* The mesh triangle budget is 400k, enforced by vertex-clustering decimation.
* The viewer builds SceneKit geometry from packed `Data` buffers with no
  per-vertex objects, renders on demand (`rendersContinuously = false`), and
  picks points on a background task.
* SwiftData runs in a `@ModelActor`, off the main thread.

## Persistence and cloud readiness

* `ScanRepository` handles metadata and `StorageService` handles bytes.
  `ScanLibraryService` keeps them consistent: staging commit, rollback on
  failure, and deleting files together with records.
* `ScanRecord` (SwiftData) stores queryable columns plus a JSON payload of the
  domain `Scan`, so the schema stays stable as the model evolves.
* `Scan.syncState` and `ownerID` already exist. To add a cloud backend,
  implement `CloudSyncService` (and optionally a remote `ScanRepository`).
  Views do not change.

## Viewer technology choice

The viewer and thumbnails use **SceneKit** rather than RealityKit because
SceneKit provides, on iOS 17:

* native point primitives with screen-space sizing for LiDAR point clouds,
* wireframe fill mode,
* built-in orbit, pan and zoom camera control with inertia,
* precise world-space hit testing with `simdWorldCoordinates`.

RealityKit is still used where it is strongest: the live AR camera view with
the scene-understanding mesh overlay while scanning.
