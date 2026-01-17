## Hotkey & Hotstring System for Windows
## Built with Nim + winim
## 
## Features:
## - Hotkeys: Ctrl+K, Alt+Shift+T, Win+C, etc.
## - Hotstrings: Type "btw" -> expands to "by the way"
## - Configurable actions: echo, send keystrokes, run commands, custom procs
## - Passthrough or swallow keys
## - Case-sensitive and case-insensitive hotstrings
## - End characters for hotstring triggers (space, enter, tab, etc.)
## - Fast paste mode using clipboard

import winim
import strutils
import tables
import sequtils
import times
import os
import libclip/clipboard

# ============================================================
# Types
# ============================================================

type
  ModifierKey* = enum
    mkNone = 0
    mkCtrl = 1
    mkAlt = 2
    mkShift = 4
    mkWin = 8

  HotkeyAction* = proc(): void
  
  Hotkey* = object
    vkCode*: int32
    modifiers*: set[ModifierKey]
    action*: HotkeyAction
    swallow*: bool  # If true, don't pass key to other apps
    description*: string

  HotstringTrigger* = enum
    htEndChar      # Trigger on space, enter, tab, etc.
    htImmediate    # Trigger immediately when pattern matches

  ReplaceMode* = enum
    rmBackspace    # Backspace each character then type (original)
    rmPaste        # Select text and paste replacement (faster)

  HotstringAction* = proc(): void

  Hotstring* = object
    trigger*: string
    replacement*: string        # Simple text replacement
    action*: HotstringAction    # Or custom action
    caseSensitive*: bool
    triggerMode*: HotstringTrigger
    backspace*: bool            # Backspace the trigger text (only for rmBackspace)
    replaceMode*: ReplaceMode   # How to replace the trigger text
    description*: string

  HotkeySystem* = ref object
    hook: HHOOK
    hotkeys: seq[Hotkey]
    hotstrings: seq[Hotstring]
    inputBuffer: string
    maxBufferLen: int
    endChars: set[char]
    running: bool

# ============================================================
# Globals (required for hook callback)
# ============================================================

var gSystem: HotkeySystem = nil

# ============================================================
# Modifier Detection
# ============================================================

