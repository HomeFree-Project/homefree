---
title: "Hardware setup — HomeFree Manual"
---

# Hardware setup

HomeFree runs on a small, quiet computer that sits between your internet modem and the rest of your home network. This page walks you through what to buy and how everything plugs in.

## What you'll need

| What | Notes |
|---|---|
| **A small computer** for HomeFree | Any mini-PC with **two Ethernet ports** and at least 8 GB of memory. New or refurbished is fine. If a port is missing, a USB-to-Ethernet adapter works. See the note below if your mini-PC won't boot reliably without a monitor. |
| **An Ethernet switch** | A small box with several Ethernet ports. "Unmanaged gigabit" is what you want — any brand. Get enough ports for your wired devices plus one for the Wi-Fi unit. |
| **A Wi-Fi access point** | The thing that broadcasts Wi-Fi in your home. Almost any modern Wi-Fi router will do, as long as it supports **bridge mode** (sometimes called "access-point mode"). Eero, Ubiquiti, TP-Link Deco, and ASUS all work. |
| **Two Ethernet cables** | One short cable from your modem to HomeFree, one from HomeFree to the switch. |

> **Headless mini-PCs (Intel NUC and similar).** Some mini-PCs hang at boot when no monitor is attached, or won't enable their GPU without a display present. If yours misbehaves once you unplug the monitor, enter the firmware (usually `F2` or `Del` at power-on) and enable **Fast Boot** and **Suppress Alert Messages at Boot**. If the box still needs a display, leave a cheap **dummy HDMI dongle** plugged in.

## How it all connects

Here's the picture. Your internet modem talks to HomeFree, HomeFree talks to a switch, and everything else — Wi-Fi, computers, TVs — connects to that switch.

