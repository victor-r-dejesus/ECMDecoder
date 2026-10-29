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

## Usage

1. Drag a `.ecm` file onto the drop area.
2. Leave **Generate .cue file** on if you want a `.cue` sheet.
3. Click **Decode** and choose an output folder.
4. Follow progress in the log. Click **Cancel** to stop, or **Clear** to drop the selected file.

Output is named after the input with the `.ecm` (and any `.bin`) extension removed. For example, `Game.bin.ecm` becomes `Game.bin` and `Game.cue`.

## Building

The repository contains the Swift sources only, without an Xcode project:

| File | Purpose |
| --- | --- |
| `ECMDecoderApp.swift` | App entry point |
| `ContentView.swift` | SwiftUI window: drop area, buttons, progress, log, `.cue` creation |
| `ECMDecoder.swift` | ECM format decoder, with ECC/EDC sector reconstruction |

To build:

1. In Xcode, create a new **macOS → App** project named `ECMDecoder`, with the SwiftUI interface and the Swift language.
2. Delete the template's generated `ContentView.swift` and `<Name>App.swift`, then add the three files above to the target.
3. If the App Sandbox is enabled, set **User Selected File** to **Read/Write** under *Signing & Capabilities* so the app can read the dropped file and write to the chosen folder.
4. Build and run.

The decoder (`ECMDecoder.swift`) uses only Foundation and typechecks under Swift 5 and Swift 6 language modes. The UI targets SwiftUI on macOS.

## Credits

The ECM format and the reference `ecm` and `unecm` tools are by Neill Corlett. This decoder is an independent Swift implementation, checked against the reference `unecm` output.
