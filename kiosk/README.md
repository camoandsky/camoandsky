# Signage kiosk

Turns an old laptop into a screen that boots straight into a fullscreen web
page, never sleeps, and shows whatever URL `screens.json` assigns it.

Read this on your phone — step 2 erases the laptop.

## What you need

- A USB stick, 4 GB or bigger (it gets erased)
- The Wi-Fi name and password
- The laptop plugged into its charger
- Optional: a free [Tailscale](https://tailscale.com) account on your phone, for remote access

## 1. Make the install USB (on the laptop, while it's still Windows)

1. Copy off anything on the laptop you want to keep.
2. Go to <https://www.debian.org/download> and download the **amd64 netinst ISO**
   (`debian-13.x.x-amd64-netinst.iso`, about 750 MB).
3. Download **Rufus** from <https://rufus.ie> and run it.
4. Device: your USB stick. Boot selection: the Debian ISO. Click **Start**.
   If it asks "ISO Image mode" or "DD Image mode", pick **DD Image mode**.
5. When Rufus says READY, leave the USB plugged in.

## 2. Boot from the USB

1. Restart the laptop and immediately tap **Esc** repeatedly until a menu appears.
2. Press **F9** (Boot Device Options) and pick the USB stick.
3. If the USB isn't listed: Esc → **F10** (BIOS Setup) → Boot Options → enable USB boot, save, retry.

## 3. Install Debian

Choose **Graphical install**, then:

| Screen | Answer |
|---|---|
| Language / location / keyboard | Defaults |
| Network | Pick your Wi-Fi and enter the password. If it mentions missing firmware, continue. |
| Hostname | `rw-hallway` |
| Domain name | Leave blank |
| **Root password** | **Leave blank** (both boxes). This makes your user an admin. |
| Full name / username | e.g. `admin` — pick a password and **write it down** |
| Partitioning | Guided – use entire disk → the laptop's disk (**not** the USB) → All files in one partition → Finish → Yes |
| Scan extra media / mirror / proxy | No / defaults / blank |
| Popularity contest | No |
| **Software selection** | **Uncheck** "Debian desktop environment" and "GNOME". **Check** "SSH server" and "standard system utilities". |
| Install GRUB | Yes, on the laptop's disk |

When it says installation complete, pull the USB and click Continue. It reboots
to a black text login prompt — that's correct.

## 4. Run the kiosk installer

Log in with the username and password from step 3, then type:

```
wget -qO kiosk.sh https://raw.githubusercontent.com/camoandsky/camoandsky/claude/code-connections-tokens-p5evlu/kiosk/install.sh
sudo bash kiosk.sh rw-hallway
```

It takes 5–15 minutes. Near the end it shows a **QR code**: scan it with your
phone and log in to Tailscale (or press Ctrl+C there to skip remote access).
The laptop then reboots and the hallway page fills the screen.

If anything errors, take a photo of the screen and send it to Claude.

## Changing what a screen shows

Edit [`screens.json`](screens.json) on GitHub (pencil icon works on a phone)
and commit. The screen picks it up within about 5 minutes.

```json
{
  "screens": {
    "rw-hallway": { "url": "https://rosewoodwi.com/rw-hallway" }
  }
}
```

To add another screen, add an entry, then install a second laptop with
`sudo bash kiosk.sh <new-screen-name>`.

## Remote access

With Tailscale on your phone or computer: `ssh admin@rw-hallway`, or use
Tailscale SSH from the Tailscale admin console.

## Good to know

- **Display:** if an HDMI TV is plugged in, the page shows on the TV; otherwise on the laptop screen.
  Closing the lid does not sleep the laptop.
- **Self-healing:** the browser restarts automatically if it crashes, and every night at 4:00.
  Security updates install automatically and reboot at 4:30 when needed.
- **Battery:** it lives on the charger, so the battery will wear over time.
  Some HP BIOSes (F10 → Advanced → Power) have a battery-care / charge-limit setting worth turning on.

## Troubleshooting (at the laptop)

| Problem | Fix |
|---|---|
| Need a command prompt | **Ctrl+Alt+F2**, log in. **Ctrl+Alt+F1** returns to the screen. |
| Page wrong or stale | `sudo systemctl start kiosk-sync` then `sudo pkill chromium` |
| See what happened | `sudo cat /home/kiosk/kiosk.log` and `journalctl -u kiosk-sync -n 50` |
| No Wi-Fi | `ip a` to check; `sudo nano /etc/network/interfaces` holds the Wi-Fi settings |
