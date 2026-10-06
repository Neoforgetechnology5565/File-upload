# Testing

## Automated

| Suite | Target | Covers |
|---|---|---|
| `MeasurementTests`, `LengthUnitTests` | ScanCore | Distance, height, width, area and bounding-box math, unit conversion and formatting |
| `VectorMathTests`, `MeshTests`, `VoxelAndPointCloudTests`, `RoomModelTests` | ScanCore | Math, transforms, ray picking, mesh cleanup and decimation, voxel fusion, outlier filter, processing pipeline, room meshes, binary codec |
| `PLYWriterTests`, `OBJWriterTests`, `USDZTests` | ScanCore | Exporter output and the validators (format, sizes, indices, alignment, CRC) |
| `ScanMetadataTests`, `ScanFeedbackTests` | ScanCore | Scan metadata coding, statistics, queries, name validation, scanning guidance |
| `SwiftDataScanRepositoryTests`, `LocalFileStorageServiceTests`, `ScanLibraryServiceTests` | App | Persistence, repository logic, file lifecycle (integration) |
| `ExportServiceTests` | App | End-to-end PLY, OBJ and USDZ export including Model I/O and fallbacks |
| `CredentialValidatorTests`, `PasswordHasherTests`, `LocalAuthServiceTests`, `AuthViewModelTests` | App | Authentication state and security properties |
| `AppModelTests`, `MeasurementViewModelTests`, `LibraryViewModelTests`, `CaptureMappingTests` | App | View models, navigation flow, error mapping |
| `LiDARScannerUITests` | UI | Onboarding, compatibility, local and registered sign-in, new-scan flow, unsupported-device behavior, history |

Run everything with ⌘U, or:

```bash
xcodebuild test -project LiDARScanner.xcodeproj -scheme LiDARScanner \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro'
cd Packages/ScanCore && swift test
```

The UI tests launch with `-ui-testing`. That selects
`AppContainer.uiTesting()`, which uses an in-memory repository, in-memory
secrets, a temporary storage directory and fresh defaults.
`UITEST_CAPABILITIES=full|none` controls only what the app *reports* as
supported. No scan data is ever faked.

## Hardware abstractions

Everything that needs LiDAR sits behind seams that tests can replace:
`DeviceCapabilityProviding` (`FixedCapabilityProvider`),
`ScanProcessingService`, `ThumbnailRendering`, `ScanRepository`,
`StorageService`, `SecureStore`, `AuthService` and `USDZExporting`. All
algorithms that consume sensor data (fusion, filtering, cleanup, measurement,
export) live in ScanCore and are tested with synthetic geometry.

## Manual device test plan (LiDAR iPhone or iPad)

1. **First launch:** onboarding, then the compatibility screen with every
   check green, then Continue Locally, then Home.
2. **Camera permission:** deny it, then Start Scanning. You should get the
   "Camera Access Needed" alert with Open Settings.
3. **Room scan:** scan a room. Check guidance ("Move closer to the wall",
   "Move slowly"), the live wall, door, window and object counts, Done, the
   processing steps, and that the result has a 3D preview with real counts and
   wall height. Measure a doorway width, save, and check that it appears in
   History.
4. **Object scan, Object preset:** scan a chair. Check "Move closer" beyond
   1.5 m and "Too fast" on quick motion, the mesh overlay, and that points and
   surface area grow. Pause, resume, reset, then finish. The result should have
   a colored mesh and points.
5. **Interruption:** press Home mid-scan and return. The status should show
   interruption and then relocalizing.
6. **Measurements:** measure a known 1 m object in m, cm, mm, ft and in.
   Expect about ±2 cm. Check Height and Area on a tabletop, then reopen the
   scan and confirm the measurements were persisted.
7. **Viewer:** rotate, pan, zoom, fit, reset, wireframe, the Points/Mesh/Both
   toggle, and room object selection.
8. **Export:** export USDZ, OBJ and PLY for both scan types. Open the USDZ in
   Quick Look (mesh scans), the OBJ in Blender, and the PLY in MeshLab or
   CloudCompare.
9. **Stress:** run a 3–5 minute Space scan. There should be no crash; the
   memory or point-budget message appears if the limit is reached.
10. **Accounts:** register, sign out, sign in, try a wrong password five times
    to trigger the lockout, then delete the account.
