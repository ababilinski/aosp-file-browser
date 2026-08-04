# Features

ASOP File Browser has two connection modes. **File Transfer Mode** uses a USB cable for everyday file browsing and transfers. **Developer Options** works over USB or Wi-Fi and adds Search Everywhere, Trash, storage details, and Phone Tools.

**No phone app is needed for either mode.**

[Setup](https://ababilinski.github.io/asop-file-browser/connect/) · [Troubleshooting](https://ababilinski.github.io/asop-file-browser/faq/#troubleshooting-title) · [Back to README](README.md)

## Files and folders

These features work with either connection mode.

- **Browse phone storage.** Open folders in a list or icon view and jump to common locations from the sidebar.
- **Expand folders in place.** Open a folder tree without leaving the folder you are viewing.
- **Move around quickly.** Use Back, Forward, Up, breadcrumbs, and the path bar to find your way around.
- **Search the current folder.** Find items by name, file type, or modified date.
- **See hidden items.** Files and folders whose names begin with a dot appear with everything else.
- **Sort your files.** Sort by name, kind, size, or modified date. Optional folder-size calculation fills in folder sizes in the background.
- **Preview before transferring.** Quick Look opens supported files without making you save them first.
- **See thumbnails.** Images and videos show a visual preview when one is available.
- **Check file details.** Get Info shows the name, location, type, size, and available dates.

## Organize and transfer

- **Drag between your phone and Finder.** Drop files or folders in either direction.
- **Drop files into folders.** Move items onto a folder in the file list or an expanded folder tree.
- **Create and rename folders and files.** New items appear in place as soon as the action starts.
- **Copy and paste.** Copy items to another folder on the same phone.
- **Compress and uncompress.** Create an archive or open one without leaving the file browser.
- **Handle duplicate names.** Skip the item, replace the existing copy, or keep both.
- **Follow long work.** The Progress panel shows overall and per-item progress for transfers and multi-APK install queues. Queued installs can be reordered or removed, and failed items keep their error details.
- **Keep browsing during a transfer.** File moves update the browser right away while the work continues in the background. Larger moves show progress.

## File Transfer Mode

File Transfer Mode is the simplest way to move files over USB.

- **No Developer Options required.** Unlock the phone, choose **File transfer / Android Auto**, and select the phone in the Mac app.
- **No extra tools required.** This mode does not depend on debugging tools or a phone app.
- **Common folders are close at hand.** Open Downloads, Music, Pictures, Camera, Movies, SD cards, and other storage exposed by the phone.
- **Permanent deletion.** Items deleted in File Transfer Mode cannot be restored from the app's Trash.

File Transfer Mode is built with [MTPKit 0.1.4](https://github.com/5j54d93/MTPKit/tree/0.1.4), an MIT-licensed Swift library by Ricky Chuang.

## Developer Options

Developer Options adds features that need USB or Wi-Fi debugging.

- **Connect over USB or Wi-Fi.** Pair with the QR code shown on your Mac or use a USB cable.
- **Search Everywhere.** Search shared storage instead of one folder at a time.
- **Use recoverable Trash.** Put items back in their original folder, preview them, or delete them permanently.
- **See storage details.** Review storage by category and find the largest files.
- **See more file information.** Created dates and file permissions appear when they are available.
- **Rename several items at once.** Batch rename files and undo supported file operations.
- **Copy between phones.** Move or copy selected files between two phones connected with debugging.

## Phone Tools

Phone Tools are available with Developer Options enabled.

- **Manage apps.** Drag an APK, XAPK, APKS, or split ZIP from Finder to install it; drop several APKs to create an editable serial install queue; open, stop, enable, disable, or uninstall an app; clear its cache or storage; save its APK; and inspect its version, size, and permissions. Downgrades, signature conflicts, incomplete splits, and other install failures get guided recovery instead of raw command output.
- **Take screenshots.** Capture one or more connected displays. Multiple displays
  are saved side by side in one image.
- **Record the screen.** Record one or more connected displays. Multiple displays
  are saved side by side in one video. Choose system audio, the phone microphone,
  or both for each display, and add the Mac's current system input when needed.
- **Control one or more devices.** Open a separate live screen for each connected device. Every screen has its own Mac control bar for battery level, navigation, volume, rotation, screenshots, and power.
- **Tune each device window.** Choose audio, input, clipboard, frame rate, video format, screen behavior, and window placement for each connected device.

[Learn how to set up Phone Tools](https://ababilinski.github.io/asop-file-browser/phone-tools/)

## Cache and Trash controls

- **Manage preview storage.** Set a cache limit, check its current size, or clear preview and thumbnail files separately.
- **Choose how long previews stay.** Remove previews after a set amount of time, clear them when the app quits, or clear them manually.
- **Encrypt cached previews when needed.** Optional encryption protects preview files stored on the Mac. Leaving it off makes previews open faster.
- **Choose what happens to Trash on quit.** Ask before emptying it, empty it automatically, or keep its contents for the next session.

Some folders and actions can vary by phone and Android version.
