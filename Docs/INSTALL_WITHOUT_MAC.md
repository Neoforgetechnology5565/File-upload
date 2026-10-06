# Building and installing without a Mac

Every push is built on a GitHub-hosted Mac (`.github/workflows/ios.yml`).
That build compiles the app, runs the tests and produces
**`LiDARScanner-unsigned.ipa`**. To find it, open the repository's **Actions**
tab, open the latest **iOS CI** run, and look under **Artifacts**.

iOS only runs apps that are **signed**. There are two ways to get a signed app
onto your iPhone without owning a Mac.

> Your iPhone must have a LiDAR Scanner (iPhone 12 Pro or a later Pro model)
> to scan. On other iPhones the app installs and runs, but it reports that
> scanning is unsupported.

## Option A: Free, with a Windows PC (Sideloadly)

Signing uses your free Apple ID. The app expires after **7 days** and must be
re-signed, and you can have at most 3 sideloaded apps.

1. On Windows, install **iTunes** and **iCloud** from apple.com. Use the
   apple.com installers, not the Microsoft Store versions.
2. Install **Sideloadly** from sideloadly.io.
3. Download `LiDARScanner-unsigned-ipa` from the Actions run and unzip it to
   get the `.ipa`.
4. Connect the iPhone by USB and tap **Trust** on the phone.
5. In Sideloadly, drag in the `.ipa`, enter your Apple ID, and click
   **Start**.
6. On the iPhone, go to Settings › General › VPN & Device Management, trust
   your Apple ID, and turn on Settings › Privacy & Security › **Developer
   Mode**. Developer Mode needs a restart.

## Option B: TestFlight (Apple Developer Program, $99/year), no computer needed

The GitHub build signs the app and uploads it to TestFlight. You install it
with the TestFlight app on your iPhone, and builds last 90 days.

This needs the following one-time setup, all of it doable in a phone or
tablet web browser:

1. Enroll at developer.apple.com/programs.
2. In App Store Connect, create the app with your own bundle ID. This
   replaces `com.example.lidarscanner` in `project.yml`.
3. Under Users and Access › Integrations › App Store Connect API, create a
   key with the **App Manager** role and download the `.p8` file.
4. In GitHub, go to Settings › Secrets and variables › Actions and add these
   secrets:
   - `ASC_KEY_ID`
   - `ASC_ISSUER_ID`
   - `ASC_KEY_P8`: the contents of the `.p8` file
   - `APPLE_TEAM_ID`

Once these secrets exist, the signing and upload step can be added to the
workflow.

## Option C: Rent a cloud Mac

Services such as MacinCloud rent macOS by the hour. You get full Xcode and can
install over USB, but only if the service supports USB passthrough, which
most do not. Option A or B is usually simpler.
