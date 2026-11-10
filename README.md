<p align="center"><img src="logo.svg" width="128" alt="Gauge logo"></p>

# Gauge

A small macOS menu bar app that shows how much memory and disk you're using, and what's taking it up.

The icon is two bars - memory on the left, disk on the right. Memory turns orange or red when macOS reports memory pressure, disk turns red once it's over 90% full.

## Memory

- Used out of total, split into apps, wired and compressed, plus the pressure level
- Your top apps by memory. Helpers count toward their app and XPC services toward the app they work for, so Safari's tabs show up under Safari
- Command line tools like `node` or `claude` get their own row, with the command and the folder they're running in
- Quit or force quit from the list. macOS's own processes are never offered

## Storage

- Free space out of total
- The biggest apps, files and folders (500 MB and up) in Applications and your home folder, with when you last opened them
- Show in Finder or Move to Trash, and empty the Trash from there

Right-click the icon for Activity Monitor, Storage Settings, Open at Login and Quit.

## Install

Needs macOS 26 and Xcode 26 (Swift 6.2).

```sh
git clone https://github.com/thisisvaze/Gauge.git
cd Gauge
./bundle.sh install
```

That builds a release, copies Gauge.app to /Applications and opens it. `./bundle.sh` on its own just builds `build/Gauge.app`.

For a complete storage scan, give Gauge Full Disk Access in System Settings > Privacy & Security (the app has a button that takes you there). If you have an Apple Development certificate, `bundle.sh` signs with it so the permission sticks across rebuilds. Without one it signs ad hoc, and you may have to allow it again after each build.

## Tests

```sh
swift test
```

## License

[MIT](LICENSE)
