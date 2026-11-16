#Requires AutoHotkey v2.0.26
#SingleInstance Force
#Include lib\Config.ahk
#Include lib\Target.ahk
#Include lib\Settings.ahk

Persistent()
MatchDpiContext()
configPath := EnvGet("LOCALAPPDATA") "\MouseCodingToolbar\settings.tsv"
if !FileExist(configPath) {
    ; One-time migration from the pre-open-source location.
    legacyPath := EnvGet("LOCALAPPDATA") "\CodexQuickToolbar\settings.tsv"
    if FileExist(legacyPath) {
        DirCreate(EnvGet("LOCALAPPDATA") "\MouseCodingToolbar")
        FileCopy(legacyPath, configPath)
    }
}
try config := ToolbarConfig(FileExist(configPath) ? configPath : A_ScriptDir "\defaults.tsv")
catch as caughtError {
    MsgBox("无法打开快捷工具栏配置。 " caughtError.Message " " configPath, "快捷指令")
    ExitApp()
}
try target := ComposerTarget(config)
catch as caughtError {
    MsgBox("无法启动 Windows UI Automation。 " caughtError.Message, "快捷指令")
    ExitApp()
}

toolbar := 0
settingsGui := 0
dragHandle := 0
drag := false
visible := false
paused := false
busy := false
lastClick := 0
shownTarget := false
position := ""
registered := []
monitorError := ""
clipHistory := []
expectedClips := []
clipPanel := 0
panelRenderedKey := ""
enterBtn := 0
voiceBtn := 0
voiceHolding := false
voicePressStart := 0
pressInfo := ""
hoverSince := 0
actionPanel := 0
actionInfo := ""
actionLeaveSince := 0
flyHover := ""
clipLeaveSince := 0
visualStates := Map()
OnClipboardChange(ClipboardChanged)
OnMessage(0x200, TrackHover)
OnMessage(0x201, RefreshVisuals)
OnMessage(0x201, VoiceButtonDown)
OnMessage(0x201, ToolbarButtonDown)
OnMessage(0x202, RefreshVisuals)
OnMessage(0x202, VoiceButtonUp)
OnMessage(0x202, ToolbarButtonUp)
OnMessage(0x0215, DragCaptureLost)

A_IconTip := "快捷输入悬浮工具栏"
A_TrayMenu.Delete()
A_TrayMenu.Add("启用工具栏", EnableToolbar)
A_TrayMenu.Add("隐藏并停用快捷键", DisableToolbar)
A_TrayMenu.Add("设置", OpenSettings)
A_TrayMenu.Add("诊断输入框（4 秒后检查）", ScheduleDiagnosis)
A_TrayMenu.Add("剪贴板诊断", ClipDiagnosis)
A_TrayMenu.Add("如何识别输入框", CalibrationHelp)
A_TrayMenu.Add()
A_TrayMenu.Add("退出", (*) => ExitApp())
A_TrayMenu.Default := "设置"

OnMessage(0x21, NoActivate)
HotIf(CanLearnComposer)
Hotkey("^!F8", LearnComposer)
HotIf()
BuildToolbar()
RegisterShortcuts()
if config.options["startup"]
    SetStartup(true)
SetTimer(UpdateToolbar, 250)

MatchDpiContext() {
    ; UI Automation uses physical screen coordinates.
    DllCall("SetThreadDpiAwarenessContext", "Ptr", -4, "Ptr")
}

