# Promptlist

A private iPhone app that builds Apple Music playlists from **songs already in
your library**, based on a prompt like *"late-night drive, synthy and moody"*.

1. The app reads your library with MusicKit.
2. An AI picks and orders songs from it that fit your prompt. You choose which
   AI in Settings:
   - **Apple Intelligence (free, the default)** runs on the iPhone, so nothing
     leaves the phone. It needs an iPhone 15 Pro or newer on iOS 26 with Apple
     Intelligence turned on. Its picks are simpler because it can only read a
     short list at a time (see [How the Apple Intelligence mode works](#how-the-apple-intelligence-mode-works)).
   - **Gemini (free tier)** reads a compact listing of your whole library
     (artist, album, year, genre, play count) and is fast. It needs a free
     Google AI Studio API key; Google limits free requests per minute and per
     day, and may use free-tier requests to improve its products.
   - **Claude (paid)** reads the same listing and makes the best picks. It
     needs an Anthropic API key.
3. You can edit the result, remove or reorder songs, or ask for changes
   ("more upbeat", "no rap").
4. **Save to Music** creates the playlist in your Apple Music library.

It's built with Flutter, so you can work on it from Windows. The iOS build,
signing and TestFlight upload run on GitHub's Mac machines, so you never need
a Mac.

## What you need

- An Apple Developer Program membership (you have one).
- An iPhone on iOS 16 or later with Apple Music, and **Sync Library** turned on
  (Settings › Apps › Music).
- One of:
  - Apple Intelligence: an iPhone 15 Pro or newer on iOS 26 with Apple
    Intelligence on.
  - Gemini: a free API key from <https://aistudio.google.com> › Get API key.
  - Claude: an Anthropic API key with some credit
    (<https://console.anthropic.com> › API Keys).
- This GitHub repository.

## One-time setup

Everything below happens in a web browser, plus one PowerShell command.

### 1. Register a bundle ID with MusicKit

1. Go to <https://developer.apple.com/account/resources/identifiers/list> and
   click **+**.
2. Choose **App IDs** › **App**. Enter a description (`Promptlist`) and an
   explicit bundle ID such as `com.yourname.promptlist`.
3. Open the **App Services** tab and tick **MusicKit**. Click **Continue**,
   then **Register**.

MusicKit lets the app read your library and create playlists. Without it the
app can't see any songs.

### 2. Create the app in App Store Connect

1. Go to <https://appstoreconnect.apple.com/apps>, click **+** › **New App**.
2. Platform **iOS**; any name (it must be unique on the App Store, so try
   something like `Promptlist Yourname`); the bundle ID from step 1; any SKU
   (e.g. `promptlist`).

You won't submit it for review. It stays private and only reaches your phone
through TestFlight.

### 3. Create an App Store Connect API key

1. In App Store Connect go to **Users and Access** › **Integrations** ›
   **App Store Connect API** › **Team Keys** and click **+**. (The first time,
   you may have to request API access.)
2. Name it `GitHub Actions` and choose **App Manager** access. If signing later
   fails with a permissions error, make a new key with **Admin** access.
3. **Download** the `.p8` file (you only get one chance) and note the
   **Key ID** and the **Issuer ID** shown above the list.

### 4. Create a signing key

In PowerShell, in any folder *outside* this repo:

```powershell
ssh-keygen -t rsa -b 2048 -m PEM -f cert_key -q -N '""'
```

This creates `cert_key`. The build uses it to create and reuse your
distribution certificate, so you never deal with certificates yourself. Keep it
safe.

### 5. Add the secrets to GitHub

In this repository go to **Settings** › **Secrets and variables** › **Actions**.

On the **Secrets** tab, add:

| Name | Value |
| --- | --- |
| `APP_STORE_CONNECT_ISSUER_ID` | Issuer ID from step 3 |
| `APP_STORE_CONNECT_KEY_IDENTIFIER` | Key ID from step 3 |
| `APP_STORE_CONNECT_PRIVATE_KEY` | Entire contents of the `.p8` file, including the `BEGIN`/`END` lines |
| `CERTIFICATE_PRIVATE_KEY` | Entire contents of `cert_key`, including the `BEGIN`/`END` lines |

On the **Variables** tab, add `BUNDLE_ID` = your bundle ID from step 1
(e.g. `com.yourname.promptlist`).

### 6. Build and upload

Start the **TestFlight** workflow in any of these ways:

- **Actions** tab › **TestFlight** › **Run workflow**. This button only
  appears once the workflow is on the `main` branch.
- Push a commit whose message contains `[testflight]`.
- Push a tag starting with `testflight-` (e.g. `testflight-2`). You can create
  one on GitHub under **Releases** › **Draft a new release**.

The build takes about 5–15 minutes. Afterwards App Store Connect needs a few
more minutes to process it. You'll get an email when it's ready.

### 7. Install it on your iPhone

1. In App Store Connect open your app › **TestFlight** › **Internal Testing**
   › **+**. Create a group (e.g. `Me`), add yourself, and turn on
   **Automatic distribution** so new builds reach you without extra steps.
2. On your iPhone install **TestFlight** from the App Store and sign in with
   the same Apple ID. Accept the invite and tap **Install**.

TestFlight builds expire after 90 days. Start the workflow again to get a
fresh one.

## Using the app

1. Tap **Connect** and allow access to Apple Music.
2. Apple Intelligence works right away. To use Gemini or Claude instead, open
   **Settings** (gear icon), choose it under **Who picks the songs** and paste
   its API key. You can also pick the model.
3. Describe the playlist, choose a rough length, and tap **Create playlist**.
4. On the preview, swipe a song left to remove it, hold and drag to reorder,
   edit the name, or tap **Refine** to ask for changes.
5. Tap **Save to Music**. The playlist appears under Library › Playlists in the
   Music app.

Prompts can refer to your listening habits ("my most played", "stuff I've
barely listened to") because the listing includes play counts.

## How the Apple Intelligence mode works

Apple's on-device model can only read a few thousand words at a time, so it
never sees your whole library. Instead:

1. It turns your prompt into search criteria: genres (chosen from the genres in
   your library), artists, title keywords, a year range, and whether to favor
   songs you play a lot or rarely.
2. The app scores every song in your library against those criteria and keeps
   the best 30–80, with at most a few per artist.
3. The model picks and orders songs from that shortlist.

**Refine** adds your feedback to the original prompt and runs these steps
again.

## What it costs

Apple Intelligence costs nothing. Gemini's free tier costs nothing either, up
to Google's per-minute and per-day limits (see yours at aistudio.google.com ›
Usage). If Google retires the default model, change the model ID in Settings.

With Claude, each new playlist sends your library listing to Claude, about 10
tokens per song. With Claude Opus 5 (the default Claude model), a 5,000-song
library comes to roughly 30 cents of input per new playlist; Claude Sonnet 5 is
about 60% cheaper.
Refinements within 5 minutes reuse a cached copy of the listing and cost a
fraction of that. Settings shows an estimate for your actual library.

Libraries over roughly 6,000 songs are handled in two steps: Claude first
shortlists artists from a one-line-per-artist summary, then picks songs from
those artists only.

## Working on it from Windows

1. Install Flutter: <https://docs.flutter.dev/get-started/install/windows>.
2. In this folder run `flutter pub get`, then:
   - `flutter test` runs the tests.
   - `flutter run -d chrome` runs the app in Chrome with a built-in **demo
     library** of 60 songs. Claude calls are real (add your key in Settings);
     saving a playlist is simulated.
3. Push to GitHub. The **CI** workflow runs the tests and compiles the iOS app
   on every push. Run the **TestFlight** workflow when you want the new
   version on your phone.

### Where things are

| Path | What it does |
| --- | --- |
| `lib/services/library_catalog.dart` | Turns your library into the compact listing Claude reads |
| `lib/services/playlist_generator.dart` | Prompts, artist shortlisting for big libraries, refinement |
| `lib/services/claude_client.dart` | Calls the Claude Messages API with structured JSON output |
| `lib/services/gemini_client.dart` | Calls the Gemini API (`generateContent`) with JSON output |
| `lib/services/on_device_generator.dart` | Free mode: search criteria, library ranking, shortlist picking |
| `ios/Runner/OnDeviceModelPlugin.swift` | Apple's on-device model (Foundation Models) |
| `lib/services/music_library.dart` | Dart side of the Apple Music bridge, plus the demo library switch |
| `ios/Runner/MusicLibraryPlugin.swift` | MusicKit: permissions, reading songs, creating playlists |
| `lib/ui/` | Home, preview and settings screens |
| `.github/workflows/` | CI and the TestFlight build |

## Troubleshooting

- **"0 songs in your library"**: turn on Sync Library (Settings › Apps ›
  Music), and check that MusicKit is ticked for your bundle ID (step 1).
- **Apple Music access is off**: Settings › Apps › Promptlist › turn on
  Media & Apple Music.
- **The TestFlight workflow fails at "Check configuration"**: a secret or the
  `BUNDLE_ID` variable is missing or misspelled.
- **It fails at "Set up code signing"**: check that the bundle ID exists
  (step 1) and the API key has App Manager or Admin access. If Apple says
  you've hit the certificate limit, revoke an old *Distribution* certificate at
  <https://developer.apple.com/account/resources/certificates/list>.
- **It fails at "Upload to TestFlight"**: make sure the app exists in App Store
  Connect with the same bundle ID (step 2).
- **Claude errors**: the message tells you what's wrong (bad key, no credit,
  rate limit). Check your key and balance at <https://console.anthropic.com>.
