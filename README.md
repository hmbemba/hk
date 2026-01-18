# hk.nim — Hotkeys + Hotstrings for Windows (Nim + winim)

A lightweight **Windows-only** hotkey + hotstring engine built in **Nim** on top of a **low-level keyboard hook** (`WH_KEYBOARD_LL`) via **winim**.

It’s designed to feel like the “core primitives” you’d want when building AHK-like behavior in Nim:
- register hotkeys like `Ctrl+K`, `Alt+Shift+T`, `Win+C`, etc.
- register hotstrings like `btw` → `by the way`
- choose whether to **swallow** the hotkey or let it pass through
- trigger hotstrings on **end characters** (space/enter/tab/punctuation) or **immediately**
- replace text via **backspacing** (simple) or **select + paste** (fast, best for long/multiline)

---

## Features

### Hotkeys
- Any combination of **Ctrl / Alt / Shift / Win**
- Action is just a `proc()`
- Optional **swallow** mode (block it from reaching other apps)
- Built-in helpers for sending keys / typing text / running commands

### Hotstrings
- `trigger` → `replacement` **or** `trigger` → custom action `proc()`
- Case-sensitive or case-insensitive
- Trigger modes:
  - `htEndChar` (fires when you type an end char like space/enter/tab/etc.)
  - `htImmediate` (fires as soon as the buffer ends with the trigger)
- Replace modes:
  - `rmBackspace` (delete chars one-by-one then type replacement)
  - `rmPaste` (select backwards then paste replacement — much faster)

---

## Requirements

- **Windows**
- **Nim**
- Dependencies:
  - `winim`
  - `libclip` (for clipboard-based paste mode)

Install deps (example):

```bash
nimble install winim libclip
```


# hk.nim — Hotkeys + Hotstrings for Windows (Nim + winim)

A lightweight **Windows-only** hotkey + hotstring engine built in **Nim** on top of a **low-level keyboard hook** (`WH_KEYBOARD_LL`) via **winim**.

It’s designed to feel like the “core primitives” you’d want when building AHK-like behavior in Nim:
- register hotkeys like `Ctrl+K`, `Alt+Shift+T`, `Win+C`, etc.
- register hotstrings like `btw` → `by the way`
- choose whether to **swallow** the hotkey or let it pass through
- trigger hotstrings on **end characters** (space/enter/tab/punctuation) or **immediately**
- replace text via **backspacing** (simple) or **select + paste** (fast, best for long/multiline)

---

## Features

### Hotkeys
- Any combination of **Ctrl / Alt / Shift / Win**
- Action is just a `proc()`
- Optional **swallow** mode (block it from reaching other apps)
- Built-in helpers for sending keys / typing text / running commands

### Hotstrings
- `trigger` → `replacement` **or** `trigger` → custom action `proc()`
- Case-sensitive or case-insensitive
- Trigger modes:
  - `htEndChar` (fires when you type an end char like space/enter/tab/etc.)
  - `htImmediate` (fires as soon as the buffer ends with the trigger)
- Replace modes:
  - `rmBackspace` (delete chars one-by-one then type replacement)
  - `rmPaste` (select backwards then paste replacement — much faster)

---

## Requirements

- **Windows**
- **Nim**
- Dependencies:
  - `winim`
  - `libclip` (for clipboard-based paste mode)

Install deps (example):

```bash
nimble install winim libclip
````

---

## Quick Start

Create a file like `main.nim`:

```nim
import hk
import times

let sys = newHotkeySystem()

# Hotkey: Ctrl+K
sys.addHotkey('K', {mkCtrl}, proc() =
  echo "Ctrl+K pressed!"
, desc = "Print message")

# Hotkey: Alt+N (types current time)
sys.addHotkey('N', {mkAlt}, proc() =
  sendString(now().format("HH:mm:ss"))
, desc = "Type current time")

# Hotstring: btw -> by the way
sys.addHotstring("btw", "by the way", desc = "Expand btw")

# Hotstring (paste mode): signature snippet
sys.addHotstring("sig", "Best regards,\nJohn Doe\njohn@example.com",
                 replaceMode = rmPaste,
                 desc = "Insert signature")