BuildToolbar() {
    global toolbar, dragHandle, visible, position, shownTarget, enterBtn, voiceBtn
    global visualStates
    if toolbar
        toolbar.Destroy()
    visualStates.Clear()
    voiceBtn := 0
    visible := false
    shownTarget := false
    position := ""
    options := config.options
    toolbar := Gui("-Caption +Border +ToolWindow +E0x08000000 "
        . (options["alwaysOnTop"] ? "+AlwaysOnTop" : "-AlwaysOnTop"), "快捷指令")
    toolbar.BackColor := "FAFBFD"
    toolbar.MarginX := 3
    toolbar.MarginY := 2
    toolbar.SetFont("s9", "Microsoft YaHei UI")
    height := Max(24, options["buttonHeight"] - 4)
    dragHandle := toolbar.AddText("xm ym w14 h" height " Center +0x200 c8893A5", "⋮⋮")
    for index, button in config.buttons {
        placement := Mod(index - 1, 6) = 0 && index > 1 ? "xm y+4" : "x+1 yp"
        control := toolbar.AddText(placement " w" options["buttonWidth"] " h" height
            " Center +0x200 c20242B", (button.enter ? "↵ " : "") button.label)
        RegisterVisual(control, button.enter ? "E5F0FD" : "ECEEF1", button.enter ? "C9E0FC" : "D9DDE3")
        ; Clicks are delivered manually on mouse-up so press-hold can drag.
        button.ctrl := control.Hwnd
    }
    toolbar.AddText("x+3 yp+5 w1 h" Max(1, height - 10) " BackgroundD8DFEA")
    enterBtn := toolbar.AddText("x+3 yp-5 w52 h" height " Center +0x200 c20242B", "↑ 发送")
    RegisterVisual(enterBtn, "E7F6E6", "C5E8C5")
    if config.voiceKey != "" {
        voiceBtn := toolbar.AddText("x+2 yp w58 h" height " Center +0x200 c20242B", "🎙 语音")
        RegisterVisual(voiceBtn, "E7F6E6", "C5E8C5")
    }
    toolbar.Show("Hide AutoSize")
    DllCall("SetWindowLongW", "Ptr", toolbar.Hwnd, "Int", -20, "Int",
        DllCall("GetWindowLongW", "Ptr", toolbar.Hwnd, "Int", -20, "Int") | 0x80000)
    DllCall("SetLayeredWindowAttributes", "Ptr", toolbar.Hwnd, "UInt", 0, "UChar", options["opacity"], "UInt", 2)
}

NoActivate(wParam, lParam, msg, hwnd) {
    if toolbar && DllCall("GetAncestor", "Ptr", hwnd, "UInt", 2, "Ptr") = toolbar.Hwnd
        return 3 ; MA_NOACTIVATE
}

UpdateToolbar(*) {
    global shownTarget, monitorError, clipPanel, hoverSince, clipLeaveSince, drag, voicePressStart
    global actionPanel, actionInfo, actionLeaveSince, flyHover
    if voicePressStart && !GetKeyState("LButton", "P")
        ReleaseVoice()
    RefreshVisuals()
    if busy
        return
    if paused || settingsGui || !config.buttons.Length {
        HideToolbar()
        return
    }
    ; While dragging, mouse events drive toolbar placement.
    if drag {
        HideClipPanel()
        hoverSince := 0
        return
    }
    overSend := MouseOnEnterBtn()
    if overSend {
        if !hoverSince
            hoverSince := A_TickCount
    } else
        hoverSince := 0
    if clipPanel {
        if overSend || MouseOnClipPanel()
            clipLeaveSince := 0
        else if !clipLeaveSince
            clipLeaveSince := A_TickCount
        else if A_TickCount - clipLeaveSince >= 250
            HideClipPanel()
    }
    if clipPanel ? PanelStale() : (hoverSince && A_TickCount - hoverSince >= 350)
        ShowClipPanel()
    ; Action flyout: grace period on leave, dwell fallback for a static cursor.
    if actionPanel {
        if MouseOnActionPanel() || ActionButtonHovered()
            actionLeaveSince := 0
        else if !actionLeaveSince
            actionLeaveSince := A_TickCount
        else if A_TickCount - actionLeaveSince >= 250
            HideActionPanel()
    } else if flyHover && A_TickCount - flyHover.since >= 300
        ShowActionPanel(flyHover.button)
    monitorError := ""
    try {
        snap := InspectComposer()
        if !snap {
            ; Keep the toolbar while the voice key is held down: the voice
            ; input's own popup steals focus and would hide it mid-use.
            if !voicePressStart
                HideToolbar()
            return
        }
        PlaceToolbar(snap)
        shownTarget := visible ? snap : false
    } catch as caughtError {
        monitorError := "无法显示悬浮窗口（脚本第 " caughtError.Line " 行）。"
        HideToolbar()
    }
}

InspectComposer(calibration := false) {
    hwnd := target.Foreground()
    try {
        snap := target.Inspect(hwnd, config.learned, calibration)
        if snap && target.HasOwnedWindow(hwnd)
            return target.Reject("应用有弹窗或菜单打开。请关闭后再点击输入框。")
        return snap
    } catch as caughtError {
        return target.Reject("Windows 无障碍检测失败（脚本第 " caughtError.Line " 行）。")
    }
}

