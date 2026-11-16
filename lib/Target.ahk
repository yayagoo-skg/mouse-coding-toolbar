class ComposerTarget {
    __New(config) {
        this.automation := ComObject("{FF48DBA4-60EF-4201-AA87-54103EEF594E}",
            "{30CBE57D-D9D0-452A-AB13-7AC5AC4825EE}")
        ComCall(16, this.automation, "Ptr*", &walker := 0)
        this.walker := ComValue(13, walker)
        this.config := config
        this.lastHwnd := 0
        this.lastPid := 0
        this.lastApp := ""
        this.reason := "尚未检查输入框。"
    }

    Foreground() {
        return DllCall("GetForegroundWindow", "Ptr")
    }

    Identify(hwnd) {
        if !hwnd || DllCall("GetWindow", "Ptr", hwnd, "UInt", 4, "Ptr")
            return ""
        pid := 0
        DllCall("GetWindowThreadProcessId", "Ptr", hwnd, "UInt*", &pid)
        if !pid
            return ""
        if hwnd = this.lastHwnd && pid = this.lastPid
            return this.lastApp
        app := ""
        try {
            name := StrLower(WinGetProcessName("ahk_id " hwnd))
            for t in this.config.targets {
                if name != StrLower(t.exe)
                    continue
                if t.package = "" || this.PackageFamily(pid) = t.package {
                    app := t.name
                    break
                }
            }
        }
        this.lastHwnd := hwnd
        this.lastPid := pid
        this.lastApp := app
        return app
    }

    PackageFamily(pid) {
        process := DllCall("OpenProcess", "UInt", 0x1000, "Int", false, "UInt", pid, "Ptr")
        if !process
            return ""
        try {
            size := 0
            if DllCall("GetPackageFamilyName", "Ptr", process, "UInt*", &size, "Ptr", 0) != 122
                return ""
            family := Buffer(size * 2)
            if DllCall("GetPackageFamilyName", "Ptr", process, "UInt*", &size, "Ptr", family) = 0
                return StrGet(family, "UTF-16")
            return ""
        } finally DllCall("CloseHandle", "Ptr", process)
    }

    Inspect(hwnd, learned, calibration := false) {
        this.reason := "Windows 无障碍接口调用失败。"
        app := this.Identify(hwnd)
        if !app
            return this.Reject("前台窗口未识别为 ChatGPT 或 ZCode。")
        if hwnd != this.Foreground() || !DllCall("IsWindowEnabled", "Ptr", hwnd)
            return this.Reject("窗口已切换，或被弹窗禁用。")

        ComCall(6, this.automation, "Ptr", hwnd, "Ptr*", &rootPointer := 0)
        if !rootPointer
            return this.Reject("Windows 未返回应用窗口的无障碍控件。")
        root := ComValue(13, rootPointer)

        ComCall(8, this.automation, "Ptr*", &pointer := 0)
        if !pointer
            return this.Reject("Windows 未返回当前焦点控件。")
        current := ComValue(13, pointer)
        if !this.Int(current, 26)
            return this.Reject("Windows 返回的控件没有键盘焦点。")

        ; A hosted editor can expose a separate UIA tree inside a native child window.
        element := false
        windowConfirmed := false
        Loop 30 {
            role := this.String(current, 45)
            if role = "dialog" || role = "alertdialog"
                return this.Reject("当前焦点位于弹窗。")

            ComCall(36, current, "Ptr*", &nativeHwnd := 0) ; CurrentNativeWindowHandle
            if nativeHwnd = hwnd || this.Same(current, root) {
                windowConfirmed := true
                break
            }
            if nativeHwnd {
                if !DllCall("IsChild", "Ptr", hwnd, "Ptr", nativeHwnd)
                    break
                windowConfirmed := true
            }

            id := this.String(current, 29)
            ; React-generated ids (_r_xxx) and native handle ids change between
            ; sessions and windows, so they cannot take part in the signature.
            if RegExMatch(id, "^_r_") || RegExMatch(id, "^\d+$")
                id := ""
            if element {
                ; Avoid document names, which can contain the conversation title.
                name := (role = "form" || role = "group") ? this.String(current, 23) : ""
                if id != "" || name != "" {
                    hasIdentifier := true
                    signature .= this.Signature(current, id, name, role)
                }
                if app = "chatgpt" && id = "prompt-textarea"
                    composerId := true
            } else if this.Int(current, 21) = 50004 || role = "textbox" || role = "searchbox" {
                name := this.String(current, 23)
                if role = "searchbox" || RegExMatch(name, "i)^(?:(?:search|find)\b|搜索|查找)")
                    return this.Reject("当前焦点是搜索框。")
                if !this.Int(current, 28) || this.Int(current, 35)
                    || this.Int(current, 38) || !this.ReadableEdit(current)
                    return this.Reject("Windows 未将该控件识别为可编辑输入框。")
                element := current
                signature := this.Signature(current, id, name, role)
                hasIdentifier := id != "" || name != ""
                composerId := app = "chatgpt" && id = "prompt-textarea"
            }
            ComCall(3, this.walker, "Ptr", current, "Ptr*", &parent := 0)
            if !parent
                break
            current := ComValue(13, parent)
        }
        if !element && !windowConfirmed
            return this.Reject("未能确认当前焦点属于前台应用，也未找到可编辑控件。")
        if !element
            return this.Reject("前台应用已确认，但当前焦点及其父级没有可编辑的输入控件。")

        rect := Buffer(16, 0)
        ComCall(43, element, "Ptr", rect)
        left := NumGet(rect, 0, "Int"), top := NumGet(rect, 4, "Int")
        right := NumGet(rect, 8, "Int"), bottom := NumGet(rect, 12, "Int")
        if right <= left || bottom <= top || hwnd != this.Foreground()
            return this.Reject("输入框不可见，或前台窗口已切换。")
        if !windowConfirmed && !this.ConfirmAtPoint(hwnd, element, (left + right) // 2, (top + bottom) // 2)
            return this.Reject("已找到可编辑控件，但无法核对其窗口归属。请确认输入框没有被其他窗口遮挡。")

        if !composerId && !hasIdentifier
            return this.Reject("输入控件没有可用于校准的名称或标识。")
        if !composerId && !calibration {
            recognized := false
            for stored in learned[app] {
                if stored == signature {
                    recognized := true
                    break
                }
            }
            if !recognized
                return this.Reject("已找到可编辑控件。请在消息输入框内按 Ctrl+Alt+F8 识别。")
        }

        if hwnd != this.Foreground()
            return this.Reject("前台窗口已切换。")
        this.reason := "已识别消息输入框。"
        return {hwnd: hwnd, app: app, element: element, signature: signature,
            left: left, top: top, right: right, bottom: bottom}
    }

    ConfirmAtPoint(hwnd, element, x, y) {
        ; POINT is passed by value as two packed 32-bit coordinates, including on secondary monitors.
        point := (x & 0xFFFFFFFF) | (y << 32)
        hitHwnd := DllCall("WindowFromPoint", "Int64", point, "Ptr")
        ; A hit on our own floating toolbar or clip panel means the editor is
        ; covered by this tool, not by a foreign window, so allow it.
        rootHwnd := hitHwnd ? DllCall("GetAncestor", "Ptr", hitHwnd, "UInt", 3, "Ptr") : 0
        if rootHwnd && (rootHwnd = toolbar.Hwnd || (clipPanel && rootHwnd = clipPanel.Hwnd))
            return true
        if hitHwnd != hwnd && !DllCall("IsChild", "Ptr", hwnd, "Ptr", hitHwnd)
            return false
        ComCall(7, this.automation, "Int64", point, "Ptr*", &hit := 0)
        if !hit
            return false
        current := ComValue(13, hit)
        ; UIA can hit text inside the editor rather than the editor itself.
        Loop 12 {
            if this.Same(current, element)
                return true
            ComCall(3, this.walker, "Ptr", current, "Ptr*", &parent := 0)
            if !parent
                break
            current := ComValue(13, parent)
        }
        return false
    }

    Reject(message) {
        this.reason := message
        return false
    }

    Signature(element, id, name, role) {
        ; Accessible names follow placeholder and conversation state, so the signature
        ; keeps only structural fields that stay stable while the AI is streaming.
        value := ""
        for field in [id, role, this.String(element, 30), this.Int(element, 21)]
            value .= StrLen(field) ":" field
        return value "|"
    }

    Int(element, index) {
        ComCall(index, element, "Int*", &value := 0)
        return value
    }

    String(element, index) {
        ComCall(index, element, "Ptr*", &value := 0)
        return this.TakeBstr(value)
    }

    TakeBstr(pointer) {
        if !pointer
            return ""
        try return StrGet(pointer, "UTF-16")
        finally DllCall("OleAut32\SysFreeString", "Ptr", pointer)
    }

    Same(a, b) {
        ComCall(3, this.automation, "Ptr", a, "Ptr", b, "Int*", &same := 0)
        return same
    }

    Pattern(element, id) {
        pointer := 0
        try ComCall(16, element, "Int", id, "Ptr*", &pointer)
        return pointer ? ComValue(13, pointer) : false
    }

    ReadableEdit(element) {
        pattern := this.Pattern(element, 10002) ; ValuePattern
        if pattern
            return !this.Int(pattern, 5)
        range := this.TextRange(element)
        if !range
            return false
        attribute := Buffer(A_PtrSize = 8 ? 24 : 16, 0)
        try {
            ComCall(9, range, "Int", 40015, "Ptr", attribute) ; IsReadOnly
            return NumGet(attribute, 0, "UShort") = 11 && NumGet(attribute, 8, "Short") = 0
        } finally DllCall("OleAut32\VariantClear", "Ptr", attribute)
    }

    TextRange(element) {
        pattern := this.Pattern(element, 10014) ; TextPattern
        if !pattern
            return false
        ComCall(7, pattern, "Ptr*", &pointer := 0)
        return pointer ? ComValue(13, pointer) : false
    }

    HasOwnedWindow(hwnd) {
        info := Buffer(A_PtrSize = 8 ? 72 : 48, 0)
        NumPut("UInt", info.Size, info)
        if !DllCall("GetGUIThreadInfo", "UInt", 0, "Ptr", info) || NumGet(info, 4, "UInt") & 0x1E
            return true
        for other in WinGetList()
            if other != hwnd && DllCall("GetAncestor", "Ptr", other, "UInt", 3, "Ptr") = hwnd
                && DllCall("IsWindowVisible", "Ptr", other)
                return true
        return false
    }
}
