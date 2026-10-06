# Backend integration (optional)

The app works fully offline by default, with on-device accounts and local scan
storage. All backend code sits behind protocols, so the scanning engine never
depends on it.

## 1. Authentication: `RESTAuthService`

**Enable it:** in `project.yml`, set the target's Info.plist property

```yaml
LSBackendBaseURL: "https://api.example.com/v1"
```

then run `xcodegen generate`. Only `https://` URLs are accepted. When the value
is empty, `LocalAuthService` is used.

**API contract** (JSON, ISO-8601 dates):

| Method | Path | Body | Success response |
|---|---|---|---|
| POST | `/auth/register` | `{email, password, displayName}` | `200 {accessToken, user}` |
| POST | `/auth/login` | `{email, password}` | `200 {accessToken, user}` |
| GET | `/auth/me` | (Bearer) | `200 user` |
| PATCH | `/auth/me` | `{displayName}` (Bearer) | `200 user` |
| POST | `/auth/logout` | (Bearer) | `204` |
| DELETE | `/auth/me` | (Bearer) | `204` |

`user = {id: String, email: String, displayName: String, createdAt: ISO-8601}`

Errors: `401` means invalid credentials or an expired session, `409` means the
account already exists, and `429` means rate-limited (`Retry-After` is honored).

**Security:** passwords are sent only over HTTPS and never stored. The access
token lives in the Keychain (`AfterFirstUnlockThisDeviceOnly`). The server
must hash passwords with a slow KDF such as Argon2id, bcrypt or PBKDF2.

**Other providers (Firebase, Supabase, Cognito, Sign in with Apple):** write a
type conforming to `AuthService` in `Authentication/`, then return it from
`AppContainer.live()`. Do not import provider SDKs anywhere else.

## 2. Cloud scan storage: `CloudSyncService`

```swift
protocol CloudSyncService: Sendable {
    var isConfigured: Bool { get }
    func enqueueUpload(scanID: UUID) async throws
    func syncNow() async throws -> SyncSummary
}
```

To implement it:
1. Read the `Scan` from `ScanRepository` and the files from
   `StorageService.scanDirectory(for:)`: `geometry.lsgeo`, `thumbnail.jpg`,
   and for rooms `room.usdz` and `captured-room.json`.
2. Upload them, for example to S3 with presigned URLs, or to Firebase or
   Supabase Storage.
3. Save the scan with `syncState = .synced`.
4. For downloads, write files into the same per-scan directory structure and
   upsert the metadata.

`ScanLibraryService.save` already marks scans `.pendingUpload` and calls
`enqueueUpload` when the service is configured and a user is signed in.
`Scan.ownerID` links each scan to its account. For a fully remote metadata
store, implement `ScanRepository` against your API, or wrap the SwiftData
repository as an offline cache.