HideToolbar() {
    global visible, drag, position, shownTarget, pressInfo, hoverSince, flyHover
    HideClipPanel()
    HideActionPanel()
    hoverSince := 0
    flyHover := ""
    pressInfo := ""
    if drag
        DllCall("ReleaseCapture")
    if visible
        toolbar.Hide()
    visible := false
    drag := false
    position := ""
    shownTarget := false
}

ToolbarGeometry(snap) {
    MatchDpiContext()
    rect := Buffer(16)
    DllCall("GetWindowRect", "Ptr", toolbar.Hwnd, "Ptr", rect)
    width := NumGet(rect, 8, "Int") - NumGet(rect, 0, "Int")
    height := NumGet(rect, 12, "Int") - NumGet(rect, 4, "Int")
    anchor := Buffer(16)
    NumPut("Int", snap.left, "Int", snap.top, "Int", snap.right, "Int", snap.bottom, anchor)
    monitor := DllCall("MonitorFromRect", "Ptr", anchor, "UInt", 2, "Ptr")
    info := Buffer(40, 0)
    NumPut("UInt", 40, info)
    if !DllCall("GetMonitorInfoW", "Ptr", monitor, "Ptr", info)
        throw OSError()
    left := NumGet(info, 20, "Int"), top := NumGet(info, 24, "Int")
    right := NumGet(info, 28, "Int"), bottom := NumGet(info, 32, "Int")
    dpi := DllCall("GetDpiForWindow", "Ptr", snap.hwnd, "UInt")
    scale := dpi ? dpi / 96 : 1
    gap := Round(7 * scale)
    baseX := snap.right - width
    baseY := snap.top - height - gap
    if baseY < top && snap.bottom + gap + height <= bottom
        baseY := snap.bottom + gap
    return {baseX: baseX, baseY: baseY, minX: left, minY: top, maxX: Max(left, right - width),
        maxY: Max(top, bottom - height), scale: scale, width: width, height: height, gap: gap}
}

PlaceToolbar(snap) {
    global visible, position
    geometry := ToolbarGeometry(snap)
    x := geometry.baseX + Round(config.options["offsetX"] * geometry.scale)
    y := geometry.baseY + Round(config.options["offsetY"] * geometry.scale)
    x := Max(geometry.minX, Min(geometry.maxX, x))
    y := Max(geometry.minY, Min(geometry.maxY, y))
    next := x "," y
    if visible && position = next
        return
    if snap.hwnd != target.Foreground() {
        HideToolbar()
        return
    }
    ; Position without activating the toolbar or raising the host window.
    insertAfter := config.options["alwaysOnTop"] ? -1 : 0
    if !DllCall("SetWindowPos", "Ptr", toolbar.Hwnd, "Ptr", insertAfter, "Int", x, "Int", y,
        "Int", 0, "Int", 0, "UInt", 0x251)
        throw OSError()
    visible := true
    position := next
}

CursorPosition() {
    point := Buffer(8)
    DllCall("GetCursorPos", "Ptr", point)
    return {x: NumGet(point, 0, "Int"), y: NumGet(point, 4, "Int")}
}

ToolbarButtonDown(wParam, lParam, msg, hwnd) {
    global pressInfo, toolbar, voiceBtn
    if !visible
        return
    if DllCall("GetAncestor", "Ptr", hwnd, "UInt", 3, "Ptr") != toolbar.Hwnd
        return
    if voiceBtn && hwnd = voiceBtn.Hwnd
        return ; VoiceButtonDown handles press-and-hold to talk.
    cursor := CursorPosition()
    pressInfo := {hwnd: hwnd, x: cursor.x, y: cursor.y}
}

ToolbarButtonUp(wParam, lParam, msg, hwnd) {
    global pressInfo, config
    EndDrag()
    if !pressInfo
        return
    hwnd := pressInfo.hwnd
    pressInfo := ""
    if !visible
        return
    ; A press-release without movement clicks the control; dragging past the
    ; threshold already converted the press into a move above.
    for button in config.buttons {
        if button.ctrl = hwnd {
            Trigger(button)
            return
        }
    }
    if enterBtn && hwnd = enterBtn.Hwnd
        SendEnterButton()
}

