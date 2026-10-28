# weather_app

A Flutter app that shows today's weather for a city. It gets the data with REST
calls to [Open-Meteo](https://open-meteo.com), which is free and needs no API key.

- `GET geocoding-api.open-meteo.com/v1/search?name=<city>` looks up the city's coordinates
- `GET api.open-meteo.com/v1/forecast?...&current=...&daily=...` gets current conditions and today's high and low

## Setup

```bash
flutter create --platforms=ios,android,macos,web .   # generates platform folders; keeps lib/ and pubspec.yaml
flutter pub get
flutter test
cp launchdarkly.example.json launchdarkly.json   # then fill in your LaunchDarkly keys
flutter run --dart-define-from-file=launchdarkly.json
```

Without `launchdarkly.json` the app still runs, using flag fallbacks.

The Weather Twins backend lives in `twins_backend/`: copy `.env.example` to
`.env`, fill it in, and run `twins_backend/go.sh`.

Keys only go in `launchdarkly.json` and `twins_backend/.env`, which are
gitignored. Never commit them.

### Network permissions
- **macOS**: add this to `macos/Runner/DebugProfile.entitlements` and `Release.entitlements`:
  ```xml
  <key>com.apple.security.network.client</key><true/>
  ```
- **Android (release builds)**: add
  `<uses-permission android:name="android.permission.INTERNET"/>` to
  `android/app/src/main/AndroidManifest.xml`.
- iOS and web work without changes.
