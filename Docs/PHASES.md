# Implementation phases

Each phase lists what was built, its files, where they belong in Xcode, the
frameworks, how to run and test it, and what needs LiDAR hardware.

**Placement in Xcode:** `project.yml` (XcodeGen) maps folders to groups and
targets automatically.
* `LiDARScanner/**` → **LiDARScanner** app target
* `LiDARScannerTests/**` → **LiDARScannerTests**
* `LiDARScannerUITests/**` → **LiDARScannerUITests**
* `Packages/ScanCore` → local Swift package, linked as the `ScanCore` product

If you build the project by hand instead, recreate the same groups and add the
package through *File › Add Package Dependencies › Add Local…*.

---

## Phase 1: Architecture and foundational models/services
**What:** the platform-independent core, which holds the domain model, internal
3D representation, math, geometry codec, voxel fusion, filters, measurement
engine, exporters and validators.
**Files:** `Packages/ScanCore/**` (Math, Geometry, Processing, Measurement,
Export, Domain, Scanning) and `Tests/ScanCoreTests/*`.
**Frameworks:** Foundation only.
**Run/test:** `cd Packages/ScanCore && swift test` (macOS or Linux), or ⌘U in Xcode.
**Hardware:** none.

## Phase 2: Device capability detection and ARKit foundation
**What:** real capability checks (world tracking, LiDAR via scene
reconstruction, scene depth, mesh classification, RoomPlan, camera
permission), a test double, the error model, logging, simd bridging, and
device and memory info.
**Files:** `Capability/DeviceCapabilityService.swift`, `Core/AppError.swift`,
`Core/Log.swift`, `Core/PlatformBridging.swift`, `Core/SystemInfo.swift`.
**Frameworks:** ARKit, RoomPlan, AVFoundation, OSLog, simd.
**Run/test:** `DeviceCompatibilityView` shows every check. `FixedCapabilityProvider`
drives unit and UI tests.
**Hardware:** real results need a device. The Simulator reports "unsupported".

## Phase 3: RoomPlan scanning
**What:** `RoomCaptureView` hosting with coaching, session control, mapping of
RoomPlan instructions to guidance, live wall/door/window/object counts,
`RoomBuilder` post-processing, `CapturedRoom` → `RoomModel` conversion,
Apple's parametric USDZ, and `CapturedRoom` JSON archiving.
**Files:** `Scanning/RoomScanning/RoomCaptureViewController.swift`,
`Scanning/RoomScanning/RoomScanProcessor.swift`, `Features/Capture/RoomScanView.swift`.
**Frameworks:** RoomPlan, UIKit, SwiftUI.
**Run/test:** New Scan › Room Scan on a device. The `RoomModel`/mesh/summary
logic is unit-tested in ScanCore (`RoomModelTests`).
**Hardware:** capture requires LiDAR and RoomPlan support.

## Phase 4: General object/spatial scanning
**What:** `ObjectScanSession`, an ARSession engine on a background queue.
It provides the preview → capture → pause/resume → reset → finish flow, scene
depth sampling with confidence filtering and camera color, `ARMeshAnchor`
tracking with live surface area, motion and distance guidance, a point budget
and memory-pressure guards.
**Files:** `Scanning/ObjectScanning/ObjectScanSession.swift`,
`Scanning/Depth/DepthPointSampler.swift`, `Scanning/Mesh/MeshAnchorExtractor.swift`,
`Scanning/Common/CaptureModels.swift`, `Features/Capture/ObjectScanView.swift`.
**Frameworks:** ARKit, RealityKit (`ARView` preview and mesh overlay), CoreVideo.
**Run/test:** New Scan › Object / Spatial Scan on a device. The color
conversion and preset mapping are unit-tested (`CaptureMappingTests`), and the
feedback logic is tested in ScanCore (`ScanFeedbackTests`).
**Hardware:** capture requires LiDAR.

## Phase 5: Scan processing and internal 3D representation
**What:** `ScanProcessingService` runs the room or object pipeline, writes
`geometry.lsgeo`, renders a thumbnail into a staging directory and builds the
`Scan` with real statistics. `ObjectScanProcessingPipeline` (ScanCore)
handles voxel filtering, outlier removal, seam welding, degenerate and
small-component removal, decimation, normals, colorization and normal transfer.
**Files:** `Processing/ScanProcessingService.swift`, `Processing/ThumbnailRenderer.swift`,
`Packages/ScanCore/Sources/ScanCore/Processing/*`, `Geometry/ScanGeometryCodec.swift`.
**Frameworks:** RoomPlan, SceneKit, Metal (offscreen renderer).
**Run/test:** `MeshTests`, `VoxelAndPointCloudTests` and
`testProcessingPipelineProducesValidGeometry` in ScanCore. On a device, the
Processing screen shows each step.
**Hardware:** real input needs a device. The algorithms are tested with synthetic data.