MoveFromDragNow() {
    global drag, config, position
    cursor := CursorPosition()
    geo := drag.geo
    x := Max(geo.minX, Min(geo.maxX, cursor.x - drag.x))
    y := Max(geo.minY, Min(geo.maxY, cursor.y - drag.y))
    config.options["offsetX"] := Round((x - geo.baseX) / geo.scale)
    config.options["offsetY"] := Round((y - geo.baseY) / geo.scale)
    ; 0x255 = NOSIZE|NOZORDER|NOACTIVATE|SHOWWINDOW|NOOWNERZORDER.
    DllCall("SetWindowPos", "Ptr", toolbar.Hwnd, "Ptr", 0, "Int", x, "Int", y,
        "Int", 0, "Int", 0, "UInt", 0x255)
    position := x "," y
}

EndDrag() {
    global drag, config, configPath
    if !drag
        return
    drag := false
    DllCall("ReleaseCapture")
    try config.Save(configPath)
    catch as caughtError
        Notice("无法保存工具栏位置。 " caughtError.Message)
}

DragCaptureLost(wParam, lParam, msg, hwnd) {
    EndDrag()
}

EnableToolbar(*) {
    global paused := false
    UpdateToolbar()
    if !visible
        Notice("请点击目标应用中的对话输入框。")
}

DisableToolbar(*) {
    global paused := true
    HideToolbar()
}

RegisterShortcuts() {
    global registered
    HotIf(CanUseShortcut)
    try {
        for key in registered
            Hotkey(key, "Off")
        registered := []
        if config.options["hotkeys"]
            for button in config.buttons
                if button.key != "" {
                    key := button.key " Up"
                    Hotkey(key, Trigger.Bind(button), "On T1")
                    registered.Push(key)
                }
    } finally HotIf()
}

CanUseShortcut(*) {
    return !paused && !settingsGui && visible && shownTarget && shownTarget.hwnd = target.Foreground()
}

CanLearnComposer(*) {
    return !settingsGui && !busy && !!target.Identify(target.Foreground())
}

CalibrationHelp(*) {
    MsgBox("先在设置的「目标应用」里添加应用进程名（如 notepad.exe）。"
        . Chr(10) "然后点击该应用的输入框，按 Ctrl+Alt+F8，工具栏会记住这个输入框。"
        . Chr(10) "仍未显示时，可从托盘菜单运行诊断。", "识别对话输入框")
}

ScheduleDiagnosis(*) {
    Notice("请在 4 秒内点击 ChatGPT 或 ZCode 的对话输入框。")
    SetTimer(DiagnoseComposer, -4000)
}

DiagnoseComposer(*) {
    result := ""
    if paused
        result := "工具栏已停用。请在托盘菜单选择「启用工具栏」。"
    else if settingsGui
        result := "请先关闭工具栏设置窗口。"
    else if !config.buttons.Length
        result := "没有已配置的按钮。请在设置中添加按钮。"
    else if busy
        result := "工具栏正在处理操作，请稍后重试。"
    else {
        UpdateToolbar()
        result := monitorError != "" ? monitorError : target.reason
    }
    MsgBox(result, "快捷工具栏 · 输入框诊断")
}

LearnComposer(*) {
    snap := InspectComposer(true)
    if !snap {
        Notice(target.reason)
        return
    }
    if MsgBox("确认刚才聚焦的是当前对话的消息输入框？" Chr(10) "请核对后再保存。",
        "识别对话输入框", "YesNo Default2 Icon?") != "Yes"
        return
    entries := config.learned[snap.app]
    hasSignature := false
    for fingerprint in entries {
        if fingerprint == snap.signature {
            hasSignature := true
            break
        }
    }
    if !hasSignature {
        entries.Push(snap.signature)
        try config.Save(configPath)
        catch as caughtError {
            entries.Pop()
            Notice("无法保存输入框。 " caughtError.Message)
            return
        }
    }
    Notice("输入框已识别。请重新点击输入框。")
}

Trigger(button, *) {
    global busy, lastClick
    if busy || paused || settingsGui || !shownTarget || A_TickCount - lastClick < 450
        return
    PasteIntoComposer(button.text, button.enter)
}

