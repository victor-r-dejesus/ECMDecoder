# ECMDecoder

A small macOS app that converts `.ecm` disc images back to `.bin`, and can write a matching `.cue` file for emulators. It was built with PlayStation (PSX) games in mind, but it works with any CD image that was compressed with ECM.

ECM ("Error Code Modeler", by Neill Corlett) shrinks CD images by stripping the error-correction data that can be recomputed. ECMDecoder rebuilds that data, so the output is byte-for-byte the original image.

## Features

- **Drag and drop.** Drop a `.ecm` file onto the window and pick an output folder.
- **Exact output.** Rebuilds mode 1, mode 2 form 1 and mode 2 form 2 sectors, and copies raw data as is. The checksum stored in the `.ecm` file is verified, so a damaged file is reported instead of producing a broken image.
- **Optional `.cue` file.** Detects MODE1/2352 or MODE2/2352 from the first sector. If the image type isn't clear, the `.cue` is skipped and the log explains why.
- **Progress and cancel.** Shows progress with an ETA. Cancel at any time.
- **Safe with existing files.** The image is written to a hidden temporary file and only moved into place when decoding succeeds. A failed or cancelled decode never overwrites an existing `.bin`.
- **Handles large images.** Input is memory-mapped and output is streamed to disk, so a 700 MB CD image doesn't need to be held in memory.

## Installing

Download the latest `ECMDecoder-<version>.dmg` from the [Releases](https://github.com/victor-r-dejesus/ECMDecoder/releases) page, open it, and drag **ECMDecoder** to **Applications**. Requires macOS 12 or later, on Apple silicon or Intel.

The app is not notarized, so macOS blocks the first launch. Right-click (or Control-click) ECMDecoder in Applications, choose **Open**, then confirm. On macOS 15 and later, go to **System Settings → Privacy & Security** and click **Open Anyway**.

## Usage

1. Drag a `.ecm` file onto the drop area.
2. Leave **Generate .cue file** on if you want a `.cue` sheet.
3. Click **Decode** and choose an output folder.
4. Follow progress in the log. Click **Cancel** to stop, or **Clear** to drop the selected file.

Output is named after the input with the `.ecm` (and any `.bin`) extension removed. For example, `Game.bin.ecm` becomes `Game.bin` and `Game.cue`.

## Building

| Path | Purpose |
| --- | --- |
| `App/ECMDecoderApp.swift` | App entry point |
| `App/ContentView.swift` | SwiftUI window: drop area, buttons, progress, log, `.cue` creation |
| `Sources/ECMDecoderCore/ECMDecoder.swift` | ECM format decoder, with ECC/EDC sector reconstruction |
| `Tests/ECMDecoderTests/` | Unit tests for the decoder, with a fixture made by the reference `ecm` tool |
| `scripts/build-app.sh` | Builds the app and the DMG |

On a Mac with Xcode or the Command Line Tools installed:

```bash
swift test
```

```bash
scripts/build-app.sh 1.0.0
```

The first command runs the decoder's unit tests. The second builds a universal `build/ECMDecoder.app` and packages it as `build/ECMDecoder-1.0.0.dmg`. The decoder only uses Foundation, so `swift test` also runs on Linux.

To work on the app in Xcode instead, create a **macOS → App** project with the SwiftUI interface, delete the template's `ContentView.swift` and `<Name>App.swift`, and add the two files in `App/` plus `Sources/ECMDecoderCore/ECMDecoder.swift` to the app target.

## Releasing

Push a version tag. The [Release workflow](.github/workflows/release.yml) runs the tests, builds the DMG on a macOS runner, and publishes a GitHub release with the DMG attached:

```bash
git tag v1.0.0
```

```bash
git push origin v1.0.0
```

You can also start a release without a local tag: on GitHub, open **Actions → Release → Run workflow**, enter the version (for example `1.1.0`), and the workflow creates the `v1.1.0` tag on that commit.

Every push and pull request also runs the tests and builds the DMG through the [CI workflow](.github/workflows/ci.yml).

## Credits

The ECM format and the reference `ecm` and `unecm` tools are by Neill Corlett. This decoder is an independent Swift implementation, checked against the reference `unecm` output.