proc isKeyDown(vk: int): bool =
  (GetAsyncKeyState(cint(vk)) and 0x8000'i16) != 0

proc isCtrlDown(): bool = isKeyDown(VK_CONTROL)
proc isAltDown(): bool = isKeyDown(VK_MENU)
proc isShiftDown(): bool = isKeyDown(VK_SHIFT)
proc isWinDown(): bool = isKeyDown(VK_LWIN) or isKeyDown(VK_RWIN)

proc getCurrentModifiers(): set[ModifierKey] =
  result = {}
  if isCtrlDown(): result.incl(mkCtrl)
  if isAltDown(): result.incl(mkAlt)
  if isShiftDown(): result.incl(mkShift)
  if isWinDown(): result.incl(mkWin)

# ============================================================
# Key Sending Utilities
# ============================================================

proc sendKeyInput(vk: int32, down: bool) =
  var input: INPUT
  input.type = INPUT_KEYBOARD
  input.ki.wVk = WORD(vk)
  input.ki.dwFlags = if down: 0 else: KEYEVENTF_KEYUP
  discard SendInput(1, addr input, cint(sizeof(INPUT)))

proc sendKey*(vk: int32) =
  ## Send a single key press and release
  sendKeyInput(vk, true)
  sendKeyInput(vk, false)

proc sendBackspace*(count: int = 1) =
  ## Send backspace key(s)
  for i in 0..<count:
    sendKey(VK_BACK)
    Sleep(20)  # Slightly longer delay for reliability

proc sendString*(text: string) =
  ## Type a string using SendInput (unicode)
  for ch in text:
    var inputs: array[2, INPUT]
    # Key down
    inputs[0].type = INPUT_KEYBOARD
    inputs[0].ki.wScan = WORD(ord(ch))
    inputs[0].ki.dwFlags = KEYEVENTF_UNICODE
    # Key up
    inputs[1].type = INPUT_KEYBOARD
    inputs[1].ki.wScan = WORD(ord(ch))
    inputs[1].ki.dwFlags = KEYEVENTF_UNICODE or KEYEVENTF_KEYUP
    discard SendInput(2, addr inputs[0], cint(sizeof(INPUT)))
    Sleep(5)

proc sendStringFast*(text: string) =
  ## Type a string using clipboard (faster for long text)
  let hMem = GlobalAlloc(GMEM_MOVEABLE, SIZE_T(text.len + 1))
  if hMem != 0:
    let pMem = GlobalLock(hMem)
    if pMem != nil:
      copyMem(pMem, unsafeAddr text[0], text.len)
      cast[ptr char](cast[int](pMem) + text.len)[] = '\0'
      discard GlobalUnlock(hMem)
      
      if OpenClipboard(0) != 0:
        discard EmptyClipboard()
        discard SetClipboardData(CF_TEXT, hMem)
        discard CloseClipboard()
        
        # Ctrl+V
        sendKeyInput(VK_CONTROL, true)
        sendKey(ord('V').int32)
        sendKeyInput(VK_CONTROL, false)

proc selectBackward*(charCount: int) =
  ## Select characters backward using Shift+Left arrow
  sendKeyInput(VK_SHIFT, true)
  for i in 0..<charCount:
    sendKey(VK_LEFT)
    Sleep(5)
  sendKeyInput(VK_SHIFT, false)
  Sleep(10)

proc pasteText*(text: string) =
  ## Paste text from clipboard using libclip
  discard setClipboardText(text)
  Sleep(10)
  # Send Ctrl+V
  sendKeyInput(VK_CONTROL, true)
  sendKey(ord('V').int32)
  sendKeyInput(VK_CONTROL, false)
  Sleep(10)

proc selectAndPaste*(selectCount: int, text: string) =
  ## Select N characters backward and paste replacement text
  ## This is faster than backspacing each character
  selectBackward(selectCount)
  Sleep(20)
  pasteText(text)

proc runCommand*(cmd: string) =
  ## Run a command/application
  discard ShellExecuteW(0, "open", cmd, nil, nil, SW_SHOWNORMAL)

# ============================================================
# Virtual Key Code Helpers
# ============================================================

proc charToVK*(ch: char): int32 =
  ## Convert character to virtual key code
  case ch
  of 'A'..'Z': result = int32(ord(ch))
  of 'a'..'z': result = int32(ord(ch) - 32)  # Convert to uppercase
  of '0'..'9': result = int32(ord(ch))
  of ' ': result = VK_SPACE
  of '\t': result = VK_TAB
  of '\r', '\n': result = VK_RETURN
  else: result = 0

proc vkToChar*(vk: int32, shifted: bool): char =
  ## Convert virtual key code to character
  case vk
  of ord('A').int32..ord('Z').int32:
    if shifted: chr(vk)
    else: chr(vk + 32)
  of ord('0').int32..ord('9').int32:
    if shifted:
      case vk
      of ord('1').int32: '!'
      of ord('2').int32: '@'
      of ord('3').int32: '#'
      of ord('4').int32: '$'
      of ord('5').int32: '%'
      of ord('6').int32: '^'
      of ord('7').int32: '&'
      of ord('8').int32: '*'
      of ord('9').int32: '('
      of ord('0').int32: ')'
      else: chr(vk)
    else: chr(vk)
  of VK_SPACE: ' '
  of VK_OEM_PERIOD: 
    if shifted: '>' else: '.'
  of VK_OEM_COMMA: 
    if shifted: '<' else: ','
  of VK_OEM_MINUS: 
    if shifted: '_' else: '-'
  of VK_OEM_PLUS: 
    if shifted: '+' else: '='
  of VK_OEM_1: 
    if shifted: ':' else: ';'
  of VK_OEM_2: 
    if shifted: '?' else: '/'
  of VK_OEM_3: 
    if shifted: '~' else: '`'
  of VK_OEM_4: 
    if shifted: '{' else: '['
  of VK_OEM_5: 
    if shifted: '|' else: '\\'
  of VK_OEM_6: 
    if shifted: '}' else: ']'
  of VK_OEM_7: 
    if shifted: '"' else: '\''
  else: '\0'

proc isEndChar*(vk: int32): bool =
  ## Check if virtual key code is an end character
  vk in [VK_SPACE, VK_RETURN, VK_TAB, VK_OEM_PERIOD, VK_OEM_COMMA,
         VK_OEM_1, VK_OEM_2, VK_OEM_7]

# ============================================================
# Hotkey System
# ============================================================

proc newHotkeySystem*(): HotkeySystem =
  new(result)
  result.hotkeys = @[]
  result.hotstrings = @[]
  result.inputBuffer = ""
  result.maxBufferLen = 32
  result.endChars = {' ', '\t', '\r', '\n', '.', ',', '/', '?', '!'}
  result.running = false

proc addHotkey*(sys: HotkeySystem, vk: int32, modifiers: set[ModifierKey],
                action: HotkeyAction, swallow: bool = false, desc: string = "") =
  ## Add a hotkey
  sys.hotkeys.add(Hotkey(
    vkCode: vk,
    modifiers: modifiers,
    action: action,
    swallow: swallow,
    description: desc
  ))

proc addHotkey*(sys: HotkeySystem, key: char, modifiers: set[ModifierKey],
                action: HotkeyAction, swallow: bool = false, desc: string = "") =
  ## Add a hotkey using character
  sys.addHotkey(charToVK(key), modifiers, action, swallow, desc)

proc addHotstring*(sys: HotkeySystem, trigger: string, replacement: string,
                   caseSensitive: bool = false, 
                   triggerMode: HotstringTrigger = htEndChar,
                   backspace: bool = true,
                   replaceMode: ReplaceMode = rmBackspace,
                   desc: string = "") =
  ## Add a hotstring with text replacement
  ## replaceMode: rmBackspace = delete chars one by one, rmPaste = select and paste (faster)
  sys.hotstrings.add(Hotstring(
    trigger: trigger,
    replacement: replacement,
    action: nil,
    caseSensitive: caseSensitive,
    triggerMode: triggerMode,
    backspace: backspace,
    replaceMode: replaceMode,
    description: desc
  ))

proc addHotstringAction*(sys: HotkeySystem, trigger: string,
                         action: HotstringAction,
                         caseSensitive: bool = false,
                         triggerMode: HotstringTrigger = htEndChar,
                         backspace: bool = true,
                         replaceMode: ReplaceMode = rmBackspace,
                         desc: string = "") =
  ## Add a hotstring with custom action
  sys.hotstrings.add(Hotstring(
    trigger: trigger,
    replacement: "",
    action: action,
    caseSensitive: caseSensitive,
    triggerMode: triggerMode,
    backspace: backspace,
    replaceMode: replaceMode,
    description: desc
  ))

proc clearBuffer*(sys: HotkeySystem) =
  sys.inputBuffer = ""

proc checkHotstrings(sys: HotkeySystem, isEndChar: bool, endCharUsed: var bool): bool =
  ## Check if buffer matches any hotstring
  ## Returns true if a hotstring was triggered
  ## Sets endCharUsed to true if we should swallow the end char
  result = false
  endCharUsed = false
  
  # Debug: show buffer state
  if sys.inputBuffer.len > 0:
    echo "Buffer: '", sys.inputBuffer, "' (len=", sys.inputBuffer.len, ") isEnd=", isEndChar
  
  for hs in sys.hotstrings:
    let bufferToCheck = if hs.caseSensitive: sys.inputBuffer
                        else: sys.inputBuffer.toLowerAscii()
    let triggerToCheck = if hs.caseSensitive: hs.trigger
                         else: hs.trigger.toLowerAscii()
    
    # Check for match based on trigger mode
    let matched = case hs.triggerMode
      of htImmediate:
        # Immediate: check if buffer ends with trigger
        bufferToCheck.endsWith(triggerToCheck)
      of htEndChar:
        # End char: buffer has the end char appended, so check buffer minus last char
        if isEndChar and bufferToCheck.len > 1:
          bufferToCheck[0..^2] == triggerToCheck  # Compare without the trailing end char
        else:
          false
    
    if matched:
      echo "MATCH: '", hs.trigger, "' mode=", hs.replaceMode
      
      # Calculate characters to remove (trigger + end char for htEndChar mode)
      let charsToRemove = if hs.triggerMode == htEndChar:
        hs.trigger.len + 1  # +1 for the end char (space, etc)
      else:
        hs.trigger.len
      
      # Clear buffer first
      sys.clearBuffer()
      
      # Execute after a small delay to ensure key is processed
      Sleep(30)
      
      case hs.replaceMode
      of rmPaste:
        # Fast mode: select backward and paste
        if hs.replacement.len > 0:
          selectAndPaste(charsToRemove, hs.replacement)
        elif hs.action != nil:
          # For actions with paste mode, just remove the trigger
          selectBackward(charsToRemove)
          Sleep(10)
          sendKey(VK_DELETE)
          Sleep(20)
          hs.action()
      of rmBackspace:
        # Original mode: backspace each character then type/action
        if hs.backspace:
          sendBackspace(charsToRemove)
          Sleep(30)
        
        # Execute action or send replacement
        if hs.action != nil:
          hs.action()
        elif hs.replacement.len > 0:
          sendString(hs.replacement)
      
      # For end-char triggered, we keep the end char (space etc)
      # For immediate, no end char involved
      endCharUsed = false
      
      result = true
      break

# ============================================================
# Keyboard Hook Callback
# ============================================================

proc keyboardProc(nCode: cint, wParam: WPARAM, lParam: LPARAM): LRESULT {.stdcall.} =
  if nCode >= 0 and gSystem != nil:
    let kbd = cast[PKBDLLHOOKSTRUCT](lParam)
    let vk = int32(kbd.vkCode)
    let isKeyDown = wParam == WM_KEYDOWN or wParam == WM_SYSKEYDOWN
    let isKeyUp = wParam == WM_KEYUP or wParam == WM_SYSKEYUP
    
    # Skip injected keys (from our own SendInput)
    if (kbd.flags and LLKHF_INJECTED) != 0:
      return CallNextHookEx(gSystem.hook, nCode, wParam, lParam)
    
    if isKeyDown:
      let mods = getCurrentModifiers()
      
      # Check hotkeys first
      for hk in gSystem.hotkeys:
        if hk.vkCode == vk and hk.modifiers == mods:
          hk.action()
          if hk.swallow:
            return 1.LRESULT
      
      # Handle hotstrings (only for non-modifier keys, allow shift for capitals)
      if mods == {} or mods == {mkShift}:
        let shifted = mkShift in mods
        let ch = vkToChar(vk, shifted)
        
        if ch != '\0':
          # Check if this is an end character
          let isEnd = ch in gSystem.endChars
          
          # Add character to buffer (even end chars, for immediate matching)
          gSystem.inputBuffer.add(ch)
          if gSystem.inputBuffer.len > gSystem.maxBufferLen:
            gSystem.inputBuffer = gSystem.inputBuffer[1..^1]
          
          # Check for hotstrings (both immediate and end-char triggered)
          var endCharUsed = false
          if gSystem.checkHotstrings(isEnd, endCharUsed):
            discard  # Hotstring was triggered
          elif isEnd:
            # End char didn't trigger anything, clear buffer for next word
            gSystem.clearBuffer()
        
        # Clear buffer on certain keys
        if vk in [VK_ESCAPE, VK_BACK]:
          if vk == VK_BACK and gSystem.inputBuffer.len > 0:
            gSystem.inputBuffer = gSystem.inputBuffer[0..^2]  # Remove last char
          else:
            gSystem.clearBuffer()
      else:
        # Clear buffer on modifier combos (except shift)
        gSystem.clearBuffer()
  
  return CallNextHookEx(if gSystem != nil: gSystem.hook else: 0.HHOOK, nCode, wParam, lParam)

# ============================================================
# System Control
# ============================================================

proc start*(sys: HotkeySystem): bool =
  ## Start the hotkey system
  if sys.running:
    return true
  
  gSystem = sys
  
  sys.hook = SetWindowsHookEx(WH_KEYBOARD_LL, keyboardProc, GetModuleHandle(nil), 0)
  
  if sys.hook == 0.HHOOK:
    echo "Failed to install keyboard hook. Error: ", GetLastError()
    return false
  
  sys.running = true
  echo "Hotkey system started."
  return true

proc stop*(sys: HotkeySystem) =
  ## Stop the hotkey system
  if sys.running and sys.hook != 0.HHOOK:
    discard UnhookWindowsHookEx(sys.hook)
    sys.hook = 0.HHOOK
    sys.running = false
    gSystem = nil
    echo "Hotkey system stopped."

proc run*(sys: HotkeySystem) =
  ## Run the message loop (blocking)
  if not sys.start():
    return
  
  var msg: MSG
  while GetMessage(addr msg, 0.HWND, 0, 0) > 0:
    TranslateMessage(addr msg)
    DispatchMessage(addr msg)
  
  sys.stop()

proc listHotkeys*(sys: HotkeySystem) =
  ## Print all registered hotkeys
  echo "\n=== Registered Hotkeys ==="
  for i, hk in sys.hotkeys:
    var modStr = ""
    if mkCtrl in hk.modifiers: modStr.add("Ctrl+")
    if mkAlt in hk.modifiers: modStr.add("Alt+")
    if mkShift in hk.modifiers: modStr.add("Shift+")
    if mkWin in hk.modifiers: modStr.add("Win+")
    
    let keyName = if hk.vkCode >= ord('A').int32 and hk.vkCode <= ord('Z').int32:
      $chr(hk.vkCode)
    elif hk.vkCode >= ord('0').int32 and hk.vkCode <= ord('9').int32:
      $chr(hk.vkCode)
    else:
      "VK_" & $hk.vkCode
    
    let desc = if hk.description.len > 0: " - " & hk.description else: ""
    echo "  ", modStr, keyName, desc

proc listHotstrings*(sys: HotkeySystem) =
  ## Print all registered hotstrings
  echo "\n=== Registered Hotstrings ==="
  for i, hs in sys.hotstrings:
    let arrow = if hs.action != nil: " -> [action]" else: " -> \"" & hs.replacement[0..min(20, hs.replacement.len-1)] & (if hs.replacement.len > 20: "..." else: "") & "\""
    let mode = if hs.triggerMode == htImmediate: " (immediate)" else: " (end char)"
    let rmode = if hs.replaceMode == rmPaste: " [paste]" else: " [backspace]"
    let cs = if hs.caseSensitive: " [case-sensitive]" else: ""
    let desc = if hs.description.len > 0: " - " & hs.description else: ""
    echo "  \"", hs.trigger, "\"", arrow, mode, rmode, cs, desc

# ============================================================
# Convenience Builders
# ============================================================

template hotkey*(sys: HotkeySystem, key: untyped, mods: set[ModifierKey], 
                 swallowKey: bool = false, body: untyped) =
  ## Template for easily adding hotkeys with inline code
  sys.addHotkey(key, mods, proc() = body, swallowKey)

template hotstring*(sys: HotkeySystem, trig: string, repl: string) =
  ## Simple hotstring template
  sys.addHotstring(trig, repl)

template hotstringAction*(sys: HotkeySystem, trig: string, body: untyped) =
  ## Hotstring with action template
  sys.addHotstringAction(trig, proc() = body)

# ============================================================
# Example Usage / Demo
# ============================================================

when isMainModule:
  let sys = newHotkeySystem()
  
  # ---- Hotkeys ----
  
  # Ctrl+K - Print message
  sys.addHotkey('K', {mkCtrl}, proc() =
    echo "Ctrl+K pressed!"
  , desc = "Print message")
  
  # Ctrl+Shift+T - Open notepad
  sys.addHotkey('T', {mkCtrl, mkShift}, proc() =
    echo "Opening Notepad..."
    runCommand("notepad.exe")
  , desc = "Open Notepad")
  
  # Alt+N - Type current time
  sys.addHotkey('N', {mkAlt}, proc() =
    let now = now()
    sendString(now.format("HH:mm:ss"))
  , desc = "Type current time")
  
  # Win+E - Already used by Windows, but we can intercept
  # sys.addHotkey('E', {mkWin}, proc() =
  #   echo "Win+E intercepted!"
  # , swallow = true)
  
  # Ctrl+Alt+R - Reload (placeholder)
  sys.addHotkey('R', {mkCtrl, mkAlt}, proc() =
    echo "Reload triggered (placeholder)"
  , desc = "Reload")
  
  # F1 - Help
  sys.addHotkey(VK_F1, {}, proc() =
    echo "\n=== Help ==="
    echo "This is a hotkey/hotstring demo."
    sys.listHotkeys()
    sys.listHotstrings()
  , desc = "Show help")
  
  # ---- Hotstrings ----
  
  # Simple text replacements using BACKSPACE mode (original, char by char)
  sys.addHotstring("btw", "by the way", desc = "Expand btw")
  sys.addHotstring("omw", "On my way!", desc = "Expand omw")
  sys.addHotstring("ty", "Thank you!", desc = "Expand ty")
  sys.addHotstring("np", "No problem!", desc = "Expand np")
  
  # Longer replacements using PASTE mode (faster, select + paste)
  sys.addHotstring("addr", "123 Main Street, Columbus, OH 43215", 
                   replaceMode = rmPaste, desc = "Insert address (paste mode)")
  sys.addHotstring("eml", "example@email.com",
                   replaceMode = rmPaste, desc = "Insert email (paste mode)")
  sys.addHotstring("sig", "Best regards,\nJohn Doe\nSoftware Engineer\njohn@example.com",
                   replaceMode = rmPaste, desc = "Insert signature (paste mode)")
  
  # Immediate trigger (as soon as pattern matches, no space needed)
  sys.addHotstringAction("::date", proc() =
    pasteText(now().format("yyyy-MM-dd"))
  , caseSensitive = false, triggerMode = htImmediate, replaceMode = rmPaste,
    desc = "Insert date (immediate, paste)")
  
  sys.addHotstringAction("::time", proc() =
    pasteText(now().format("HH:mm:ss"))
  , caseSensitive = false, triggerMode = htImmediate, replaceMode = rmPaste,
    desc = "Insert time (immediate, paste)")
  
  sys.addHotstringAction("::now", proc() =
    pasteText(now().format("yyyy-MM-dd HH:mm:ss"))
  , caseSensitive = false, triggerMode = htImmediate, replaceMode = rmPaste,
    desc = "Insert datetime (immediate, paste)")
  
  # Code snippets - paste mode is great for multiline
  sys.addHotstring(";fn", "proc name*() =\n  discard", 
                   replaceMode = rmPaste, desc = "Nim proc snippet (paste)")
  sys.addHotstring(";for", "for i in 0..<n:\n  discard", 
                   replaceMode = rmPaste, desc = "Nim for loop (paste)")
  sys.addHotstring(";if", "if condition:\n  discard", 
                   replaceMode = rmPaste, desc = "Nim if statement (paste)")
  sys.addHotstring(";proc", """proc name*(arg: Type): ReturnType =
  ## Documentation
  result = default""", replaceMode = rmPaste, desc = "Full Nim proc template (paste)")
  
  # Special characters - short ones use backspace mode
  sys.addHotstring(";shrug", "¯\\_(ツ)_/¯", desc = "Shrug emoji")
  sys.addHotstring(";lenny", "( ͡° ͜ʖ ͡°)", desc = "Lenny face")
  sys.addHotstring(";check", "✓", desc = "Checkmark")
  sys.addHotstring(";x", "✗", desc = "X mark")
  sys.addHotstring(";arrow", "→", desc = "Arrow")
  
  # Custom action hotstring
  sys.addHotstringAction(";calc", proc() =
    runCommand("calc.exe")
  , desc = "Open calculator")
  
  # ---- Display registered items ----
  sys.listHotkeys()
  sys.listHotstrings()
  
  echo "\n=== System Ready ==="
  echo "Press F1 for help."
  echo "Press Ctrl+C to exit.\n"
  
  # Run the system
  sys.run()