## Phase 6: 3D viewer
**What:** a SceneKit viewer with orbit/pan/zoom, reset camera, fit model, a
mesh/points/both toggle, wireframe, measurement annotations, room-element
selection with highlight and info card, and point-cloud ray picking.
**Files:** `Viewer/SceneBuilder.swift`, `Viewer/SceneViewerController.swift`,
`Viewer/ScanSceneView.swift`, `Features/Viewer/ScanViewerView.swift`.
**Frameworks:** SceneKit.
**Run/test:** open any saved scan › View in 3D. Works in the Simulator with saved data.
**Hardware:** none for viewing.

## Phase 7: Measurements
**What:** an extensible `MeasurementTool` protocol with Distance, Height,
Width (horizontal), Area (Newell polygon) and Bounding Box tools, a
`MeasurementEngine` registry, model bounds, unit conversion (m, cm, mm, ft,
in) and the point-picking workflow.
**Files:** `ScanCore/Measurement/*`, `Features/Measurement/MeasurementView.swift`.
**Run/test:** `MeasurementTests`, `LengthUnitTests` and `MeasurementViewModelTests`.
**Hardware:** none.

## Phase 8: Local persistence and scan history
**What:** `ScanRepository` protocol, SwiftData `@ModelActor` store, in-memory
repository, file `StorageService` with staging commit, disk-space checks and
file protection, `ScanLibraryService`, History with search, type filter, sort
and delete, and Details.
**Files:** `Persistence/*`, `Storage/StorageService.swift`, `Services/ScanLibraryService.swift`,
`Features/History/*`, `Features/Details/*`.
**Frameworks:** SwiftData.
**Run/test:** `SwiftDataScanRepositoryTests`, `LocalFileStorageServiceTests`,
`ScanLibraryServiceTests` and `LibraryViewModelTests`.
**Hardware:** none.

## Phase 9: Exporters
**What:** real converters only.
* **PLY:** binary or ASCII, with XYZ plus normals and RGB when available,
  and faces for meshes.
* **OBJ:** writes `.obj` + `.mtl` with groups, materials, normals and
  optional vertex colors.
* **USDZ:** RoomPlan's USDZ for rooms. Otherwise Model I/O direct, then Model
  I/O usdc packaged with a spec-compliant USDZ packager (64-byte aligned,
  stored), then the USDA writer, which also covers point-cloud-only scans.

Every output is structurally validated before it is offered to the user.
**Files:** `ScanCore/Export/*`, `Export/ExportService.swift`, `Export/USDZExporter.swift`,
`Features/Export/ExportView.swift`.
**Frameworks:** Model I/O.
**Run/test:** `PLYWriterTests`, `OBJWriterTests`, `USDZTests` and `ExportServiceTests`.
**Hardware:** none.

## Phase 10: Authentication and cloud-ready architecture
**What:** the `AuthService` protocol; `LocalAuthService` (PBKDF2-HMAC-SHA256
with 600k iterations, random salt, Keychain storage, lockout); `RESTAuthService`
(generic bearer-token API, HTTPS only, enabled through `LSBackendBaseURL`);
`SecureStore` (Keychain or in-memory); guest mode; and the `CloudSyncService`
protocol, disabled by default.
**Files:** `Authentication/*`, `Services/CloudSyncService.swift`.
**Frameworks:** Security, CommonCrypto.
**Run/test:** `CredentialValidatorTests`, `PasswordHasherTests`,
`LocalAuthServiceTests` and `AuthViewModelTests`.
**Hardware:** none. A backend is needed only if you configure one.

## Phase 11: Complete UI/UX
**What:** all 20 screens, `NavigationStack` routing, full-screen capture, the
onboarding → compatibility → auth flow, iPad readable widths and adaptive
grids, Dynamic Type, VoiceOver labels, dark mode (system colors), haptics,
consistent error alerts with Open Settings, and settings for units, density,
mesh overlay and export defaults.
**Files:** `Application/*`, `Features/**`, `UI/Components/Components.swift`, `Resources/*`.
**Run/test:** `AppModelTests` and the UI tests (`LiDARScannerUITests`).

## Phase 12: Testing, optimization, error handling, documentation
**What:** unit tests across ScanCore and the app, UI tests that use an
isolated `-ui-testing` container, the memory and performance safeguards
described in ARCHITECTURE.md, the `AppError` mapping for every failure class,
and these docs.
**Run/test:** ⌘U. See [TESTING.md](TESTING.md) for the manual device test plan.
