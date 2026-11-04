# Yorishiro guide

[繁體中文](guide.zh-TW.md)

- [Getting started](#getting-started)
- [Hotkeys](#hotkeys)
- [OBS](#obs)
- [Virtual camera](#virtual-camera)
- [Left and right](#left-and-right)
- [iPhone tracking](#iphone-tracking)
- [Several people on one computer](#several-people-on-one-computer)
- [Troubleshooting](#troubleshooting)

## Getting started

1. Download the AppImage from [Releases](https://github.com/koshizuow/yorishiro/releases), then
   `chmod +x Yorishiro-<version>-x86_64.AppImage` and run it.
2. The card on the stage walks you through choosing a model, checking face tracking and placing the model.
   A Live2D model is a folder with a `.model3.json` file. Models in `~/.local/share/yorishiro/Live2DModels/` show up
   by themselves.
3. Look straight at the camera with a relaxed face for a moment, or use **Auto calibrate** on the Sensitivity page.
   It goes one step at a time, so you can read each step before you do it.
4. Drag the model to move it, scroll or pinch to resize it, and hold Shift and scroll to tilt it. The gear in the corner
   opens all settings.
5. To get Yorishiro in the application menu with its icon in the dock, press **Add to application menu** on the About
   page. Press it again if you move the file. The file itself may keep a generic icon in the file manager: that depends
   on your desktop.

## Hotkeys

If the model comes with hotkeys, they are ready when it loads. To see or change them, open the **Hotkeys** page in
Settings. A model must be loaded.

- **Change the keys:** click the keys of a hotkey, then hold the new keys together, up to three, such as Ctrl+M or
  Tab+F1. They are set when you let go. Esc cancels and Backspace clears.
- **Add one:** press **Add hotkey**, then choose what it does: an expression, an animation or an app action.
- **Hold:** with Hold on, the hotkey is active only while you keep the keys down.

Keyboard hotkeys work while the app's window has focus. To use them from other windows, for example with OBS or a game
in front, add your user to the `input` group and log in again:

```sh
sudo usermod -aG input $USER
```

With this group every program you run can read the keyboard, so only add it if you need it. Check it with `id -nG`.

## OBS

The stage goes to OBS with a transparent background, without the app's buttons and menus.

You need:

- PipeWire 1.4 or newer. Ubuntu 25.10 and 26.04 and Debian 13 have it. Ubuntu 24.04 and Linux Mint 22 ship 1.0, and the
  app runs there without this output unless PipeWire is updated.
- The Vulkan renderer, which is the default.
- OBS 32 or newer with the [obs-pwvideo](https://github.com/hoshinolina/obs-pwvideo) plugin, a separate project.
  OBS does not load a plugin built for a newer OBS, and the plugin's releases are built for OBS 32. Ubuntu 26.04 ships
  OBS 32. Debian 13 and Ubuntu 25.10 ship OBS 30: use the Flatpak OBS there.

Download the plugin from [its releases](https://github.com/hoshinolina/obs-pwvideo/releases) and install it for the OBS you use:

- **OBS from your distribution** (apt, dnf, pacman): unpack `obs-pwvideo-<version>-x86_64-ubuntu-gnu.tar.xz` into your
  OBS settings:

  ```bash
  mkdir -p ~/.config/obs-studio/plugins
  tar xJf obs-pwvideo-<version>-x86_64-ubuntu-gnu.tar.xz -C ~/.config/obs-studio/plugins
  ```

  On Ubuntu and Debian the `.deb` works too and installs it for every user:
  `sudo apt install ./obs-pwvideo-<version>-x86_64-linux-gnu.deb`.
- **OBS from Flathub** (`com.obsproject.Studio`): the Flatpak keeps its settings elsewhere, so unpack the same file
  there:

  ```bash
  mkdir -p ~/.var/app/com.obsproject.Studio/config/obs-studio/plugins
  tar xJf obs-pwvideo-<version>-x86_64-ubuntu-gnu.tar.xz -C ~/.var/app/com.obsproject.Studio/config/obs-studio/plugins
  ```

Restart OBS. Its log (Help, Log Files) then shows `[obs-pwvideo] plugin loaded successfully`.

Then:

1. In Yorishiro, turn on **Send the stage to OBS (PipeWire, transparent)**.
2. In OBS, add a **PipeWire video** source and pick Yorishiro.

The app keeps sending frames while its window is covered or minimized, so OBS can sit on top of it.

## Virtual camera

For apps that only take a camera, such as Google Meet. A camera has no transparency, so it shows the app's background:
the image or color you chose, and black in transparent mode. Change the background and the camera follows.

On Ubuntu:

```sh
sudo apt install v4l2loopback-dkms
sudo modprobe v4l2loopback devices=1 video_nr=20 card_label="Yorishiro" exclusive_caps=1
```

The `modprobe` line lasts until you reboot. The app shows this command when it finds no device, and **Check again** looks
for the device without a restart. Then choose the device in the camera panel, turn the virtual camera on, and pick
**Yorishiro** as the camera in the other app.

The picture keeps the size it had when the camera started, and a resized window is scaled to fit it, so the other app
keeps working.

## Left and right

Yorishiro works like a mirror. Look to your right and the model turns to the right side of the screen.

OBS, your stream and the people in a call see the same picture as the app's window. Video call apps such as Google Meet
usually flip **your own preview** only, so your preview can look reversed compared to the app while everyone else sees it
the right way round.

## iPhone tracking

An iPhone with VTube Studio can track your face instead of the webcam. The app on the phone sends its tracking the way
it does for VSeeFace, and that part is free.

On the iPhone:

1. Connect to the same Wi-Fi as the computer. Turn off mobile data if the IP below does not look like your other
   devices' (for example `192.168.x.x`).
2. In VTube Studio, tap the camera button once so tracking starts.
3. Open the settings (the gear), scroll down to the **VSeeFace** part and turn on **Activate**.
4. Press **Show IP list** and note the IPv4 address. The port is always 21412.
5. Optional: turn off **Streaming Mode** under the PC connection, or the screen darkens once the computer connects.

In Yorishiro, open the camera panel, choose **iOS BlendShapes (VTS)** as the tracking source, enter the phone's IPv4
address as **Hostname (Phone)** and press **Connect to Mobile**. The computer appears under **Connected VSF Clients** on
the phone.

- Keep VTube Studio open on the phone, with the screen on. The model stops while the app is in the background.
- If nothing arrives, the computer's firewall may be blocking UDP port 50650, which the data comes in on. With ufw:
  `sudo ufw allow 50650/udp`.
- The model works like a mirror, as with the webcam.

## Several people on one computer

Open the app again. Each copy takes the next number, or choose one with `--instance=2`.

- Each copy has its own settings and takes a free camera. The model library is shared.
- OBS streams are named `Yorishiro`, `Yorishiro-2` and so on. Plugin ports are 8001, 8002 and so on.
- Two copies cannot read one camera at the same time. The second shows the camera as busy and keeps running.

Every copy runs its own tracking, so the limit depends on your computer.

## Troubleshooting

| What you see | What to do |
|---|---|
| The window takes about a minute to appear on Wayland | The desktop portal is not answering. Install and start the backend for your desktop, for example `xdg-desktop-portal-wlr` or `xdg-desktop-portal-hyprland`. |
| Keyboard hotkeys do nothing | Click the app's window so it has focus. For other windows see [Hotkeys](#hotkeys). |
| No Yorishiro source in OBS | Check that **Send the stage to OBS** is on, then check the plugin against your OBS version. |
| No device in the virtual camera list | Run the `modprobe` line from [Virtual camera](#virtual-camera), then press **Check again**. It is needed again after a reboot. |
| iPhone tracking stays on Listening | Check the phone's IP and that it is on the same Wi-Fi, see [iPhone tracking](#iphone-tracking). |
| Camera busy | Another app or another copy has the camera. Close it, or choose another camera. |
