# Releasing Decanter

## Your values (none of these are secret)

| | |
|---|---|
| Signing identity (sign by this hash) | `755F880D8DBA3C9C44D4244F110D3469DA72F37A` |
| Its name | Developer ID Application: Adam O'Reilly (83YKH78UXW) |
| Team ID | `83YKH78UXW` |
| Bundle id (never changes) | `com.yeobogames.yeobgamer` |
| Bundle | `Decanter.app`, universal (x86_64 + arm64), macOS 14.0 minimum |
| Certificate expires | 1 Feb 2027 |
| Notary credential `build.sh` uses | `perturbazione-notary` (override with `DECANTER_NOTARY_PROFILE`) |

The only secrets are the private key and the notary password, and both stay in the keychain.

## Current state

- Latest release: 1.2.3 (build 6): Decanter installs updates itself (Install and Relaunch). Notarised 26 Sep 2026 (submission `052993ea-43b9-4a14-8e56-96c36720055f`), published as [v1.2.3](https://github.com/adamoadamo/decanter/releases/tag/v1.2.3). The next release needs a new version number.
- From 1.2.3 on, an update is installed from the release's `.zip` asset, which must be signed with the same Developer ID and bundle id, so always attach the notarised zip (`build.sh --release` does). 1.2.2 and earlier only open the release page.
- 1.2.2 (build 5): the new icon, and a game's name is no longer editable. Submission `a83ad9db-cca7-443b-90ed-14f25d8ce7ab`, [v1.2.2](https://github.com/adamoadamo/decanter/releases/tag/v1.2.2).
- 1.2.1 (build 4): bigger icon, Check for Updates in About, a check on every launch. Submission `a5725f1b-b9fe-4a12-a221-7dd1c302a969`, [v1.2.1](https://github.com/adamoadamo/decanter/releases/tag/v1.2.1).
- 1.2 (build 3), the first under the name Decanter: notarised 26 Sep 2026 (submission `f7247e56-08c4-4a7d-9666-b0ccf1a6875d`), published as [v1.2](https://github.com/adamoadamo/decanter/releases/tag/v1.2). It checks for updates at most once a day.
- Before that: 1.1 (build 2), still called Yeobgamer, in `dist/Yeobgamer-1.1.zip` (submission `fdd63246-bbef-4443-b407-58b442f3b05d`). 1.0 (`8586e538-…`) is still in `dist/`.
- 1.1 has no update check, so testers on 1.1 need 1.2 sent to them once. From 1.2 on, Decanter tells them about new releases itself.
- Checked in the notarised 1.1: the CrossOver engine's libraries (FreeType, MoltenVK) load in the game process, so hardened runtime doesn't block the `DYLD_FALLBACK_LIBRARY_PATH` passed to Wine. Gatekeeper accepted it (`source=Notarized Developer ID`), the ticket was stapled, and it's signed with hardened runtime, a secure timestamp and no entitlements.

## To publish a release

This is what shows existing copies of Decanter an "update available" alert. Decanter checks
`github.com/adamoadamo/decanter` for the latest release every time it opens. Decanter → Check for Updates… and the
button in About Decanter check straight away.

1. Bump `CFBundleShortVersionString` (and `CFBundleVersion`) in `Resources/Info.plist`. Releases are tagged `v` plus that version, e.g. `v1.3`.
2. Write the release notes for players in `release-notes/<version>.md`. The start of it appears in the update alert.
3. Commit everything.
4. From a terminal on an unlocked Mac, run:

```
./build.sh --release
```

It checks the notes, your GitHub login (`gh auth status`) and that the version isn't already released before it starts, then does everything `--notarise` does (below), pushes your commits, and creates the GitHub release with the notarised zip attached.

To see what players see, open github.com/adamoadamo/decanter/releases. To take a bad release back, delete it there (or `gh release delete v1.3 --repo adamoadamo/decanter`); copies that haven't updated stop being offered it.

## To notarise without releasing

1. Bump `CFBundleShortVersionString` (and `CFBundleVersion`) in `Resources/Info.plist`.
2. From a terminal on an unlocked Mac, run:

```
./build.sh --notarise
```

That one command does the whole job:

- builds arm64 and x86_64 separately (Command Line Tools can't do both in one build) and merges them with `lipo`
- signs by hash with hardened runtime and a secure timestamp, with no entitlements
- zips with `ditto`, submits, and waits (usually one to two minutes)
- stops if Apple says anything but Accepted, and prints the `notarytool log` command to run
- staples the ticket, validates it, and checks that `spctl` says `source=Notarized Developer ID`. Stapling happens on a copy in a temporary folder: `stapler` fails with Error 73 on paths containing a space, and this project lives in "untitled folder".
- writes the stapled app to `dist/Decanter-<version>.zip`, ready to share

Plain `./build.sh` (no flag) makes a quick ad-hoc-signed build that only runs on this Mac.

## What notarisation covers

Only the launcher itself. Wine isn't in the bundle: Decanter downloads it on first run into `~/Library/Application Support/Decanter/`. Because the app downloads it itself, those files aren't quarantined and Gatekeeper doesn't check them, so an unsigned Wine build doesn't block a notarised Decanter.

## If notarytool can't find the credential

`Error: No Keychain password item found for profile: perturbazione-notary` usually means the screen is locked. `notarytool` keeps the password in keychain storage that macOS won't read while the Mac is locked. Unlock and run it again.

## To notarise a bundle by hand

Run these from a folder whose path has no spaces, or `stapler` fails with Error 73:

```
ditto -c -k --keepParent build/Decanter.app Decanter.zip      # ditto, never zip
xcrun notarytool submit Decanter.zip --keychain-profile perturbazione-notary --wait
xcrun stapler staple build/Decanter.app
spctl -a -vvv -t install build/Decanter.app     # must say: source=Notarized Developer ID
codesign -dv --verbose=4 build/Decanter.app     # must say: Notarization Ticket=stapled
```

If Apple returns Invalid, this shows the reason:

```
xcrun notarytool log <submission-id> --keychain-profile perturbazione-notary
```

## Storing a credential under the app's own name (optional)

Create an app-specific password at appleid.apple.com → Sign-In and Security → App-Specific Passwords, then:

```
xcrun notarytool store-credentials decanter-notary \
  --apple-id <your-apple-id> --team-id 83YKH78UXW --password <app-specific-password>
```

Then either run `DECANTER_NOTARY_PROFILE=decanter-notary ./build.sh --notarise`, or change the default near the top of `build.sh`. With a separate profile, rotating one project's password doesn't break the other.
