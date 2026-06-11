# How to get Flow on your Mac

Flow = you hold a key, you talk, your Mac types what you said. Free.

Follow these steps exactly, in order. Don't skip any.

---

## PART 1 — Make sure your Mac can run it (1 minute)

1. Look at the **very top-left corner** of your screen. There's an **** Apple logo.
2. Click it once.
3. Click **About This Mac** (first item in the list).
4. A small window opens. Look for these two lines:
   - **Chip** — it must say **Apple M1**, **M2**, **M3**, or **M4**.
     ❌ If it says **Intel** anywhere → stop, Flow can't run on this Mac. Sorry.
   - **macOS** — the number must be **26** or higher.
     ❌ If it's lower → click  → **System Settings** → **General** →
     **Software Update**, update your Mac (free, takes a while), then come back.
5. Both good? Close the window. Continue.

---

## PART 2 — Open Terminal (30 seconds)

Terminal is an app already on your Mac. It's a plain text window where you
paste commands. You will paste exactly **two** things into it, both given below.

1. Hold the **⌘ command** key and tap the **space bar**. A search bar appears
   in the middle of the screen.
2. Type: `terminal`
3. Press **return** (the enter key).
4. A boring white or black window opens with some text and a blinking cursor.
   That's Terminal. Leave it open.

---

## PART 3 — Download Apple's free builder tool (10 minutes, mostly waiting)

Flow is built fresh on your Mac, so first you need Apple's free tool that does
the building.

1. Copy the line below (select it, then ⌘ command + C):

   ```
   xcode-select --install
   ```

2. Click inside the Terminal window, paste it (⌘ command + V), press **return**.
3. **One of two things happens:**
   - **A popup appears** saying the command line developer tools need to be
     installed → click **Install**, then **Agree**. A progress bar runs for
     5–15 minutes. Wait for it to say it's done, then click **Done**.
   - **OR Terminal prints** something like *"command line tools are already
     installed"* → perfect, nothing to do.
4. When that's finished, continue to Part 4.

---

## PART 4 — Install Flow (about 5 minutes)

1. Copy this ENTIRE line — all of it, it's one line:

   ```
   curl -fsSL https://raw.githubusercontent.com/Littlemowmow/flow/main/Scripts/install.sh | zsh
   ```

2. Click inside the Terminal window, paste it (⌘ command + V), press **return**.
3. Lots of text will scroll by. This is normal. Do nothing. Wait.
4. You're done with this part when you see:

   ```
   ✅ Flow installed and launched.
   ```

5. You can now close Terminal forever (⌘ command + Q).
6. Look at the **top-right** of your screen, near the clock. There's a new
   tiny **microphone icon** 🎤. That's Flow. It's running.

❌ If you see the word **error** in red instead → you probably skipped Part 3.
Do Part 3, then do Part 4 again.

---

## PART 5 — Say yes to three permissions (2 minutes)

Flow needs three switches turned on. Your Mac will show popups asking for them.

**The easy way — follow the popups:**
When a popup appears saying Flow wants to use the **Microphone** → click
**Allow**. When popups mention **Accessibility** or **Input Monitoring** →
click **Open System Settings** and turn the **Flow** switch **ON**. Type your
Mac password if it asks.

**If you missed the popups, do it by hand:**

1. Click  → **System Settings**.
2. In the left sidebar, click **Privacy & Security**.
3. Click **Microphone** → find **Flow** in the list → turn its switch **ON**.
4. Click the **< back arrow**, click **Accessibility** → find **Flow** →
   switch **ON** (it may ask for your Mac password — type it).
5. Click back again, click **Input Monitoring** → find **Flow** → switch **ON**.

**Last thing:** click the tiny 🎤 microphone icon at the top-right of your
screen → click **Quit Flow**. Then open **Finder** → **Applications** →
double-click **Flow**. (This restart makes the permissions kick in.)

---

## PART 6 — Try it! (10 seconds)

1. Open anything you can type in. Messages, Notes, Google — anything.
2. Click into the text box so the cursor is blinking there.
3. Find the **fn** key — bottom-left corner of your keyboard, has a little
   **🌐 globe** on it.
4. **Hold fn down**, say out loud: *"hello this is me talking instead of
   typing"* — then **let go**.
5. A second later, your words appear. That's it. You did it.

**Bonus moves:**
- **fn + space bar** at the same time = hands-free mode. It keeps typing
  while you talk. Press **fn + space** again to stop.
- **esc** key = cancel hands-free, type nothing.
- The 🎤 icon turns **red** while Flow is listening.

---

## Something not working?

| Problem | Fix |
|---|---|
| Holding fn does nothing | Do Part 5 again — one of the three switches is off. Then quit and reopen Flow. |
| Holding fn opens an emoji picker | Click  → System Settings → Keyboard → find "Press 🌐 key to" → choose **Do Nothing**. |
| No 🎤 icon at the top of the screen | Open Finder → Applications → double-click Flow. |
| Words come out messy | Turn on Apple Intelligence:  → System Settings → Apple Intelligence & Siri → turn it on. Flow cleans up your speech much better with it. |
