#!/bin/sh
# Runs the app in Chrome with the LaunchDarkly keys from launchdarkly.json.
cd "$(dirname "$0")" || exit 1
exec flutter run -d chrome --dart-define-from-file=launchdarkly.json
