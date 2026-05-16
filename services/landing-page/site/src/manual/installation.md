---
title: "Installation — HomeFree Manual"
---

# Installation

Once your hardware is wired up (see [Hardware setup](/hardware-setup/)), installing HomeFree itself takes about 20 minutes. It's a guided installer — you'll be picking from on-screen options, not typing commands.

## What you'll need

- The HomeFree box, plugged into your modem and switch.
- A USB stick, **8 GB or larger**. Anything currently on it will be erased.
- Another computer to prepare the USB stick. Mac, Windows, or Linux is fine.
- A monitor and a keyboard to attach to the HomeFree box during the install. After it's done, neither is needed — you'll use HomeFree from your phone or laptop.
- About 20 minutes.

## Step 1 — Download the installer

On any computer, go to **[homefree.host](https://homefree.host/)** and click the green **HomeFree ISO** button on the front page. You'll get a file called something like `homefree-latest.iso`.

## Step 2 — Put the installer on a USB stick

Download a free tool called **balenaEtcher** from [balena.io/etcher](https://www.balena.io/etcher/). It works on Mac, Windows, and Linux.

1. Plug your USB stick into the computer.
2. Open Etcher.
3. **Flash from file** → pick the `homefree-latest.iso` you just downloaded.
4. **Select target** → pick your USB stick. Double-check it's the right one; the USB stick will be erased.
5. **Flash!** Wait a couple of minutes for it to finish.

When Etcher says "Flash complete," you can unplug the USB stick.

## Step 3 — Boot HomeFree from the USB stick

1. Plug the USB stick into the HomeFree box.
2. Plug in the monitor and keyboard.
3. Power on the HomeFree box.
4. As soon as you see the manufacturer logo, repeatedly tap the **boot menu key**. This key is different for every brand — try **F12** first, then **F11**, **F10**, **F8**, **F9**, or **Esc**. (If you blow past it, power off and try again.)
5. From the menu that pops up, pick the USB stick.

The HomeFree installer will load. Give it a minute.

If the box just keeps booting normally instead of showing the boot menu, search online for "boot menu key" plus your computer's brand. You may also need to go into the firmware settings and turn off something called **Secure Boot** — HomeFree's installer isn't signed for it yet.

## Step 4 — Walk through the installer

The installer asks you a few questions on screen:

1. **Which disk to install on?** Pick the SSD inside the HomeFree box. **The disk will be erased** — make sure you don't have anything you want to keep on it.
2. **Pick a username and password.** This is *your* HomeFree login. You'll use it for everything — signing in to your photos, your files, your calendar. One password, every app. Use something strong; a passphrase you can remember is great.
3. **Pick a name for your HomeFree.** This is the web address you'll use to reach your apps from anywhere, like `mycloud.example.com`. If you already own a domain name, type it here. If you don't, the installer will give you one for free (something like `yourname.homefree.host`) — you can swap it for your own later.
4. **Confirm which Ethernet port is which.** The installer detects both ports and asks you to confirm which one your modem is plugged into. If you're not sure, the screen tells you to unplug one cable, watch which port "lost" its connection on screen, and pick that one.
5. **Install.** The installer does its thing — about 10 to 15 minutes. Get a coffee.

When it's done, the screen will show a short web address (something like `https://homefree.lan`). You can unplug the monitor and keyboard now — you're done with this part.

## Step 5 — Sign in for the first time

Grab your phone or laptop. Make sure it's connected to your home Wi-Fi (which is now running through HomeFree).

1. Open a browser and go to **`https://homefree.lan`**.
2. Your browser may show a security warning the first time. That's normal — HomeFree uses its own certificate for in-home access. Click "Advanced" or "Show details" and accept the certificate. You'll only have to do this once per device.
3. You'll see a sign-in screen. Type the username and password you set in Step 4.
4. You're in. You'll land on your **HomeFree dashboard** — a page that lists all your apps. From here you can turn things on, turn things off, and open any app with a click.

## Step 6 — Hook up your domain (optional, but recommended)

This step lets you reach your HomeFree from anywhere — not just at home.

If you typed your own domain name in Step 4, your HomeFree dashboard will have a green **Network** page that walks you through pointing that domain at your home. It's three or four clicks, mostly waiting for the internet's address book ("DNS") to catch up.

If you picked a free `yourname.homefree.host` name instead, you're already done — that one works from anywhere automatically.

## Now what?

Open the **Apps** section of your HomeFree dashboard and turn on the things you want to use. Then come back to the manual:

- [FreshRSS](/apps/freshrss/) — read all your news in one place.
- [FreshRSS on Android](/apps/freshrss-capy/) — also read it on your phone.

More app pages are on the way.

## If something goes wrong

- **The USB stick won't boot.** The most common cause is a setting called **Secure Boot**. Go into the firmware settings (usually by tapping `Del` or `F2` at power-on), find Secure Boot, and turn it off. Save and reboot.
- **The installer can't see your Ethernet ports.** Check the cables are fully plugged in. If one of the ports is a USB-to-Ethernet adapter, try a different USB port on the HomeFree box.
- **You can't reach `https://homefree.lan` from your phone or laptop.** Your Wi-Fi is probably still in router mode. Go back to [Hardware setup → Step 2](/hardware-setup/#step-2--set-your-wi-fi-to-bridge-mode).
- **You forgot your password.** Plug the keyboard and monitor back into HomeFree, follow the on-screen recovery steps.

Still stuck? Drop into [our chat](https://matrix.to/#/#homefree:homefree.host) and someone will help.
