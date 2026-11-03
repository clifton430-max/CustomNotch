# CustomNotch

A small "notch" that you can drag anywhere on your Mac. It sticks to whichever screen edge you drop it on (top, bottom, left or right). Hover over it to open a panel with the date and your CPU, memory and battery usage.

It lives in the menu bar and has no Dock icon.

## Requirements

- macOS 14 (Sonoma) or newer
- Swift 5.10 or newer, which comes with Xcode or the Xcode Command Line Tools. If you don't have either, run:

  ```sh
  xcode-select --install
  ```

## Install

```sh
git clone https://github.com/clifton430-max/CustomNotch.git
cd CustomNotch
./build.sh run
```

`./build.sh` builds `CustomNotch.app` in the project folder, and `./build.sh run` also launches it. To keep it, drag `CustomNotch.app` into `/Applications`.

To start it automatically when you log in, add it under **System Settings → General → Login Items**.

## Using it

| Do this | What happens |
| --- | --- |
| Hover over the notch | It opens and shows the date plus CPU, memory and battery rings |
| Click a ring | Opens a detail panel listing the apps using the most of that resource |
| Click the pin in the open notch | Keeps it open after the mouse leaves |
| Drag the notch | Moves it. Let go near an edge and it springs onto that edge. You can also throw it |
| Menu bar icon (capsule) → **Notch Settings…** (⌘,) | Size, per-edge presets and companion options |
| Menu bar icon → **Reset Position** (⌘R) | Moves it back to its default spot |
| Menu bar icon → **Quit CustomNotch** (⌘Q) | Quits |

On a MacBook with a camera notch, CustomNotch avoids the hardware notch when it's docked to the top edge.

### Settings

- **General**: where the notch is docked, and resetting its position.
- **Appearance & Size**: width, height and overall scale, saved separately for each edge.
- **Edge Presets**: the saved size for each of the four edges.
- **Companion**: cookie frequency, the cookie button, and how long messages stay after you read them. These only matter when the companion app is running (see below).

## Optional: Terraria Companion

CustomNotch can host a character from the Terraria Companion desktop app. Drag or throw a companion onto the notch and she moves in. She lives in a small room inside the opened notch, leaves messages there (the notch glows pink until you open it), and has a pouch button that opens her inventory. Drag her out of the notch to put her back on the desktop.

The two apps talk over `http://127.0.0.1:47834`. If the companion app isn't running, CustomNotch works on its own and the companion features stay hidden.

## Troubleshooting

- **"CustomNotch can't be opened"** after copying the app from another Mac: the app is only ad-hoc signed. Right-click it and choose **Open**, or run `xattr -dr com.apple.quarantine CustomNotch.app`. Building it yourself with `./build.sh` avoids this.
- **Notch is off-screen** after unplugging a monitor: use **Reset Position** from the menu bar icon.
