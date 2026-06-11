# Installing Flow (no tech skills needed)

Flow lets you talk instead of type, anywhere on your Mac. Hold the **fn** key
(bottom-left of your keyboard, with a 🌐 globe on it), speak, let go — your
words appear wherever your cursor is. It's free and nothing you say ever
leaves your Mac.

Setup takes about 10 minutes, mostly waiting. You'll copy-paste two commands —
that's as technical as it gets.

## Step 1 — Check your Mac can run it

1. Click the **** Apple logo in the top-left corner of your screen.
2. Click **About This Mac**.
3. You need both of these:
   - **Chip:** says "Apple M1", "M2", "M3", or "M4" (not "Intel").
   - **macOS:** version **26** or newer. If yours is older, run Software
     Update first (it's free).

If your Mac says Intel, Flow unfortunately won't work on it.

## Step 2 — Get Apple's free build tools

1. Press **⌘ command + space bar** together, type `terminal`, press **return**.
   A plain white/black window opens — that's Terminal. Don't worry, you'll
   only paste two things into it.
2. Copy this line, paste it into Terminal, and press **return**:

   ```
   xcode-select --install
   ```

3. A window pops up — click **Install**, agree, and wait for it to finish
   (5–10 minutes depending on internet). If it instead says "already
   installed", even better — go to Step 3.

## Step 3 — Install Flow

Copy this whole line, paste it into the same Terminal window, press **return**:

```
curl -fsSL https://raw.githubusercontent.com/Littlemowmow/flow/main/Scripts/install.sh | zsh
```

Text will scroll by for a few minutes while it downloads and builds Flow.
When it says **"✅ Flow installed and launched"**, you're nearly done.
You can close Terminal now.

## Step 4 — Give Flow its three permissions

Flow needs your permission to hear you and to type for you. macOS will show
prompts — if you miss one, click the little **microphone icon in your menu
bar** (top-right of the screen) and use the ⚠️ item to open the right settings.

In **System Settings → Privacy & Security**, turn the **Flow** switch ON in
each of these three places (you may need to enter your Mac password):

1. **Microphone** — so it can hear you
2. **Accessibility** — so it can type for you
3. **Input Monitoring** — so it notices when you hold fn

If the fn key doesn't respond after granting these, quit Flow (menu bar
icon → Quit Flow) and reopen it from your **Applications** folder.

## Step 5 — Optional: smarter cleanup

If **Apple Intelligence** is on (System Settings → Apple Intelligence & Siri),
Flow automatically tidies what you say — removing "um"s and fixing
punctuation. If it's off, Flow still works, just with simpler cleanup.

## How to use it

- Click into anything you can type in — a message, an email, a search box.
- **Hold fn**, talk normally, **let go**. Your words appear a second later.
- **fn + space** = hands-free mode: it keeps typing as you talk. Press
  **fn + space** again to stop, or **esc** to cancel.
- The microphone icon in your menu bar turns red while it's listening.

That's it. Talk faster than you type.