PasteIntoComposer(text, pressEnter) {
    global busy, lastClick
    if busy || paused || settingsGui || !shownTarget
        return
    busy := true
    lastClick := A_TickCount
    savedClipboard := ""
    sequence := 0
    try {
        snapshot := shownTarget
        first := CheckTarget(snapshot)
        hwnd := first.hwnd
        for modifier in ["Alt", "Ctrl", "Shift", "LWin", "RWin"]
            if !KeyWait(modifier, "T1")
                throw Error("请松开组合键后重试。")

        savedClipboard := ClipboardAll()
        savedText := A_Clipboard
        A_Clipboard := text
        ; The button's own text must not enter the clipboard history.
        expectedClips.Push({text: text, until: A_TickCount + 5000})
        sequence := DllCall("GetClipboardSequenceNumber", "UInt")
        if !ClipWait(0.5)
            throw Error("Windows 剪贴板暂不可用。")
        CheckTarget(first)
        if DllCall("GetClipboardSequenceNumber", "UInt") != sequence
            throw Error("剪贴板已被其他应用更新，请重试。")
        if hwnd != target.Foreground()
            throw Error("前台窗口已改变。")
        SendInput("^v")
        Sleep(350)
        if pressEnter {
            CheckTarget(first)
            SendInput("{Enter}")
        }
    } catch as caughtError {
        Notice(caughtError.Message)
    } finally {
        try {
            if sequence && DllCall("GetClipboardSequenceNumber", "UInt") = sequence
                A_Clipboard := savedClipboard
        } catch {
            Notice("系统剪贴板正忙，未能恢复原内容。")
        }
        busy := false
    }
}

SendEnterButton(*) {
    global busy, lastClick
    if busy || paused || settingsGui || !shownTarget || A_TickCount - lastClick < 450
        return
    busy := true
    lastClick := A_TickCount
    try {
        first := CheckTarget(shownTarget)
        for modifier in ["Alt", "Ctrl", "Shift", "LWin", "RWin"]
            if !KeyWait(modifier, "T1")
                throw Error("请松开组合键后重试。")
        CheckTarget(first)
        SendInput("{Enter}")
    } catch as caughtError {
        Notice(caughtError.Message)
    } finally {
        busy := false
    }
}

ClipboardChanged(dataType) {
    if dataType != 1
        return
    text := A_Clipboard
    if text = "" {
        ; Delayed rendering or a slow writer: retry shortly instead of losing it.
        SetTimer(RetryClip, -250)
        return
    }
    AddClipHistory(text)
}

RetryClip() {
    text := A_Clipboard
    if text != ""
        AddClipHistory(text)
}

AddClipHistory(text) {
    global clipHistory, expectedClips
    ; Expire stale expectations so they can never swallow a later real copy.
    while expectedClips.Length && A_TickCount > expectedClips[1].until
        expectedClips.RemoveAt(1)
    ; Text written by the toolbar's own buttons is expected and never recorded.
    if expectedClips.Length && expectedClips[1].text == text {
        expectedClips.RemoveAt(1)
        return
    }
    for index, item in clipHistory
        if item == text {
            clipHistory.RemoveAt(index)
            break
        }
    clipHistory.InsertAt(1, text)
    if clipHistory.Length > 10
        clipHistory.Pop()
}

TrackHover(wParam, lParam, msg, hwnd) {
    global drag, pressInfo, hoverSince, clipPanel, flyHover, actionPanel
    RefreshVisuals()
    if !toolbar || DllCall("GetAncestor", "Ptr", hwnd, "UInt", 2, "Ptr") != toolbar.Hwnd
        return
    if drag {
        MoveFromDragNow()
        return
    }
    if pressInfo {
        cursor := CursorPosition()
        ; Past a small threshold the press becomes a toolbar drag, and the
        ; pending click is dropped.
        if Abs(cursor.x - pressInfo.x) > 6 || Abs(cursor.y - pressInfo.y) > 6 {
            WinGetPos(&x, &y, , , "ahk_id " toolbar.Hwnd)
            drag := {x: cursor.x - x, y: cursor.y - y, geo: ToolbarGeometry(shownTarget)}
            DllCall("SetCapture", "Ptr", toolbar.Hwnd)
            pressInfo := ""
            HideActionPanel()
            flyHover := ""
            return
        }
    }
    ; The instant the cursor reaches the send button, pop the panel — no timer
    ; latency. The stationary case is still covered by UpdateToolbar's fallback.
    if !clipPanel && MouseOnEnterBtn() {
        hoverSince := A_TickCount
        ShowClipPanel()
    }
    ; Action flyout dwell tracking on phrase buttons (instant once the dwell
    ; has elapsed; UpdateToolbar covers a cursor that never moves).
    MouseGetPos(, , , &actCtrl, 2)
    targetButton := ""
    for b in config.buttons
        if b.ctrl && b.ctrl = actCtrl {
            targetButton := b
            break
        }
    if targetButton {
        if !flyHover || flyHover.ctrl != actCtrl
            flyHover := {ctrl: actCtrl, since: A_TickCount, button: targetButton}
        if !actionPanel && A_TickCount - flyHover.since >= 300
            ShowActionPanel(targetButton)
    } else if flyHover
        flyHover := ""
}

