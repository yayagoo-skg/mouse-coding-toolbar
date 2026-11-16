OpenSettings(*) {
    global settingsGui
    if settingsGui {
        settingsGui.Show()
        return
    }
    if busy
        return
    HideToolbar()
    ui := Gui("+MinSize650x500", "快捷指令设置")
    settingsGui := ui
    ui.SetFont("s10", "Microsoft YaHei UI")
    ui.MarginX := 16
    ui.MarginY := 12
    editor := SettingsEditor(ui)
    ui.OnEvent("Close", CloseSettings)
    ui.OnEvent("Escape", CloseSettings)
    editor.FillList()
    ui.Show()
}

CloseSettings(ui, *) {
    global settingsGui := 0
    ui.Destroy()
}

class SettingsEditor {
    __New(ui) {
        this.ui := ui
        this.rows := []
        this.selected := 0
        this.recording := false
        this.recordKeys := []
        for button in config.buttons
            this.rows.Push(button.Clone())
        options := config.options
        ui.AddText("xm", "按钮顺序")
        this.list := ui.AddListBox("xm w190 r10")
        this.list.OnEvent("Change", ObjBindMethod(this, "Select"))
        ui.AddButton("xm w45", "新增").OnEvent("Click", ObjBindMethod(this, "Add"))
        ui.AddButton("x+4 w45", "删除").OnEvent("Click", ObjBindMethod(this, "Delete"))
        ui.AddButton("x+4 w40", "↑").OnEvent("Click", ObjBindMethod(this, "Move", -1))
        ui.AddButton("x+4 w40", "↓").OnEvent("Click", ObjBindMethod(this, "Move", 1))

        ui.AddText("x227 ym", "按钮名称")
        this.label := ui.AddEdit("xp y+4 w405")
        ui.AddText("xp y+9", "填入内容")
        this.body := ui.AddEdit("xp y+4 w405 r7 +WantTab")
        ui.AddText("xp y+9", "快捷键")
        this.key := ui.AddEdit("x+8 yp w100")
        this.enter := ui.AddCheckbox("x+12 yp", "填入后回车")
        ui.AddText("x227 y+9 c475569", "例如 !1 = Alt+1，^+K = Ctrl+Shift+K。留空即禁用。")

        ui.AddText("xm y+20", "目标应用（进程名，逗号分隔）")
        this.targetsEdit := ui.AddEdit("x+8 yp w360", this.JoinTargets())
        ui.AddText("xm y+6 c475569", "工具栏只在目标应用中显示，如 chatgpt.exe, zcode.exe。添加后在该应用的输入框上按 Ctrl+Alt+F8 校准。")

        ui.AddText("xm y+20", "语音输入快捷键")
        this.voiceKey := ui.AddEdit("x+8 yp w90 ReadOnly BackgroundF8FAFC", config.voiceKey)
        this.voiceRecordBtn := ui.AddButton("x+6 yp w60", "录制")
        this.voiceRecordBtn.OnEvent("Click", ObjBindMethod(this, "ToggleVoiceRecord"))
        ui.AddText("xm y+6 c475569", "点「录制」后按下想要的组合键（如 Alt+V、Win+H），或单独按左/右 Alt、Ctrl、Shift、Win；Esc 取消。留空则不显示语音按钮。")

        ui.AddText("xm y+16", "按钮宽度（55–160）")
        this.width := ui.AddEdit("x+4 w46 Number", options["buttonWidth"])
        ui.AddText("x+14 yp", "高度（24–52）")
        this.height := ui.AddEdit("x+4 w46 Number", options["buttonHeight"])
        ui.AddText("x+14 yp", "不透明度（100–255）")
        this.opacity := ui.AddEdit("x+4 w46 Number", options["opacity"])
        this.topmost := ui.AddCheckbox("xm y+15 Checked" options["alwaysOnTop"], "始终置顶")
        this.hotkeys := ui.AddCheckbox("x+18 Checked" options["hotkeys"], "启用快捷键")
        this.startup := ui.AddCheckbox("x+18 Checked" options["startup"], "登录 Windows 时启动")
        this.reset := ui.AddCheckbox("x+18", "恢复默认位置")
        ui.AddButton("xm y+16 w100 Default", "保存").OnEvent("Click", ObjBindMethod(this, "Save"))
        ui.AddButton("x+8 w100", "取消").OnEvent("Click", (*) => CloseSettings(ui))
    }

    CommitRow() {
        if !this.selected
            return
        row := this.rows[this.selected]
        row.label := Trim(this.label.Value)
        row.text := this.body.Value
        row.key := Trim(this.key.Value)
        row.enter := this.enter.Value ? true : false
    }

    FillList(index := 1) {
        labels := []
        for row in this.rows
            labels.Push(row.label != "" ? row.label : "未命名")
        this.list.Delete()
        if labels.Length
            this.list.Add(labels)
        this.selected := Min(index, labels.Length)
        this.list.Choose(this.selected)
        this.ShowRow()
    }

    ShowRow() {
        row := this.selected ? this.rows[this.selected] : {label: "", text: "", key: "", enter: false}
        this.label.Value := row.label
        this.body.Value := row.text
        this.key.Value := row.key
        this.enter.Value := row.enter ? true : false
        for control in [this.label, this.body, this.key, this.enter]
            control.Enabled := this.selected != 0
    }

    Select(*) {
        index := this.list.Value
        this.CommitRow()
        this.FillList(index)
    }

