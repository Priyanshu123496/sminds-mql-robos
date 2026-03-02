# TTR-X Mobile Helper (Android + iPhone)

Simple Expo React Native app to encode/decode:

- `Fast EMA <-> InpP2`
- `Slow EMA <-> InpP3`
- `Filter EMA <-> InpP4`

## Run locally

```powershell
cd "C:\SMINDS\projects\sminds-mql-robos\mt5\Production Ready EA\ttrx-mobile-app"
npm install
npx expo start
```

Then:

- Press `a` for Android emulator/device.
- Press `i` for iOS simulator (macOS required), or scan QR via Expo Go.

## Build app binaries

Use EAS (Expo Application Services):

```powershell
npm install -g eas-cli
eas login
eas build:configure
eas build -p android
eas build -p ios
```

## Formula used in app

- `InpP2 = ((FastEMA + 11) * 17) XOR 913`
- `InpP3 = ((SlowEMA + 17) * 19) XOR 1291`
- `InpP4 = ((FilterEMA + 23) * 29) XOR 2087`