MouseOnClipPanel() {
    global clipPanel
    if !clipPanel
        return false
    MouseGetPos(, , &win)
    return win && win = clipPanel.Hwnd
}

MouseOnEnterBtn() {
    global enterBtn
    if !enterBtn || !visible
        return false
    MouseGetPos(, , &win)
    if win != toolbar.Hwnd
        return false
    rect := Buffer(16)
    if !DllCall("GetWindowRect", "Ptr", enterBtn.Hwnd, "Ptr", rect)
        return false
    cursor := CursorPosition()
    return cursor.x >= NumGet(rect, 0, "Int") && cursor.x < NumGet(rect, 8, "Int")
        && cursor.y >= NumGet(rect, 4, "Int") && cursor.y < NumGet(rect, 12, "Int")
}

PanelHistoryKey() {
    global clipHistory
    return clipHistory.Length ":" (clipHistory.Length ? clipHistory[1] : "")
}

PanelStale() {
    global panelRenderedKey
    return PanelHistoryKey() != panelRenderedKey
}

ClipDiagnosis(*) {
    lines := "历史条数: " clipHistory.Length "`n`n"
    for index, item in clipHistory {
        preview := StrReplace(StrReplace(item, "`r`n", " "), "`n", " ")
        lines .= index ": " SubStr(preview, 1, 20) "`n"
    }
    current := StrReplace(StrReplace(A_Clipboard, "`r`n", " "), "`n", " ")
    lines .= "`n当前剪贴板文本（前 60 字）:`n" SubStr(current, 1, 60)
    MsgBox(lines, "剪贴板诊断")
}

PasteHistoryItem(text, *) {
    HideClipPanel()
    PasteIntoComposer(text, false)
}

ShowClipPanel() {
    global clipPanel, clipHistory, enterBtn, panelRenderedKey
    if !enterBtn
        return
    items := clipHistory.Clone()
    if !items.Length && A_Clipboard != ""
        items.Push(A_Clipboard)
    ; Newest at the bottom, closest to the toolbar button.
    oldestFirst := []
    Loop items.Length
        oldestFirst.Push(items[items.Length - A_Index + 1])
    items := oldestFirst
    HideClipPanel()
    ui := Gui("-Caption +Border +ToolWindow +E0x08000000 +AlwaysOnTop", "剪贴板历史")
    clipPanel := ui
    ui.BackColor := "FAFBFD"
    ui.MarginX := 4
    ui.MarginY := 4
    ui.SetFont("s9", "Microsoft YaHei UI")
    ui.AddText("xm ym w224 h22 +0x200 c374151", "  剪贴板历史")
    if !items.Length {
        ; Always show the panel, even when empty, so hovering reads as "empty"
        ; instead of feeling like nothing happened.
        ui.AddText("xm y+1 w224 h26 +0x200 c94A3B8", "  剪贴板是空的，复制后出现在这里")
    }
    Loop items.Length {
        text := items[A_Index]
        preview := StrReplace(StrReplace(text, "`r`n", " "), "`n", " ")
        preview := Trim(preview, " ")
        if StrLen(preview) > 18
            preview := SubStr(preview, 1, 18) "…"
        row := ui.AddText("xm y+1 w224 h26 +0x200", "  " preview)
        row.OnEvent("Click", PasteHistoryItem.Bind(text))
        RegisterVisual(row, "ECEEF1", "D9DDE3")
    }
    ui.Show("Hide AutoSize")
    rect := Buffer(16)
    ; Center the panel over the send button so the cursor enters mid-panel.
    DllCall("GetWindowRect", "Ptr", enterBtn.Hwnd, "Ptr", rect)
    btnCenter := (NumGet(rect, 0, "Int") + NumGet(rect, 8, "Int")) // 2
    btnTop := NumGet(rect, 4, "Int")
    prect := Buffer(16)
    DllCall("GetWindowRect", "Ptr", clipPanel.Hwnd, "Ptr", prect)
    width := NumGet(prect, 8, "Int") - NumGet(prect, 0, "Int")
    height := NumGet(prect, 12, "Int") - NumGet(prect, 4, "Int")
    x := btnCenter - width // 2
    y := btnTop - height - 6
    x := Max(SysGet(76), Min(SysGet(76) + SysGet(78) - width, x))
    y := Max(SysGet(77), Min(SysGet(77) + SysGet(79) - height, y))
    DllCall("SetWindowPos", "Ptr", clipPanel.Hwnd, "Ptr", -1, "Int", x, "Int", y,
        "Int", 0, "Int", 0, "UInt", 0x251)
    panelRenderedKey := PanelHistoryKey()
}

