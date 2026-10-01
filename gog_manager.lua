local state = {
    hook_installed = false,
    calls = 0,
    gog_gunlance_calls = 0,
    swaps = 0,

    last_weapon_type = "None",
    last_focus = "None",
    last_original_shell = "None",
    last_returned_shell = "None",
    last_error = "None",
}

local function to_managed(value)
    if value == nil then
        return nil
    end

    local ok, object = pcall(function()
        return sdk.to_managed_object(value)
    end)

    if ok and object ~= nil then
        return object
    end

    return value
end

local function to_number(value)
    if value == nil then
        return nil
    end

    local numeric = tonumber(value)

    if numeric ~= nil then
        return numeric
    end

    local ok, converted = pcall(function()
        return sdk.to_int64(value)
    end)

    if ok then
        return tonumber(converted)
    end

    return nil
end

local function to_boolean(value)
    if value == true then
        return true
    elseif value == false or value == nil then
        return false
    end

    local numeric = to_number(value)

    return numeric ~= nil and numeric ~= 0
end

local function shell_name(value)
    if value == 0 then
        return "NORMAL [0]"
    elseif value == 1 then
        return "WIDE [1]"
    elseif value == 2 then
        return "LONG [2]"
    end

    return "OTHER [" .. tostring(value) .. "]"
end

local function focus_name(value)
    if value == 83 then
        return "ATTACK [83]"
    elseif value == 84 then
        return "AFFINITY [84]"
    elseif value == 85 then
        return "ELEMENT [85]"
    end

    return "OTHER [" .. tostring(value) .. "]"
end

local equip_set_type = nil
local equip_work_info_type = nil
local em0078_util_type = nil

local get_weapon_data = nil
local get_work_info = nil
local get_work = nil
local is_em0078_weapon = nil

local function inspect_equip_set(raw_equip_set)
    local equip_set = to_managed(raw_equip_set)

    if equip_set == nil then
        return false
    end

    local weapon_data =
        to_managed(
            get_weapon_data:call(equip_set)
        )

    if weapon_data == nil then
        return false
    end

    local is_gog =
        to_boolean(
            is_em0078_weapon:call(
                nil,
                weapon_data
            )
        )

    if not is_gog then
        return false
    end

    local work_info =
        to_managed(
            get_work_info:call(equip_set)
        )

    if work_info == nil then
        return false
    end

    local work =
        to_managed(
            get_work:call(work_info)
        )

    if work == nil then
        return false
    end

    local weapon_type =
        to_number(
            work:get_field("FreeVal0")
        )

    local focus =
        to_number(
            work:get_field("FreeVal1")
        )

    state.last_weapon_type =
        tostring(weapon_type)

    state.last_focus =
        focus_name(focus)

    -- FreeVal0 = 7 is Gunlance/Wp07.
    if weapon_type ~= 7 then
        return false
    end

    -- Attack Focus stays Normal.
    -- Only Gog Affinity/Element focuses are swapped.
    if focus ~= 84 and focus ~= 85 then
        return false
    end

    state.gog_gunlance_calls =
        state.gog_gunlance_calls + 1

    return true
end

local function install_hook()
    equip_set_type =
        sdk.find_type_definition(
            "app.EquipDef.EquipSet"
        )

    equip_work_info_type =
        sdk.find_type_definition(
            "app.EquipDef.EquipWorkInfo"
        )

    em0078_util_type =
        sdk.find_type_definition(
            "app.Em0078_ArtianUtil"
        )

    local weapon_util_type =
        sdk.find_type_definition(
            "app.WeaponUtil"
        )

    if equip_set_type == nil then
        error("app.EquipDef.EquipSet not found")
    end

    if equip_work_info_type == nil then
        error(
            "app.EquipDef.EquipWorkInfo not found"
        )
    end

    if em0078_util_type == nil then
        error(
            "app.Em0078_ArtianUtil not found"
        )
    end

    if weapon_util_type == nil then
        error("app.WeaponUtil not found")
    end

    get_weapon_data =
        equip_set_type:get_method(
            "get_WeaponData",
            0
        )

    get_work_info =
        equip_set_type:get_method(
            "get_WorkInfo",
            0
        )

    get_work =
        equip_work_info_type:get_method(
            "get_Work",
            0
        )

    is_em0078_weapon =
        em0078_util_type:get_method(
            "isEm0078_ArtianWeapon",
            1
        )

    local get_shell_type =
        weapon_util_type:get_method(
            "getWp07ShellType",
            1
        )

    if get_weapon_data == nil then
        error("EquipSet.get_WeaponData not found")
    end

    if get_work_info == nil then
        error("EquipSet.get_WorkInfo not found")
    end

    if get_work == nil then
        error("EquipWorkInfo.get_Work not found")
    end

    if is_em0078_weapon == nil then
        error(
            "Em0078_ArtianUtil."
            .. "isEm0078_ArtianWeapon not found"
        )
    end

    if get_shell_type == nil then
        error(
            "WeaponUtil.getWp07ShellType"
            .. "(EquipSet) not found"
        )
    end

    sdk.hook(
        get_shell_type,

        function(args)
            state.calls = state.calls + 1
            state.last_error = "None"

            local should_swap = false

            local ok, result = pcall(
                inspect_equip_set,
                args[2]
            )

            if ok then
                should_swap = result
            else
                state.last_error =
                    tostring(result)

                log.error(
                    "[Gog Gunlance shell swap] "
                    .. state.last_error
                )
            end

            thread.get_hook_storage().should_swap =
                should_swap
        end,

        function(retval)
            local storage =
                thread.get_hook_storage()

            if not storage.should_swap then
                return retval
            end

            local original =
                to_number(retval)

            if original == nil then
                state.last_error =
                    "Could not convert shell result"

                return retval
            end

            state.last_original_shell =
                shell_name(original)

            local replacement = original

            if original == 1 then
                -- Element Focus normally returns Wide.
                replacement = 2
            elseif original == 2 then
                -- Affinity Focus normally returns Long.
                replacement = 1
            end

            state.last_returned_shell =
                shell_name(replacement)

            if replacement ~= original then
                state.swaps = state.swaps + 1

                log.info(
                    "[Gog Gunlance shell swap] "
                    .. state.last_focus
                    .. ": "
                    .. shell_name(original)
                    .. " -> "
                    .. shell_name(replacement)
                )
            end

            return sdk.to_ptr(replacement)
        end
    )

    state.hook_installed = true
end

re.on_draw_ui(function()
    imgui.text(
        "Gog Gunlance Shell-Only Swap"
    )

    imgui.separator()

    imgui.text(
        "Hook installed: "
        .. tostring(state.hook_installed)
    )

    imgui.text(
        "Shell calls: "
        .. tostring(state.calls)
    )

    imgui.text(
        "Gog Gunlance calls: "
        .. tostring(state.gog_gunlance_calls)
    )

    imgui.text(
        "Swaps performed: "
        .. tostring(state.swaps)
    )

    imgui.separator()

    imgui.text(
        "Last FreeVal0: "
        .. state.last_weapon_type
    )

    imgui.text(
        "Last focus: "
        .. state.last_focus
    )

    imgui.text(
        "Original shell: "
        .. state.last_original_shell
    )

    imgui.text(
        "Returned shell: "
        .. state.last_returned_shell
    )

    imgui.text(
        "Last error: "
        .. state.last_error
    )
end)

local ok, error_message =
    pcall(install_hook)

if not ok then
    state.last_error =
        tostring(error_message)

    log.error(
        "[Gog Gunlance shell-only init] "
        .. state.last_error
    )
end
