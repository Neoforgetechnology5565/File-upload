# Installing on iPhone without a Mac (TestFlight, one-tap install)

GitHub builds and tests the app on cloud Macs after every change
(`.github/workflows/ios.yml`). When that build succeeds,
`.github/workflows/testflight.yml` signs the app and uploads it to
**TestFlight**. A new version then appears in the TestFlight app on your
iPhone, and you tap **Install** or **Update**. You never need a Mac or a
computer.

Apple requires every iPhone app to be signed by a developer account. That is
why this uses the **Apple Developer Program ($99/year)**. Everything below can
be done in Safari on the iPhone; use "Request Desktop Website" if a page is
cramped.

## One-time setup (about 20 minutes, plus Apple's enrollment approval)

1. **Enroll** at <https://developer.apple.com/programs/enroll/> with your
   Apple ID. Approval usually takes a few hours to 2 days.

2. **Find your Team ID** at <https://developer.apple.com/account> under
   Membership details. It is 10 characters, for example `AB12CD34EF`.

3. **Create the app record.** In <https://appstoreconnect.apple.com>, go to
   Apps › **+** › New App:
   - Platform: iOS. Name: *LiDAR Scanner*, or any name that isn't already
     taken on the App Store.
   - Bundle ID: choose "Register a new bundle ID" and use something unique,
     such as `com.yourname.lidarscanner`. Write it down.
   - SKU: anything, for example `lidarscanner`.

4. **Create an API key.** In App Store Connect, go to Users and Access ›
   Integrations › App Store Connect API › **+**:
   - Name: `GitHub`. Access: **Admin**. Admin is needed so the build can
     create signing certificates automatically.
   - Download the `.p8` file. You can only download it once. Open it in the
     Files app and copy all of its text.
   - Note the **Key ID** and the **Issuer ID**, which is shown above the key list.

5. **Add them to GitHub.** On github.com, open this repository, then go to
   Settings › Secrets and variables › Actions.
   - **Secrets** tab › New repository secret, four times:
     - `ASC_KEY_ID`: the Key ID
     - `ASC_ISSUER_ID`: the Issuer ID
     - `ASC_KEY_P8`: the full text of the `.p8` file, including the
       `-----BEGIN/END PRIVATE KEY-----` lines
     - `APPLE_TEAM_ID`: your Team ID
   - **Variables** tab › New repository variable:
     - `BUNDLE_ID`: the bundle ID from step 3

6. **Start the first upload.** In the repository's Actions tab, choose
   TestFlight › Run workflow. After that it runs automatically after every
   successful build.

7. **Install on the iPhone.**
   - Install **TestFlight** from the App Store.
   - In App Store Connect, go to your app › TestFlight › Internal Testing ›
     **+** to create a group, and add yourself as a tester.
   - Once Apple finishes processing the build (usually 5–30 minutes), it
     appears in TestFlight. Tap **Install**.

Builds expire after 90 days, but every new successful build replaces the old
one automatically. To turn on update notifications, open TestFlight › the app
› Automatic Updates.

## Troubleshooting

* **Actions shows "TestFlight upload skipped. Missing configuration…":** one
  of the secrets or the variable in step 5 is missing or misspelled.
* **"No profiles for … were found" or certificate errors:** the API key needs
  the **Admin** role, and the bundle ID must match the app record exactly.
* **"Missing compliance" in TestFlight:** this shouldn't happen, because the
  app declares it uses no non-exempt encryption. If it does, answer "None of
  the algorithms mentioned above".
* **Upload rejected for a duplicate build number:** run the workflow again.
  Each run uses a new build number.

## Free option (no developer account): SideStore

You need a Windows PC or a Mac **once** for setup. After that, everything
happens on the iPhone. Apps signed with a free Apple ID last 7 days, and you
refresh them in SideStore with one tap. At most 3 such apps can be installed.

Download link for the latest build (works on the iPhone, no login needed):
<https://github.com/olatundelukman5565-svg/File-upload/releases/download/latest-build/LiDARScanner.ipa>

### On the computer (once)
1. Windows only: install **iTunes** and **iCloud** from apple.com, not from
   the Microsoft Store.
2. Follow the official installation guide at <https://sidestore.io> to install
   SideStore onto the iPhone over USB with your Apple ID. That guide stays
   current with SideStore's installer; follow it exactly.

### On the iPhone
1. In Settings › Privacy & Security, turn on **Developer Mode**. This needs a
   restart.
2. In Settings › General › VPN & Device Management, trust your Apple ID.
3. Open the download link above in Safari, then tap Download.
4. Open SideStore, go to My Apps, tap **+**, and choose `LiDARScanner.ipa`
   from Downloads.
5. Every 7 days, open SideStore and tap **Refresh All**. Opening SideStore
   regularly is enough to keep the app working.

## Alternative: Sideloadly (Windows/Mac)

This is simpler to set up, but every 7-day refresh needs the computer. Install
Sideloadly from sideloadly.io, connect the iPhone by USB, drag in the `.ipa`,
enter your Apple ID, and click Start.