ShowActionPanel(button) {
    global actionPanel, actionInfo
    HideActionPanel()
    ; The flyout offers the opposite of the button's own behavior.
    wantEnter := !button.enter
    ui := Gui("-Caption +Border +ToolWindow +E0x08000000 +AlwaysOnTop")
    actionPanel := ui
    actionInfo := {button: button, enter: wantEnter}
    ui.BackColor := "FAFBFD"
    ui.MarginX := 3
    ui.MarginY := 2
    ui.SetFont("s9", "Microsoft YaHei UI")
    w := wantEnter ? 84 : 66
    btn := ui.AddText("xm ym w" w " h24 Center +0x200 c20242B", wantEnter ? "↵ 直接发送" : "只填入")
    btn.OnEvent("Click", ActionPanelClick)
    RegisterVisual(btn, wantEnter ? "E5F0FD" : "ECEEF1", wantEnter ? "C9E0FC" : "D9DDE3")
    ui.Show("Hide AutoSize")
    brect := Buffer(16)
    DllCall("GetWindowRect", "Ptr", button.ctrl, "Ptr", brect)
    center := (NumGet(brect, 0, "Int") + NumGet(brect, 8, "Int")) // 2
    trect := Buffer(16)
    DllCall("GetWindowRect", "Ptr", toolbar.Hwnd, "Ptr", trect)
    prect := Buffer(16)
    DllCall("GetWindowRect", "Ptr", actionPanel.Hwnd, "Ptr", prect)
    width := NumGet(prect, 8, "Int") - NumGet(prect, 0, "Int")
    height := NumGet(prect, 12, "Int") - NumGet(prect, 4, "Int")
    x := center - width // 2
    y := wantEnter ? NumGet(trect, 4, "Int") - height - 4 : NumGet(trect, 12, "Int") + 4
    x := Max(SysGet(76), Min(SysGet(76) + SysGet(78) - width, x))
    y := Max(SysGet(77), Min(SysGet(77) + SysGet(79) - height, y))
    DllCall("SetWindowPos", "Ptr", actionPanel.Hwnd, "Ptr", -1, "Int", x, "Int", y,
        "Int", 0, "Int", 0, "UInt", 0x251)
}

HideActionPanel() {
    global actionPanel, actionInfo, actionLeaveSince, visualStates
    actionLeaveSince := 0
    if actionPanel {
        for _, control in actionPanel
            if visualStates.Has(control.Hwnd)
                visualStates.Delete(control.Hwnd)
        actionPanel.Destroy()
        actionPanel := 0
        actionInfo := ""
    }
}

MouseOnActionPanel() {
    global actionPanel
    if !actionPanel
        return false
    MouseGetPos(, , &win)
    return win && win = actionPanel.Hwnd
}

ActionButtonHovered() {
    global actionInfo, toolbar
    if !actionInfo
        return false
    MouseGetPos(, , &win, &ctrl, 2)
    return win && win = toolbar.Hwnd && ctrl && ctrl = actionInfo.button.ctrl
}

ActionPanelClick(*) {
    global actionInfo
    if actionInfo
        PasteIntoComposer(actionInfo.button.text, actionInfo.enter)
    HideActionPanel()
}

HideClipPanel() {
    global clipPanel, visualStates, clipLeaveSince
    clipLeaveSince := 0
    if clipPanel {
        for _, control in clipPanel
            if visualStates.Has(control.Hwnd)
                visualStates.Delete(control.Hwnd)
        clipPanel.Destroy()
        clipPanel := 0
    }
}