# Immediate hotstring action: ::date
sys.addHotstringAction("::date", proc() =
  pasteText(now().format("yyyy-MM-dd"))
, triggerMode = htImmediate,
  replaceMode = rmPaste,
  desc = "Insert date immediately")

sys.listHotkeys()
sys.listHotstrings()

echo "Running... Press Ctrl+C to quit."
sys.run()
```

Run:

```bash
nim c -r main.nim
```

---

## API Overview

### Types

* `ModifierKey`
  `mkCtrl`, `mkAlt`, `mkShift`, `mkWin`

* `HotstringTrigger`

  * `htEndChar`
  * `htImmediate`

* `ReplaceMode`

  * `rmBackspace`
  * `rmPaste`

### Create a system

```nim
let sys = newHotkeySystem()
```

### Register hotkeys

```nim
sys.addHotkey('K', {mkCtrl}, proc() =
  echo "Pressed!"
, swallow = false,
  desc = "Print message")
```

You can also use a VK directly:

```nim
sys.addHotkey(VK_F1, {}, proc() =
  sys.listHotkeys()
  sys.listHotstrings()
, desc = "Show help")
```

### Register hotstrings (replacement)

```nim
sys.addHotstring("omw", "On my way!", desc = "Expand omw")
```

Paste mode (recommended for long / multiline):

```nim
sys.addHotstring("addr", "123 Main Street...\nUSA",
                 replaceMode = rmPaste,
                 desc = "Insert address")
```

### Register hotstrings (custom action)

```nim
sys.addHotstringAction(";calc", proc() =
  runCommand("calc.exe")
, desc = "Open calculator")
```

### Start / stop / run

* `start()` installs the hook
* `run()` starts a Windows message loop (blocking)
* `stop()` removes the hook

```nim
discard sys.start()
# ...
sys.stop()

# Or just:
sys.run()
```

---

## Utility Helpers Included

These are handy for building actions:

* `sendKey(vk)`
* `sendBackspace(count)`
* `sendString(text)` (SendInput unicode typing)
* `pasteText(text)` (clipboard + Ctrl+V via libclip)
* `selectBackward(charCount)`
* `selectAndPaste(selectCount, text)`
* `runCommand(cmd)` (ShellExecuteW "open")

Virtual-key helpers:

* `charToVK(ch): int32`
* `vkToChar(vk, shifted): char`

---

## How Hotstrings Work

The system keeps a rolling `inputBuffer` (default max length `32`) and updates it on keydown for “normal typing” keys.

### End-char mode (`htEndChar`)

When you type an end character (space/tab/enter/punctuation), the buffer looks like:

```
"btw "
```

It compares the buffer **minus the last char** to the trigger:

* `"btw "` → compare `"btw"` → match → replace

### Immediate mode (`htImmediate`)

Triggers as soon as the buffer ends with the trigger:

* typing `::date` triggers instantly (no space required)

### Replace mode differences

* `rmBackspace`: deletes each character using backspace, then types replacement
* `rmPaste`: selects backwards with `Shift+Left`, then pastes via clipboard (fast)

---

## Notes / Limitations

* **Windows only** (uses `SetWindowsHookEx` low-level keyboard hook)
* The hook skips keys flagged as **injected** (`LLKHF_INJECTED`) to avoid re-trigger loops from `SendInput`
* Hotstring detection only runs when modifiers are `{}` or `{mkShift}` (so typing while holding Ctrl/Alt/Win doesn’t corrupt buffer)
* Some keys / layouts can be tricky (IME, non-US keyboard layouts, dead keys). `vkToChar` currently covers common ASCII + some punctuation.

---

## Security & Privacy

This library installs a global keyboard hook. That means it can see keystrokes system-wide while running. Use responsibly and avoid distributing binaries that capture sensitive input without explicit user consent.

---

## License

Choose whatever fits your project (MIT is common). Add a `LICENSE` file if you plan to publish this as a nimble package.

---

## Demo

This repo includes an `isMainModule` demo in `hk.nim`:

* hotkeys (Ctrl+K, Ctrl+Shift+T, Alt+N, F1)
* hotstrings (btw/omw/ty/np + paste-mode snippets + immediate `::date` etc.)

Run it directly:

```bash
nim c -r hk.nim
```