{# Network topology diagram — inline SVG, pre-rendered. Previously a
   <pre class="mermaid"> block that loaded mermaid from jsdelivr; that
   was the only Mermaid use in the entire manual, and a third-party
   runtime load violated the no-external-resources rule. If more
   diagrams are needed, follow the same pattern (hand-authored or
   build-time-rendered SVG) — do NOT reintroduce a runtime diagram
   library. #}
<div class="mermaid" role="img" aria-label="HomeFree sits between the internet modem and a switch, which fans out to a Wi-Fi access point and to wired devices; phones and laptops connect to the access point over Wi-Fi.">
<svg viewBox="0 0 760 240" xmlns="http://www.w3.org/2000/svg" style="max-width:100%;height:auto;font-family:var(--font-display);">
  <defs>
    <marker id="hf-arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="8" markerHeight="8" orient="auto-start-reverse">
      <path d="M0,0 L10,5 L0,10 z" fill="#b6bcc4"/>
    </marker>
  </defs>
  <g fill="#181b21" stroke="#34d399" stroke-width="1.5" font-size="13" font-weight="500">
    <ellipse cx="60" cy="120" rx="50" ry="26"/>
    <rect x="140" y="94" width="120" height="52" rx="6"/>
    <polygon points="320,94 420,94 440,120 420,146 320,146 300,120"/>
    <rect x="480" y="94" width="120" height="52" rx="6"/>
    <rect x="640" y="30" width="100" height="50" rx="6"/>
    <rect x="640" y="160" width="100" height="50" rx="6"/>
  </g>
  <g fill="#f5f7fa" font-size="13" text-anchor="middle" font-weight="600" font-family="var(--font-display)">
    <text x="60" y="124">Internet</text>
    <text x="200" y="124">Internet modem</text>
    <text x="370" y="124">HomeFree</text>
    <text x="540" y="124">Ethernet switch</text>
    <text x="690" y="60">Wi-Fi</text>
    <text x="690" y="180">Wired devices</text>
    <text x="690" y="196" font-size="11" fill="#b6bcc4" font-weight="400">TV, computer</text>
  </g>
  <g stroke="#b6bcc4" stroke-width="1.5" fill="none" marker-end="url(#hf-arrow)">
    <line x1="110" y1="120" x2="140" y2="120"/>
    <line x1="260" y1="120" x2="300" y2="120"/>
    <line x1="440" y1="120" x2="480" y2="120"/>
    <line x1="600" y1="105" x2="640" y2="65"/>
    <line x1="600" y1="135" x2="640" y2="175"/>
  </g>
  <g fill="#b6bcc4" font-size="11" text-anchor="middle" font-family="var(--font-mono)">
    <text x="280" y="112">cable</text>
    <text x="460" y="112">cable</text>
  </g>
  <g stroke="#34d399" stroke-width="1.5" stroke-dasharray="4 4" fill="none">
    <path d="M 740 55 Q 760 120 740 185" marker-end="url(#hf-arrow)"/>
  </g>
  <text x="755" y="125" font-size="11" fill="#34d399" font-family="var(--font-mono)" text-anchor="end">Wi-Fi</text>
  <text x="690" y="225" font-size="11" fill="#b6bcc4" font-weight="400" text-anchor="middle">Phones, laptops</text>
</svg>
</div>

The HomeFree box is the *only* thing between your modem and the rest of your home. Every device — wired or wireless — goes through it. That's how HomeFree can protect your network, sign you into your apps, and route traffic.

## Step 1 — Set your internet modem to bridge mode

Most home internet boxes are *combo units*: modem, router, and Wi-Fi all in one. HomeFree replaces the router and Wi-Fi parts, so the combo unit needs to behave like a plain modem. That setting is called **bridge mode**.

**If you have Spectrum / Charter:** your modem is probably already in bridge mode out of the box. Once you've plugged HomeFree into it, just unplug the modem from power for 30 seconds and plug it back in. That's it.

**If you have a different provider** (Xfinity, Verizon, others): search your provider's app or website for "bridge mode" and switch it on. While you're there, turn off the modem's built-in Wi-Fi — HomeFree will provide that through your separate Wi-Fi access point. After changing the setting, unplug the modem for 30 seconds and plug it back in.

**If you have AT&T Fiber:** AT&T's gateway calls bridge mode **IP Passthrough**. In the gateway's admin pages:

- On the **IP Passthrough** page, set:
  - Allocation Mode → **PassThrough**
  - Default Server Internal Address → leave **empty**
  - Passthrough Mode → **DHCPS-fixed**
  - Passthrough Fixed MAC Address → the MAC address of HomeFree's **WAN** Ethernet port (the one plugged into the gateway)
- On the **Packet Filter** tab, disable all packet filters.
- On the **Firewall Advanced** tab, disable every setting.

Then unplug the gateway for 30 seconds and plug it back in.

If your provider won't let you enable bridge mode, HomeFree will still work, but some apps that need to be reachable from outside your home (like sharing a photo album link with grandma) may have limits. Ask your provider, or contact us if you'd like help.

## Step 2 — Set your Wi-Fi to bridge mode

Same idea as the modem: your Wi-Fi unit needs to broadcast Wi-Fi but *not* try to be the network's router. HomeFree handles the router job. That setting is called **bridge mode** or **access-point mode** depending on the brand.

**Eero (any model):**

1. Open the eero app. Make sure you can see your eero and reach its settings — if you can't, fix that first.
2. Tap **Settings → Network Settings → DHCP & NAT → Bridge**.
3. Plug the eero into the Ethernet switch (which you'll connect to HomeFree in Step 4).
4. Wait a minute. The eero will reboot in its new mode.

**Other brands:** look in the Wi-Fi unit's app or settings page for "bridge mode" or "access-point mode" and turn it on.

## Step 3 — Plug everything in

In this order:

1. **Modem to HomeFree.** One Ethernet cable from your modem to one of HomeFree's Ethernet ports. (Either port is fine — the installer will help you pick.)
2. **HomeFree to switch.** Second Ethernet cable from HomeFree's *other* Ethernet port to your Ethernet switch.
3. **Wi-Fi to switch.** Plug your Wi-Fi unit into one of the switch's ports.
4. **Wired devices to switch.** Plug your TV, desktop, NAS, anything wired into the remaining switch ports.

That's the physical setup done.

## Step 4 — Power-on order

When everything is wired up, turn things on in this order:

1. **Modem.** Wait about two minutes for it to fully wake up and sync with your internet provider.
2. **HomeFree.** Wait one minute.
3. **Switch and Wi-Fi.** Both come up; your devices will start connecting.

Once HomeFree is running you're ready to install it — flip over to the [Installation](/installation/) page.

## If something goes wrong

- **No internet on your devices.** Most often this means your Wi-Fi unit is still in router mode. Re-check Step 2 — it has to be in bridge / access-point mode for HomeFree to take over the network job.
- **HomeFree never finishes starting up.** Unplug it for a few seconds and plug it back in. If that doesn't help, the [Installation](/installation/) page covers what to check next.
- **The Wi-Fi works but websites don't load.** Same fix as the first item — the Wi-Fi unit is running its own little network instead of letting HomeFree do it.