VoiceButtonDown(wParam, lParam, msg, hwnd) {
    global voicePressStart, config
    if config.voiceKey = "" || voicePressStart
        return
    if !toolbar || !visible || DllCall("GetAncestor", "Ptr", hwnd, "UInt", 3, "Ptr") != toolbar.Hwnd
        return
    MouseGetPos(, , , &ctrl, 2)
    if !(ctrl && ctrl = voiceBtn.Hwnd)
        return
    voicePressStart := A_TickCount
    SetVoiceVisual()
    SetTimer(VoiceHoldCheck, -250)
}

VoiceHoldCheck() {
    global voiceHolding, voicePressStart, config
    if !voicePressStart || voiceHolding
        return
    if GetKeyState("LButton", "P") {
        voiceHolding := true
        seq := KeySequence(config.voiceKey, true)
        if seq != ""
            SendInput(seq)
        SetVoiceVisual()
    } else {
        voicePressStart := 0
        SetVoiceVisual()
    }
}

VoiceButtonUp(wParam, lParam, msg, hwnd) {
    ReleaseVoice()
}

ReleaseVoice() {
    global voiceHolding, voicePressStart, config
    if !voicePressStart
        return
    wasHolding := voiceHolding
    voiceHolding := false
    voicePressStart := 0
    SetTimer(VoiceHoldCheck, 0)
    if wasHolding {
        ; Held past the threshold: the key stayed down while talking, release it.
        seq := KeySequence(config.voiceKey, false)
        if seq != ""
            SendInput(seq)
    } else {
        ; Short click: send one full press, which toggles the voice input.
        ; KeySequence is required here — a bare "LAlt" would be typed as text.
        downSeq := KeySequence(config.voiceKey, true)
        upSeq := KeySequence(config.voiceKey, false)
        if downSeq != "" {
            SendInput(downSeq)
            Sleep(40)
            SendInput(upSeq)
        }
    }
    SetVoiceVisual()
}

KeySequence(key, press) {
    if !RegExMatch(key, "i)^([!^+#]*)([a-z0-9]|F(?:[1-9]|1[0-9]|2[0-4])|[LR](?:Alt|Ctrl|Shift|Win))?$", &m)
        return ""
    seq := ""
    if press {
        for sym, name in Map("!", "Alt", "^", "Ctrl", "+", "Shift", "#", "LWin")
            if InStr(m[1], sym)
                seq .= "{" name " down}"
        if m[2] != ""
            seq .= "{" m[2] " down}"
    } else {
        if m[2] != ""
            seq .= "{" m[2] " up}"
        for sym, name in Map("!", "Alt", "^", "Ctrl", "+", "Shift", "#", "LWin")
            if InStr(m[1], sym)
                seq .= "{" name " up}"
    }
    return seq
}

SetVoiceVisual() {
    RefreshVisuals()
}

RegisterVisual(control, hover, pressed) {
    global visualStates
    visualStates[control.Hwnd] := {control: control, hover: hover, pressed: pressed, state: ""}
    PaintVisual(visualStates[control.Hwnd], 0)
}

RefreshVisuals(*) {
    global visualStates, voiceBtn, voicePressStart, drag
    MouseGetPos(, , , &hovered, 2)
    pressed := GetKeyState("LButton", "P")
    for hwnd, item in visualStates {
        state := 0
        if voicePressStart && voiceBtn && hwnd = voiceBtn.Hwnd
            state := 2
        else if !drag && hwnd = hovered
            state := pressed ? 2 : 1
        PaintVisual(item, state)
    }
}

PaintVisual(item, state) {
    if item.state == state
        return
    item.state := state
    background := state = 2 ? item.pressed : state = 1 ? item.hover : "FAFBFD"
    item.control.Opt("Background" background)
    DllCall("InvalidateRect", "Ptr", item.control.Hwnd, "Ptr", 0, "Int", 1)
}

CheckTarget(first) {
    if first.hwnd != target.Foreground()
        throw Error("前台窗口已改变。")
    current := target.Inspect(first.hwnd, config.learned)
    if !current || current.app != first.app || !target.Same(first.element, current.element)
        || target.HasOwnedWindow(first.hwnd)
        throw Error("对话输入框焦点已改变，已停止操作。")
    return current
}

Notice(message) {
    ToolTip(message)
    SetTimer(ClearNotice, -3200)
}

ClearNotice(*) {
    ToolTip()
}
