---
title: "FreshRSS on Android with Capy — HomeFree Manual"
---

# FreshRSS on Android with Capy

[Capy Reader](https://capyreader.com/) is a clean, free Android app for reading your FreshRSS news on the go. This page walks you through connecting it.

Capy uses a **separate password** for connecting to FreshRSS — different from your normal HomeFree password. That's on purpose: a phone is easier to lose than your laptop, so the app password gives Capy *only* the ability to read your feeds and nothing more. You'll set it up in a moment.

## Step 1 — Turn on app access in FreshRSS

On your computer, sign in to FreshRSS (open the **FreshRSS** tile from your HomeFree dashboard).

1. Click the **wrench icon** at the top right → **Configuration**.
2. Go to **Authentication**.
3. Check the box **Allow API access (required for mobile apps)**.
4. Click **Submit**.

## Step 2 — Pick a phone password

Still in FreshRSS:

1. Click the **person icon** at the top right → **Profile**.
2. Find the field labelled **API password** (sometimes shown as "API password (e.g., for mobile apps)").
3. Type a new password. **Don't reuse your HomeFree login password.** A short phrase you can type on a phone keyboard is fine.
4. Click **Submit**.

Keep this password handy — you'll type it on your phone in Step 4.

## Step 3 — Install Capy

On your Android phone, install Capy Reader from one of:

- **[Google Play](https://play.google.com/store/apps/details?id=com.capyreader.app)**
- **[F-Droid](https://f-droid.org/packages/com.capyreader.app/)**

Both work fine; pick whichever app store you prefer.

## Step 4 — Connect Capy to your FreshRSS

Open Capy and add an account:

1. Tap **Add account → FreshRSS**.
2. **Server URL**: `https://freshrss.<your-domain>/api/greader.php` (replace `<your-domain>` with your HomeFree domain).
3. **Username**: your normal HomeFree username.
4. **Password**: the **phone password you set in Step 2** — *not* your normal HomeFree login.
5. Tap **Sign in**.

Capy will sync your feeds. Within a few seconds you'll see the same feeds and unread counts you have on your computer.

## Other phones, other apps

Capy is the recommended Android app, but the same setup works for:

- **Reeder** on iPhone, iPad, and Mac. (Pick the *FreshRSS* account type.)
- **FluentReader Lite** on Android.
- **NetNewsWire** on iPhone, iPad, and Mac.

Use the same server URL, username, and phone password.

## If it doesn't work

- **"Authentication failed."** You typed your normal HomeFree password instead of the phone password. Go back to Step 2 in FreshRSS, make sure an API password is set, and use that one in Capy.
- **"Could not connect."** Make sure you're connected to the internet, and try typing `https://freshrss.<your-domain>` into your phone's browser — if that loads, Capy will too.
- **Stories aren't marking as read on my computer too.** Pull down to refresh in Capy; the sync should catch up within a few seconds.
