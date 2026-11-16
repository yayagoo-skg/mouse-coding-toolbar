class ToolbarConfig {
    __New(path) {
        this.options := Map()
        this.buttons := []
        this.targets := []
        this.learned := Map()
        this.voiceKey := ""
        for line in StrSplit(FileRead(path, "UTF-8"), "`n", "`r") {
            if line = ""
                continue
            fields := StrSplit(line, "`t")
            switch fields[1] {
                case "option":
                    this.options[fields[2]] := Integer(fields[3])
                case "button":
                    ; Field 4 carries the action ("fill" or "send"); field 5 keeps the shortcut.
                    this.buttons.Push({label: this.Decode(fields[2]), text: this.Decode(fields[3]),
                        enter: fields.Length > 3 && fields[4] = "send",
                        key: fields.Length > 4 ? fields[5] : ""})
                case "target":
                    this.targets.Push({name: Trim(fields[2]), exe: Trim(fields[3]),
                        package: fields.Length > 3 ? Trim(fields[4]) : ""})
                case "learn":
                    if !this.learned.Has(fields[2])
                        this.learned[fields[2]] := []
                    this.learned[fields[2]].Push(this.Decode(fields[3]))
                case "voice":
                    this.voiceKey := fields[2]
            }
        }
        ; Migrate configs from before target apps were configurable.
        if !this.targets.Length {
            this.targets.Push({name: "chatgpt", exe: "chatgpt.exe",
                package: "OpenAI.Codex_2p2nqsd0c76g0"})
            this.targets.Push({name: "zcode", exe: "zcode.exe", package: ""})
            for t in this.targets
                this.learned[t.name] := this.learned.Has(t.name) ? this.learned[t.name] : []
        }
        this.Validate()
    }

    Save(path) {
        this.Validate()
        data := ""
        for key, value in this.options
            data .= "option`t" key "`t" value "`n"
        for button in this.buttons
            data .= "button`t" this.Encode(button.label) "`t" this.Encode(button.text)
                . "`t" (button.enter ? "send" : "fill") "`t" button.key "`n"
        for t in this.targets
            data .= "target`t" t.name "`t" t.exe (t.package != "" ? "`t" t.package : "") "`n"
        data .= "voice`t" this.voiceKey "`n"
        for app, fingerprints in this.learned
            for fingerprint in fingerprints
                data .= "learn`t" app "`t" this.Encode(fingerprint) "`n"

        SplitPath(path, , &directory)
        DirCreate(directory)
        temp := path ".tmp"
        file := FileOpen(temp, "w", "UTF-8")
        try file.Write(data)
        finally file.Close()
        ; MoveFileEx replaces the old file only after the complete new file was written.
        if !DllCall("MoveFileExW", "Str", temp, "Str", path, "UInt", 9)
            throw OSError()
    }

    Validate() {
        for key, limits in Map("buttonWidth", [55, 160], "buttonHeight", [24, 52],
            "opacity", [100, 255], "alwaysOnTop", [0, 1], "hotkeys", [0, 1],
            "startup", [0, 1], "offsetX", [-20000, 20000], "offsetY", [-20000, 20000]) {
            if !this.options.Has(key) || this.options[key] < limits[1] || this.options[key] > limits[2]
                throw ValueError("设置超出范围：" key)
        }
        if this.voiceKey != "" && !RegExMatch(this.voiceKey, "i)^([!^+#]*)([a-z0-9]|F(?:[1-9]|1[0-9]|2[0-4])|[LR](?:Alt|Ctrl|Shift|Win))?$")
            throw ValueError("语音快捷键无效：可用修饰键+字母/数字/F键，或单独的左右 Alt/Ctrl/Shift/Win。")
        names := Map()
        for t in this.targets {
            if t.name = "" || t.exe = ""
                throw ValueError("目标应用的名称和进程名不能为空。")
            key := StrLower(t.name)
            if names.Has(key)
                throw ValueError("目标应用名称重复：" t.name)
            names[key] := true
            if !this.learned.Has(t.name)
                this.learned[t.name] := []
        }
        for key, entries in this.learned.Clone()
            if !names.Has(StrLower(key))
                this.learned.Delete(key)
        keys := Map()
        for button in this.buttons {
            if !Trim(button.label) || !Trim(button.text, " `t`r`n")
                throw ValueError("按钮名称和内容均不能为空。")
            button.enter := button.enter ? true : false
            modifiers := "", key := ""
            if button.key != "" {
                if !RegExMatch(button.key, "i)^([!^+#]+)([a-z0-9]|F(?:[1-9]|1[0-9]|2[0-4]))$", &match)
                    throw ValueError("快捷键格式无效，请使用 !1、^+K 或 ^!F9 这样的格式。")
                for symbol in ["^", "!", "+", "#"]
                    if InStr(match[1], symbol)
                        modifiers .= symbol
                key := modifiers StrUpper(match[2])
                if StrLen(modifiers) != StrLen(match[1]) || keys.Has(key) || key = "^!F8"
                    throw ValueError("快捷键重复或已保留：" key)
                keys[key] := true
            }
            button.key := key
        }
    }

    Encode(value) {
        return StrReplace(StrReplace(StrReplace(StrReplace(value, "%", "%25"), "`t", "%09"),
            "`r", "%0D"), "`n", "%0A")
    }

    Decode(value) {
        return StrReplace(StrReplace(StrReplace(StrReplace(value, "%0A", "`n", true),
            "%0D", "`r", true), "%09", "`t", true), "%25", "%", true)
    }
}
