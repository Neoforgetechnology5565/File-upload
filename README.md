# LiDAR Scanner (iOS / iPadOS)

A native SwiftUI app for LiDAR-equipped iPhones and iPads. It scans rooms with
**RoomPlan** and objects or spaces with **ARKit scene depth and scene
reconstruction**. You can measure on the 3D result, keep a local scan history,
and export real **USDZ, OBJ and PLY** files.

> Status: complete source for all 12 phases, with unit and UI tests. The code
> was written without access to Xcode or a LiDAR device. Build it and run the
> tests on a Mac (see [Getting started](#getting-started)), then follow the
> manual device test plan in [`Docs/TESTING.md`](Docs/TESTING.md).

---

## 1. Recommended architecture

**MVVM + Services + Repository**, with all scanning, geometry and export logic
kept out of the views, plus a hardware-independent core package.

```
SwiftUI Views ──► @Observable ViewModels ──► Domain services ──► Engines / stores
 (Features/)        (Features/)                (Services/,        ├─ RoomPlan pipeline   (Scanning/RoomScanning)
                                                Processing/,      ├─ ARKit pipeline      (Scanning/ObjectScanning, Depth, Mesh)
                                                Export/)          ├─ ScanCore package    (geometry, processing, measurement, exporters)
                                                                  ├─ ScanRepository      (SwiftData / in-memory / future cloud)
                                                                  ├─ StorageService      (files)
                                                                  └─ AuthService         (local Keychain / REST)
```

* **Two separate capture pipelines** share one internal representation
  (`ScanGeometry`):
  * **Room**: `RoomCaptureView` → `CapturedRoomData` → `RoomBuilder` →
    `CapturedRoom` → `RoomModel` (parametric elements) + Apple's USDZ.
  * **Object/Spatial**: `ARSession` (scene depth + `ARMeshAnchor`
    reconstruction) → depth sampling + voxel fusion → mesh cleanup →
    `PointCloud` + `TriangleMesh`.
* **ScanCore** (`Packages/ScanCore`) uses only Foundation and the standard
  library: math, geometry, the voxel grid, filters, mesh cleanup, the
  measurement engine, the PLY/OBJ/USDA writers, USDZ packaging and the domain
  model. Its tests run with `swift test` and need no device.
* **Dependency injection** goes through `AppContainer`. Every important
  service sits behind a protocol: `AuthService`, `StorageService`,
  `ScanRepository`, `ExportService`, `ScanProcessingService`,
  `CloudSyncService`, `DeviceCapabilityProviding`, `SecureStore`,
  `USDZExporting` and `ThumbnailRendering`.

More detail: [`Docs/ARCHITECTURE.md`](Docs/ARCHITECTURE.md).

## 2. Project structure

```
project.yml                      XcodeGen spec (targets, Info.plist, schemes)
Packages/ScanCore/               Platform-independent core (Swift package)
  Sources/ScanCore/
    Math/                        Vector math, Transform3D, BoundingBox, Ray
    Geometry/                    PointCloud, TriangleMesh, RoomModel, ScanGeometry, codec, binary I/O
    Processing/                  VoxelGrid, PointCloudAccumulator (actor), filters, MeshCleanup, pipeline
    Measurement/                 LengthUnit, MeasurementTool protocol + tools, MeasurementEngine, PointPicker
    Export/                      PLYWriter, OBJWriter, USDAWriter, USDZPackager, ExportValidator
    Domain/                      Scan, metadata, statistics, queries, validation
    Scanning/                    ScanFeedback + analyzer (tracking/speed/distance → guidance)
  Tests/ScanCoreTests/
LiDARScanner/                    iOS app target
  Application/                   App entry, AppContainer (DI), AppModel (router/state machine), RootView
  Core/                          AppError, logging, platform bridging, system/memory info
  Capability/                    Device capability detection (LiDAR, depth, RoomPlan, camera)
  Scanning/
    Common/                      Capture models (presets, drafts, capture output)
    RoomScanning/                RoomPlan controller, CapturedRoom → RoomModel, USDZ export
    ObjectScanning/              ARSession engine (ObjectScanSession)
    Depth/                       LiDAR depth → world points (+ camera color)
    Mesh/                        ARMeshAnchor → TriangleMesh
  Processing/                    ScanProcessingService, thumbnail renderer
  Viewer/                        SceneKit scene builder, viewer controller, SwiftUI host
  Export/                        ExportService, Model I/O USDZ exporter
  Persistence/                   ScanRepository protocol, SwiftData model/store, in-memory repo
  Storage/                       StorageService + local file implementation
  Authentication/                AuthService, local (PBKDF2/Keychain) + REST implementations
  Services/                      ScanLibraryService, AppSettings, CloudSyncService
  UI/Components/                 Shared components, theme, error alerts, haptics
  Features/                      The 20 screens and their view models
  Resources/                     Assets, PrivacyInfo.xcprivacy (Info.plist is generated)
LiDARScannerTests/               App unit/integration tests
LiDARScannerUITests/             UI tests (launch with -ui-testing)
Docs/                            Architecture, phases, limitations, backend, testing
```

Screens (all in `LiDARScanner/Features`): SplashView, OnboardingView,
DeviceCompatibilityView, LoginView, RegisterView, HomeView, NewScanView,
ScanModeSelectionView, RoomScanView, ObjectScanView, ScanInstructionsView,
ProcessingView, ScanResultView, ScanViewerView, MeasurementView,
ScanHistoryView, ScanDetailsView, ExportView, SettingsView, ProfileView.

## 3. Required frameworks

| Framework | Used for |
|---|---|
| SwiftUI, Observation | UI, `@Observable` view models, `NavigationStack` |
| ARKit | `ARSession`, `ARWorldTrackingConfiguration`, scene depth, `ARMeshAnchor` |
| RealityKit | `ARView` camera preview with the live reconstructed-mesh overlay |
| RoomPlan | `RoomCaptureView`/`RoomCaptureSession`, `RoomBuilder`, `CapturedRoom` export |
| SceneKit | 3D viewer (orbit/pan/zoom, point primitives, wireframe, hit testing), thumbnails |
| Model I/O | USD export of meshes |
| SwiftData | Local scan database |
| Security, CommonCrypto | Keychain, PBKDF2 password hashing, secure random |
| AVFoundation | Camera permission |
| OSLog | Logging |

No third-party dependencies.

## 4. Minimum OS

**iOS / iPadOS 17.0.** That release is required for SwiftData, `@Observable`,
RoomPlan floors and parent identifiers, and the current SwiftUI APIs. Build
with **Xcode 16 or later**.

## 5. Supported devices

You need a device with a **LiDAR Scanner**:
* iPhone 12 Pro / Pro Max and later Pro models (13 Pro, 14 Pro, 15 Pro, 16 Pro, …)
* iPad Pro 11-inch (2nd gen and later) and iPad Pro 12.9-inch (4th gen and later), plus later iPad Pro models

The app checks at runtime with `ARWorldTrackingConfiguration.supportsSceneReconstruction`,
`supportsFrameSemantics(.sceneDepth)` and `RoomCaptureSession.isSupported`.
On a device without LiDAR it says so clearly and keeps browsing, measuring and
exporting existing scans available. The App Store has no "LiDAR required"
capability key; only `arkit` is declared.

## 6. Development phases

See [`Docs/PHASES.md`](Docs/PHASES.md). For each phase it lists what was
built, the files and where they sit in Xcode, the frameworks, how to run and
test it, and what needs physical LiDAR hardware.

1. Architecture and foundational models/services
2. Device capability detection and the ARKit foundation
3. RoomPlan scanning
4. General object/spatial scanning
5. Scan processing and the internal 3D representation
6. 3D viewer
7. Measurements
8. Local persistence and scan history
9. Exporters
10. Authentication and cloud-ready architecture
11. Complete UI/UX
12. Testing, optimization, error handling and documentation

## 7. Important technical limitations

The full list is in [`Docs/LIMITATIONS.md`](Docs/LIMITATIONS.md). The key points:
* **Accuracy:** LiDAR and RoomPlan are not metrology tools. Expect about 1–2 cm
  error at close range, growing with distance. The UI says this and never
  shows invented precision or fake coverage percentages.
* **Coverage:** ARKit does not expose a "percent complete". The app shows real,
  measured values instead: fused point count, reconstructed surface area,
  RoomPlan element counts, and a live mesh overlay.
* **Object isolation:** an object scan captures everything inside the preset's
  depth range, not just the object. There is no automatic background removal.
* **Textures:** no UV texture atlas is generated. Color is stored per vertex or
  per point. OBJ uses the common `v x y z r g b` extension, PLY has native
  RGB, and USD uses `displayColor`. Not every viewer shows vertex colors.
* **RoomPlan USDZ** comes from Apple's exporter. OBJ and PLY for rooms are
  generated from the same parametric boxes, with documented wall thicknesses.

## Getting started

```bash
brew install xcodegen          # once
xcodegen generate              # creates LiDARScanner.xcodeproj from project.yml
open LiDARScanner.xcodeproj
```

1. In *Signing & Capabilities*, choose your team, or set `DEVELOPMENT_TEAM` in `project.yml`.
2. Run on a LiDAR iPhone or iPad. In the Simulator the app runs, but capture
   is reported as unsupported.
3. Tests: **⌘U** runs the app unit tests, UI tests and ScanCore tests. For the
   core package alone: `cd Packages/ScanCore && swift test`.

Configuration points, all optional:
* `LSBackendBaseURL` in `project.yml` turns on `RESTAuthService`. See [`Docs/BACKEND_INTEGRATION.md`](Docs/BACKEND_INTEGRATION.md).
* `CloudSyncService`: implement it and return it from `AppContainer.live()`.