    Add(*) {
        this.CommitRow()
        this.rows.Push({label: "新按钮", text: "", key: "", enter: false})
        this.FillList(this.rows.Length)
        this.label.Focus()
    }

    Delete(*) {
        if !this.selected
            return
        this.rows.RemoveAt(this.selected)
        this.FillList(this.selected)
    }

    Move(delta, *) {
        index := this.selected + delta
        if !this.selected || index < 1 || index > this.rows.Length
            return
        this.CommitRow()
        row := this.rows.RemoveAt(this.selected)
        this.rows.InsertAt(index, row)
        this.FillList(index)
    }

    JoinTargets() {
        names := ""
        for t in config.targets
            names .= (names = "" ? "" : ", ") t.exe
        return names
    }

    ParseTargets(previous) {
        targets := []
        for part in StrSplit(Trim(this.targetsEdit.Value), ",") {
            part := Trim(part)
            if part = ""
                continue
            exe := StrLower(part)
            ; Keep the stored name (and any package rule) when the exe already
            ; exists, so learned calibrations survive a settings round-trip.
            for t in previous
                if StrLower(t.exe) = exe {
                    targets.Push({name: t.name, exe: t.exe, package: t.package})
                    break
                }
            if targets.Length && StrLower(targets[targets.Length].exe) = exe
                continue
            targets.Push({name: RegExReplace(part, "i)\.exe$"), exe: part, package: ""})
        }
        return targets
    }

    Save(*) {
        global config, target
        this.CommitRow()
        previous := config
        candidate := config.Clone()
        candidate.options := config.options.Clone()
        candidate.buttons := this.rows
        candidate.targets := this.ParseTargets(previous.targets)
        try {
            for key, control in Map("buttonWidth", this.width, "buttonHeight", this.height,
                "opacity", this.opacity, "alwaysOnTop", this.topmost, "hotkeys", this.hotkeys,
                "startup", this.startup)
                candidate.options[key] := Integer(control.Value)
            if this.reset.Value {
                candidate.options["offsetX"] := 0
                candidate.options["offsetY"] := 0
            }
            candidate.voiceKey := Trim(this.voiceKey.Value)
            candidate.Validate()
            config := candidate
            target.config := candidate
            RegisterShortcuts()
            BuildToolbar()
            if previous.options["startup"] != candidate.options["startup"]
                SetStartup(candidate.options["startup"])
            candidate.Save(configPath)
        } catch as caughtError {
            config := previous
            try target.config := previous
            try RegisterShortcuts()
            try BuildToolbar()
            if previous.options["startup"] != candidate.options["startup"]
                try SetStartup(previous.options["startup"])
            MsgBox("设置未保存。 " caughtError.Message, "快捷指令设置", "Icon!")
            return
        }
        CloseSettings(this.ui)
    }

    ToggleVoiceRecord(*) {
        if this.recording {
            this.StopVoiceRecord("")
            return
        }
        this.recording := true
        this.captured := ""
        this.recordKeys := []
        this.voiceRecordBtn.Text := "按键中…"
        callback := ObjBindMethod(this, "CaptureKey")
        for name in this.KeyNames()
            this.Record("*" name, callback)
        for name in ["LAlt up", "RAlt up", "LCtrl up", "RCtrl up"
            , "LShift up", "RShift up", "LWin up", "RWin up"]
            this.Record(name, callback)
        this.Record("*Esc", callback)
    }

    Record(name, callback) {
        try {
            Hotkey(name, callback, "On")
            this.recordKeys.Push(name)
        }
    }

    CaptureKey(*) {
        if !this.recording
            return
        hot := A_ThisHotkey
        if hot = "*Esc" {
            this.StopVoiceRecord("")
            return
        }
        if InStr(hot, " up") {
            ; A modifier released with no main key in between: single-modifier hotkey.
            if this.captured = ""
                this.StopVoiceRecord(SubStr(hot, 1, -3))
            return
        }
        mainKey := SubStr(hot, 2)
        syms := ""
        for pair in Map("Alt", "!", "Ctrl", "^", "Shift", "+", "Win", "#")
            if GetKeyState(pair[1], "P")
                syms .= pair[2]
        this.captured := syms mainKey
        this.StopVoiceRecord(this.captured)
    }

    StopVoiceRecord(key) {
        if !this.recording
            return
        this.recording := false
        for hk in this.recordKeys
            try Hotkey(hk, "Off")
        this.recordKeys := []
        this.voiceRecordBtn.Text := "录制"
        if key != ""
            this.voiceKey.Value := key
    }

    KeyNames() {
        names := []
        Loop 26
            names.Push(Chr(96 + A_Index))
        Loop 10
            names.Push(String(A_Index - 1))
        Loop 24
            names.Push("F" A_Index)
        names.Push("Space", "Enter", "Tab")
        return names
    }
}

SetStartup(enabled) {
    path := A_Startup "\MouseCodingToolbar.lnk"
    legacy := A_Startup "\CodexQuickToolbar.lnk"
    if enabled {
        FileCreateShortcut(A_AhkPath, path, A_ScriptDir, '"' A_ScriptFullPath '"', "Mouse Coding Toolbar")
        if FileExist(legacy)
            FileDelete(legacy)
    } else {
        if FileExist(path)
            FileDelete(path)
        if FileExist(legacy)
            FileDelete(legacy)
    }
}
