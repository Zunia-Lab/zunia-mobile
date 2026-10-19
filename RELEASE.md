# Releasing Zunia to Google Play and the App Store

Version **0.1.0 (build 2)**. Section 1 is done in this repository. Sections 3 and 4 need the store accounts, so the account owner does them.

## 1. What is ready

| | Where | Notes |
|---|---|---|
| Android App Bundle | `build/app/outputs/bundle/release/app-release.aab` | Signed with the upload key (`CN=Zunia Lab`, SHA-256 `89:15:A3:03:…:74:62:99`). Targets SDK 36. Every 64-bit native library is 16 KB aligned, as Play requires. |
| iOS release build | `flutter build ipa --no-codesign` passes | iPhone only. Privacy manifest: no tracking, no data collected. App Store export options are in `ios/ExportOptions.plist`. |
| Store texts | `fastlane/metadata/android/en-US/`, `fastlane/metadata/ios/en-US/` | Every field is within its store's limit. Fees are disclosed (0.5% swap fee). |
| Play graphics | `fastlane/metadata/android/en-US/images/` | `icon.png` (512×512), `featureGraphic.png` (1024×500), `phoneScreenshots/` (1080×1920). |
| App Store screenshots | `fastlane/screenshots/en-US/` | iPhone 6.9″ (1320×2868), the size App Store Connect requires. |

The screenshots come from a test wallet with almost no funds. For a stronger listing, retake them with a funded demo wallet:

```bash
ZUNIA_SHOTS=<dir> flutter drive --driver=test_driver/integration_test.dart --target=integration_test/tour_test.dart -d <iPhone 17 Pro Max simulator>
```

Then frame them the same way.

## 2. The Play upload key

- **Keystore and passwords:** `~/Projects/BDan/zunia/.secrets/android-upload/zunia-upload.jks` and `key.properties` (mode 600).
- **Back up both now.** Put a copy in a password manager and an offline copy somewhere safe.
- **Recovery:** a lost upload key can be replaced through Play's upload key reset, but that takes days.
- **The build reads it from** `android/key.properties`, which is git-ignored. Without that file, a release build is signed with the debug key, and Play refuses debug-signed bundles.

## 3. Google Play (Play Console)

1. **Create the app.**
   - Package `com.zuniawallet.zunia_mobile`. It can never change.
   - App, free, default language English (US).
2. **Signing.**
   - Accept Play App Signing.
   - Upload `app-release.aab` to **Internal testing** first.
   - That first upload registers the upload key above.
3. **Personal developer accounts** created after 13 November 2023 must run a closed test with at least 12 testers for 14 days in a row before production. Organization accounts are exempt.
4. **App content.**
   - Privacy policy: https://zunialab.com/legal/privacy.
   - Ads: none.
   - App access: no login needed.
   - Target audience: 18+.
   - Content rating: fill in the questionnaire.
   - Data safety: no data collected or shared. Traffic is encrypted in transit.
   - Financial features: cryptocurrency wallet, non-custodial.
5. **Store listing.**
   - Texts and graphics: `fastlane/metadata/android/en-US/`.
   - Category: Finance. Contact: dev@zunialab.com. Website: https://zunialab.com.
6. **App Links, once Play App Signing is on.**
   - Copy the **app signing** key's SHA-256 from Play Console → Test and release → Setup → App signing.
   - Paste it into `zunia-website/public/.well-known/assetlinks.json`, in place of `REPLACE_WITH_PLAY_APP_SIGNING_SHA256`. zunialab.com and link.zunialab.com both serve this file.
   - Until then, https connect links open the website, not the app. `zunia://` links and the in-app scanner work either way.

## 4. App Store (App Store Connect)

1. **Choose the team. This blocks submission.**
   - Apple accepts wallets only from developers enrolled **as an organization** (App Review Guideline 3.1.5(b)(i)).
   - The project is set to team `683ATPM9Y6`, whose certificates carry a person's name ("Dan Baruka"), so it looks like an individual enrollment.
   - Two ways forward:
     - publish under an organization team, such as Zedeal Group Hub Ltd (`64JHX3M6XH`), which already holds `com.zunialab.Zunia`;
     - or enroll Zunia Lab as an organization.
   - Then set that team in Xcode (Runner → Signing & Capabilities) and as `teamID` in `ios/ExportOptions.plist`.
2. **Sign in to Xcode** with an Apple ID in that team: Xcode → Settings → Accounts.
3. **Create the app.**
   - Bundle ID `com.zuniawallet.zuniaMobile`, registered in the chosen team, with the Associated Domains capability.
   - Name "Zunia Wallet", SKU `zunia-mobile`, primary language English (U.S.), category Finance.
4. **Build, export and upload.**
   ```bash
   flutter build ipa --release --export-options-plist=ios/ExportOptions.plist
   ```
   Upload `build/ios/ipa/*.ipa` with Transporter, or with Xcode → Organizer → Distribute App.
5. **Questionnaires.**
   - **App Privacy:** Data Not Collected, which matches `ios/Runner/PrivacyInfo.xcprivacy`.
   - **Age rating:** answer **Unrestricted Web Access: Yes**, because the built-in browser opens any site.
   - **Export compliance:** the app uses standard encryption (the vault and the end-to-end encrypted connect messages). Answer the questions in App Store Connect. Once the answer is settled, add `ITSAppUsesNonExemptEncryption` to `Info.plist` so App Store Connect stops asking for every build.
6. **Review notes.** Paste this:
   > Zunia is a self-custody wallet: there is no account or login. On first launch, tap "Create a new wallet", accept the two safety statements, and choose a password. Zunia never holds user funds and has no in-app purchases; the 0.5% swap fee is shown before each swap and paid on-chain. To try connecting a website: on a computer, open https://app.zunialab.com, choose Connect wallet → Zunia Mobile, and scan the code with the scan button at the top of Zunia's home screen.
7. **Universal links, once the team is final.**
   - Replace `TEAMID` in `zunia-website/public/.well-known/apple-app-site-association` with the team ID. zunialab.com and link.zunialab.com both serve this file.

## 5. Once the apps are live

1. Swap "coming soon to the App Store and Google Play" for links to the listings. The wording is in these places:
   - the dashboard (`MobilePairingPanel.tsx`, `WalletOptions.tsx`, `ConnectionsSection.tsx`, `landing/content.ts`);
   - the website download section;
   - the docs (`use-wallet/mobile.md`, `get-started/compatibility.md`, `faq.md`).
2. Update the docs' `llms` and MCP outputs as well.

## 6. Every later release

1. Raise the version in `pubspec.yaml`. The build number after `+` must always go up.
2. Write the release notes:
   - Play: `fastlane/metadata/android/en-US/changelogs/<build number>.txt`.
   - App Store: `fastlane/metadata/ios/en-US/release_notes.txt`.
3. Build:
   ```bash
   flutter build appbundle --release
   flutter build ipa --release --export-options-plist=ios/ExportOptions.plist
   ```
