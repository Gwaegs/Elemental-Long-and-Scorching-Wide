-- wp07_long_elemental_shelling.lua
--
-- Long Gunlance attribute-aware elemental/status shelling and raw normalization.
--
-- Raw Long Gunlance:
--   Keeps its normal fixed fire component.
--
-- Elemental Long Gunlance:
--   Enables weapon element at 2.0 base scaling.
--   Artillery 1/2/3 multiplies shell element by 1.06/1.12/1.18.
--   Charged shell element is multiplied by 1.6.
--   Full Burst element is multiplied by 1.15.
--   BF/RBF Full Burst element is multiplied by 0.96.
--   Wyvern Fire receives no additional action multiplier.
--   Wyrmstake ticking hits retain their native 0.5 element rate and are
--   identified per runtime request, so simultaneous shells remain at full rate.
--   User3 charged/FB/BF/RBF raw multipliers are neutralized to 1.0 only
--   for qualifying true-element Long, then restored for all other weapons.
--   Based on testing, weapon element replaces fixed shell fire.
--
-- Status Long Gunlance:
--   Enables status buildup at 0.55 scaling.
--   Fixed shell fire remains.
--   Ordinary crafted/non-Gog Long Gunlances use WeaponData._Attribute:
--     0 = raw, 1-5 = true element, 6+ = status.
--
-- Normal and Wide Gunlances:
--   Unchanged.
--
-- Shell-type detection:
--   Reads cHunterWp07Handling._ShellType continuously for both Gog and
--   non-Gog Gunlances, preventing stale Long/Normal/Wide state after swaps.
--
-- After switching Gunlances, press "Refresh shell type" in the
-- REFramework UI.

------------------------------------------------------------
-- CONFIGURATION
------------------------------------------------------------

local ELEMENT_RATE = 2.0
local STATUS_RATE = 0.55
local WYRMSTAKE_ELEMENT_RATE = 0.5

local ELEMENT_ACTION_MULTIPLIER = {
    UNCHARGED = 1.0,
    CHARGED = 1.6,
    FULLBURST = 1.15,
    BF_FULLBURST = 0.96,
    RBF_FULLBURST = 0.96,
    WYVERN_FIRE = 1.0,
}

local ARTILLERY_ELEMENT_MULTIPLIER = {
    [0] = 1.00,
    [1] = 1.06,
    [2] = 1.12,
    [3] = 1.18,
}

local ARTILLERY_SKILL_ID = 36
local ARTILLERY_RAW_VALUE_INDEX = 0
local ARTILLERY_FIRE_VALUE_INDEX = 2

-- Canonical Artillery values confirmed from SkillData.
local ARTILLERY_RAW_CANONICAL = {
    [0] = 5,
    [1] = 10,
    [2] = 15,
}

local ARTILLERY_FIRE_CANONICAL = {
    [0] = 3,
    [1] = 6,
    [2] = 9,
}

-- Confirmed cross-weapon FreeVal2 attribute IDs.
local TRUE_ELEMENT_FREEVAL2 = {
    [22611] = "FIRE",
    [31749] = "WATER",
    [22190] = "THUNDER",
    [29119] = "ICE",
    [18812] = "DRAGON",
}

local STATUS_FREEVAL2 = {
    [27364] = "POISON",
    [19855] = "PARALYSIS",
    [19961] = "SLEEP",
    [410] = "BLAST",
}

-- Ordinary crafted/non-Gog weapons expose their attribute through
-- app.user_data.WeaponData.cData._Attribute._Value.
-- 0 = raw, 1-5 = true element, 6+ = status.
local WEAPON_DATA_ELEMENT_NAMES = {
    [1] = "FIRE",
    [2] = "WATER",
    [3] = "ICE",
    [4] = "THUNDER",
    [5] = "DRAGON",
}

local SHELL_PARAM_TYPE =
    "app.col_user_data.AttackParamPlShell"

local SHELL_PARAM_METHOD =
    "createRuntimeAttackParam"

local SHELL_TYPE_ENUM =
    "app.Wp07Def.SHELL_TYPE"

------------------------------------------------------------
-- STATE
------------------------------------------------------------

local hook_installed = false
local error_message = nil

local runtime_calls = 0
local modified_calls = 0

local shell_type_detected = false
local current_shell_type_value = nil
local current_shell_type_path = nil
local current_shell_type_name = "Unknown"

local long_shell_type_value = nil

local detector_status = "Not scanned"

local gog_focus_value = nil
local gog_focus_name = "Not detected"
local handling_hook_installed = false
local handling_update_calls = 0
local combat_shell_writes = 0
local ammo_rebuilds = 0
local combat_shell_status = "Not applied"

local frame = 0

local action_state = {
    charged_until = -1,
    pending_fullburst = "NONE",
    active_fullburst = "NONE",
    fullburst_until = -1,
    wyvern_fire_until = -1,
}

local hunter_skill = nil
local artillery_level_data_list = nil
local artillery_values_zeroed = false
local artillery_last_error = "Not attempted"
local artillery_retry_count = 0
local artillery_live_values = "Unavailable"
local current_artillery_level = 0
local current_artillery_element_multiplier = 1.0
local current_element_action_multiplier = 1.0
local current_effective_element_rate = ELEMENT_RATE

-- Forward declaration because restore_artillery_values() calls this helper
-- before its full definition appears later in the file.
local refresh_artillery_live_values

local element_detector_status = "Not scanned"
local element_detector_path = nil
local element_detector_value = nil
local element_detector_source = "Unknown"
local qualifying_elemental_long = false
local qualifying_status_long = false
local current_attribute_id = nil
local current_attribute_name = "UNKNOWN"
local current_attribute_class = "UNKNOWN"

local long_user3_rates_neutralized = false
local long_user3_rate_status = "Not applied"
local long_charge_live = nil
local long_fullburst_live = nil
local long_bf_live = nil
local long_rbf_live = nil

local LONG_CHARGE_CANONICAL = 1.70
local LONG_FULLBURST_CANONICAL = 1.075
local LONG_BF_CANONICAL = 0.960
local LONG_RBF_CANONICAL = 0.960

local raw_normalization_attempts = 0
local raw_normalization_successes = 0
local last_action_context = "UNCHARGED"
local last_shell_param_kind = "UNKNOWN"
local last_raw_rate_before = nil
local last_raw_rate_after = nil

------------------------------------------------------------
-- BASIC HELPERS
------------------------------------------------------------

local function safe_to_managed_object(value)
    if value == nil then
        return nil
    end

    local ok, object = pcall(function()
        return sdk.to_managed_object(value)
    end)

    if ok then
        return object
    end

    return nil
end

local function safe_get_field(object, field_name)
    if object == nil then
        return nil
    end

    local ok, value = pcall(function()
        return object:get_field(field_name)
    end)

    if ok then
        return value
    end

    return nil
end

local function safe_set_field(object, field_name, value)
    if object == nil or value == nil then
        return false
    end

    return pcall(function()
        object:set_field(field_name, value)
    end)
end

local function safe_address(object)
    if object == nil then
        return nil
    end

    local ok, address = pcall(function()
        return object:get_address()
    end)

    if ok and address ~= nil then
        return tostring(address)
    end

    return nil
end

local function safe_type_definition(object)
    if object == nil then
        return nil
    end

    local ok, type_definition = pcall(function()
        return object:get_type_definition()
    end)

    if ok then
        return type_definition
    end

    return nil
end

local function safe_type_name(object)
    local type_definition = safe_type_definition(object)

    if type_definition == nil then
        return nil
    end

    local ok, name = pcall(function()
        return type_definition:get_full_name()
    end)

    if ok then
        return name
    end

    return nil
end

local function approximately_equal(a, b)
    if type(a) ~= "number" or type(b) ~= "number" then
        return false
    end

    return math.abs(a - b) < 0.0001
end


local function call_method(object, method_name, ...)
    if object == nil then
        return false, nil
    end

    local args = { ... }

    return pcall(function()
        return object:call(
            method_name,
            table.unpack(args)
        )
    end)
end

local function array_get(array, index)
    array = safe_to_managed_object(array) or array

    if array == nil then
        return nil
    end

    local attempts = {
        function()
            return array:call("get_Item", index)
        end,
        function()
            return array:call("GetValue", index)
        end,
    }

    for _, attempt in ipairs(attempts) do
        local ok, value = pcall(attempt)

        if ok then
            return safe_to_managed_object(value) or value
        end
    end

    return nil
end

local function array_set(array, index, value)
    array = safe_to_managed_object(array) or array

    if array == nil then
        return false
    end

    local attempts = {
        function()
            return array:call(
                "set_Item",
                index,
                value
            )
        end,
        function()
            return array:call(
                "SetValue",
                value,
                index
            )
        end,
    }

    for _, attempt in ipairs(attempts) do
        if pcall(attempt) then
            return true
        end
    end

    return false
end

local function get_count(object)
    local ok, count =
        call_method(object, "get_Count")

    if ok and count ~= nil then
        return tonumber(count)
    end

    ok, count =
        call_method(object, "get_Length")

    if ok and count ~= nil then
        return tonumber(count)
    end

    return nil
end

local function find_method(type_definition, name, count)
    if type_definition == nil then
        return nil
    end

    if count ~= nil then
        local ok, method = pcall(function()
            return type_definition:get_method(
                name,
                count
            )
        end)

        if ok and method ~= nil then
            return method
        end
    end

    local ok, method = pcall(function()
        return type_definition:get_method(name)
    end)

    if ok then
        return method
    end

    return nil
end

local function hook_pre(
    type_definition,
    method_name,
    count,
    callback
)
    local method =
        find_method(
            type_definition,
            method_name,
            count
        )

    if method == nil then
        log.info(
            "[WP07 Long Shelling] Missing action method: " ..
            tostring(method_name)
        )

        return false
    end

    sdk.hook(
        method,

        function(args)
            local ok, err =
                pcall(callback, args)

            if not ok then
                log.info(
                    "[WP07 Long Shelling] Action hook error " ..
                    tostring(method_name) ..
                    ": " ..
                    tostring(err)
                )
            end
        end,

        function(retval)
            return retval
        end
    )

    return true
end

local function lower(text)
    if text == nil then
        return ""
    end

    return string.lower(tostring(text))
end

local function contains(text, search)
    return string.find(
        lower(text),
        lower(search),
        1,
        true
    ) ~= nil
end

------------------------------------------------------------
-- ENUM VALUE HELPERS
------------------------------------------------------------

local function normalize_enum_value(value)
    if type(value) == "number" then
        return value
    end

    if value == nil then
        return nil
    end

    local possible_fields = {
        "value__",
        "_Value",
        "value",
        "mValue",
    }

    for _, field_name in ipairs(possible_fields) do
        local result = safe_get_field(value, field_name)

        if type(result) == "number" then
            return result
        end
    end

    return nil
end

local function get_all_fields(type_definition)
    local output = {}
    local visited_types = {}

    local current = type_definition

    while current ~= nil do
        local current_name = nil

        pcall(function()
            current_name = current:get_full_name()
        end)

        if current_name ~= nil
            and visited_types[current_name] then

            break
        end

        if current_name ~= nil then
            visited_types[current_name] = true
        end

        local fields = nil

        pcall(function()
            fields = current:get_fields()
        end)

        if fields ~= nil then
            for _, field in ipairs(fields) do
                table.insert(output, field)
            end
        end

        local parent = nil

        pcall(function()
            parent = current:get_parent_type()
        end)

        current = parent
    end

    return output
end

local function find_long_enum_value()
    local enum_type =
        sdk.find_type_definition(SHELL_TYPE_ENUM)

    if enum_type == nil then
        return nil
    end

    local fields = get_all_fields(enum_type)

    for _, field in ipairs(fields) do
        local field_name = nil
        local is_static = false

        pcall(function()
            field_name = field:get_name()
        end)

        pcall(function()
            is_static = field:is_static()
        end)

        if is_static
            and field_name ~= nil
            and contains(field_name, "long") then

            local value = nil

            pcall(function()
                value = field:get_data(nil)
            end)

            local normalized =
                normalize_enum_value(value)

            if normalized ~= nil then
                log.info(
                    "[WP07 Long Shelling] " ..
                    "LONG enum constant: " ..
                    tostring(field_name) ..
                    " = " ..
                    tostring(normalized)
                )

                return normalized
            end
        end
    end

    return nil
end

------------------------------------------------------------
-- ACTIVE PLAYER LOOKUP
------------------------------------------------------------

local function try_call(object, method_name)
    if object == nil then
        return nil
    end

    local ok, result = pcall(function()
        return object:call(method_name)
    end)

    if ok then
        return result
    end

    return nil
end

local function get_master_player()
    local player_manager =
        sdk.get_managed_singleton("app.PlayerManager")

    if player_manager == nil then
        return nil, "PlayerManager unavailable"
    end

    local method_candidates = {
        "get_MasterPlayer",
        "getMasterPlayer",
        "get_MasterPlayerObject",
        "getMasterPlayerObject",
        "get_MainPlayer",
        "getMainPlayer",
        "get_Player",
        "getPlayer",
    }

    for _, method_name in ipairs(method_candidates) do
        local player =
            try_call(player_manager, method_name)

        if safe_type_definition(player) ~= nil then
            return player, method_name .. "()"
        end
    end

    local field_candidates = {
        "_MasterPlayer",
        "MasterPlayer",
        "_MasterPlayerObject",
        "_MainPlayer",
        "_Player",
        "Player",
    }

    for _, field_name in ipairs(field_candidates) do
        local player =
            safe_get_field(player_manager, field_name)

        if safe_type_definition(player) ~= nil then
            return player, field_name
        end
    end

    return nil, "Could not locate active player"
end

------------------------------------------------------------
-- OBJECT GRAPH SCANNER
------------------------------------------------------------

local MAX_SCAN_DEPTH = 6
local MAX_SCAN_OBJECTS = 400

local function should_skip_field(field_name, field_type_name)
    local name = lower(field_name)
    local type_name = lower(field_type_name)

    local blocked_terms = {
        "catalog",
        "dictionary",
        "hashset",
        "list`",
        "array",
        "cache",
        "allweapon",
        "allitem",
        "enemy",
        "quest",
        "effect",
        "sound",
        "motion",
    }

    for _, term in ipairs(blocked_terms) do
        if contains(name, term)
            or contains(type_name, term) then

            return true
        end
    end

    return false
end

local function should_follow_field(field_name, field_type_name)
    if should_skip_field(field_name, field_type_name) then
        return false
    end

    local useful_terms = {
        "weapon",
        "equip",
        "item",
        "wp",
        "player",
        "master",
        "data",
        "holder",
        "param",
        "current",
        "use",
        "shell",
    }

    for _, term in ipairs(useful_terms) do
        if contains(field_name, term)
            or contains(field_type_name, term) then

            return true
        end
    end

    return false
end

local function find_shell_type_in_object_graph(root)
    if root == nil then
        return nil
    end

    local visited = {}
    local scanned_objects = 0

    local function scan(object, path, depth)
        if object == nil
            or depth > MAX_SCAN_DEPTH
            or scanned_objects >= MAX_SCAN_OBJECTS then

            return nil
        end

        local address = safe_address(object)

        if address == nil or visited[address] then
            return nil
        end

        visited[address] = true
        scanned_objects = scanned_objects + 1

        local type_definition =
            safe_type_definition(object)

        if type_definition == nil then
            return nil
        end

        local fields =
            get_all_fields(type_definition)

        for _, field in ipairs(fields) do
            local field_name = nil
            local field_type = nil
            local field_type_name = nil
            local is_static = false

            pcall(function()
                field_name = field:get_name()
            end)

            pcall(function()
                field_type = field:get_type()
            end)

            pcall(function()
                if field_type ~= nil then
                    field_type_name =
                        field_type:get_full_name()
                end
            end)

            pcall(function()
                is_static = field:is_static()
            end)

            if not is_static and field_name ~= nil then
                local value = nil

                pcall(function()
                    value = field:get_data(object)
                end)

                if field_type_name == SHELL_TYPE_ENUM then
                    local normalized =
                        normalize_enum_value(value)

                    if normalized ~= nil then
                        return {
                            value = normalized,
                            path =
                                path ..
                                "." ..
                                tostring(field_name),
                            scanned_objects =
                                scanned_objects,
                        }
                    end
                end

                if depth < MAX_SCAN_DEPTH
                    and field_type_name ~= nil
                    and should_follow_field(
                        field_name,
                        field_type_name
                    ) then

                    if safe_type_definition(value) ~= nil then
                        local result = scan(
                            value,
                            path ..
                                "." ..
                                tostring(field_name),
                            depth + 1
                        )

                        if result ~= nil then
                            return result
                        end
                    end
                end
            end
        end

        return nil
    end

    return scan(
        root,
        safe_type_name(root) or "Player",
        0
    )
end

------------------------------------------------------------
-- GOG ARTIAN FOCUS / LIVE HANDLING OVERRIDE
------------------------------------------------------------

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

local function get_current_gog_focus()
    local equip_util =
        sdk.find_type_definition("app.EquipUtil")

    if equip_util == nil then
        return nil
    end

    local get_weapon_work =
        equip_util:get_method(
            "getEquipWorkWeapon",
            1
        )

    if get_weapon_work == nil then
        return nil
    end

    local ok, work = pcall(function()
        return get_weapon_work:call(nil, 0)
    end)

    if not ok or work == nil then
        return nil
    end

    work = safe_to_managed_object(work) or work

    local weapon_type =
        tonumber(safe_get_field(work, "FreeVal0"))

    local focus =
        tonumber(safe_get_field(work, "FreeVal1"))

    if weapon_type ~= 7 then
        return nil
    end

    if focus ~= 83
        and focus ~= 84
        and focus ~= 85 then

        return nil
    end

    return focus
end

local function refresh_gog_focus()
    gog_focus_value = get_current_gog_focus()

    if gog_focus_value == nil then
        gog_focus_name = "Not detected"
    else
        gog_focus_name =
            focus_name(gog_focus_value)
    end

    return gog_focus_value
end

local function desired_shell_for_focus(focus)
    if focus == 83 then
        return 0
    elseif focus == 84 then
        -- Affinity Focus retains its stat package but uses Wide.
        return 1
    elseif focus == 85 then
        -- Element Focus retains its stat package but uses Long.
        return 2
    end

    return nil
end

local handling_setup_limit_ammo = nil

local function update_live_shell_detection(
    handling,
    shell_value
)
    if shell_value == nil then
        return
    end

    current_shell_type_value = shell_value
    current_shell_type_path =
        "app.cHunterWp07Handling._ShellType"
    shell_type_detected = true

    if shell_value == long_shell_type_value then
        current_shell_type_name = "LONG"
        detector_status =
            "Long shelling detected from live handling"
    else
        current_shell_type_name =
            "Not Long (" ..
            tostring(shell_value) ..
            ")"

        detector_status =
            "Non-Long shelling detected from live handling"
    end
end

local function apply_shell_to_handling(handling)
    if handling == nil then
        return false
    end

    -- Always read the live handling shell type. Previously this state was
    -- refreshed only for Gog weapons, so switching from Gog to a non-Gog
    -- Gunlance could leave the old Long/Normal/Wide result cached.
    local current =
        normalize_enum_value(
            safe_get_field(
                handling,
                "_ShellType"
            )
        )

    if current == nil then
        combat_shell_status =
            "Could not read _ShellType"

        return false
    end

    update_live_shell_detection(
        handling,
        current
    )

    local focus = refresh_gog_focus()

    if focus == nil then
        combat_shell_status =
            "Live non-Gog shell type: " ..
            tostring(current)

        return true
    end

    local desired =
        desired_shell_for_focus(focus)

    if current == desired then
        combat_shell_status =
            "Already correct (" ..
            tostring(current) ..
            ")"

        update_live_shell_detection(
            handling,
            desired
        )

        return true
    end

    if not safe_set_field(
        handling,
        "_ShellType",
        desired
    ) then
        combat_shell_status =
            "Could not write _ShellType"

        return false
    end

    combat_shell_writes =
        combat_shell_writes + 1

    update_live_shell_detection(
        handling,
        desired
    )

    -- Ammo capacity is initialized separately from _ShellType.
    -- Rebuild it once whenever the focus forces a new shell type.
    if handling_setup_limit_ammo ~= nil then
        local ok = pcall(function()
            handling_setup_limit_ammo:call(
                handling,
                true
            )
        end)

        if ok then
            ammo_rebuilds = ammo_rebuilds + 1
        end
    end

    combat_shell_status =
        tostring(current) ..
        " -> " ..
        tostring(desired)

    log.info(
        "[WP07 Long Shelling] Live Gog shell type " ..
        combat_shell_status ..
        " for " ..
        focus_name(focus)
    )

    return true
end

local function install_handling_hook()
    local handling_type =
        sdk.find_type_definition(
            "app.cHunterWp07Handling"
        )

    if handling_type == nil then
        return false,
            "app.cHunterWp07Handling not found"
    end

    local do_update =
        handling_type:get_method(
            "doUpdate",
            0
        )

    if do_update == nil then
        do_update =
            handling_type:get_method(
                "doUpdate"
            )
    end

    if do_update == nil then
        return false,
            "cHunterWp07Handling.doUpdate not found"
    end

    handling_setup_limit_ammo =
        handling_type:get_method(
            "setupLimitAmmo",
            1
        )

    local ok, hook_error = pcall(function()
        sdk.hook(
            do_update,

            function(args)
                handling_update_calls =
                    handling_update_calls + 1

                local handling =
                    safe_to_managed_object(
                        args[2]
                    )

                if handling ~= nil then
                    apply_shell_to_handling(
                        handling
                    )
                end
            end,

            function(retval)
                return retval
            end
        )
    end)

    if not ok then
        return false, tostring(hook_error)
    end

    handling_hook_installed = true
    return true, nil
end

------------------------------------------------------------
-- SHELL-TYPE REFRESH
------------------------------------------------------------

local function refresh_shell_type()
    shell_type_detected = false
    current_shell_type_value = nil
    current_shell_type_path = nil
    current_shell_type_name = "Unknown"

    if long_shell_type_value == nil then
        long_shell_type_value =
            find_long_enum_value()
    end

    if long_shell_type_value == nil then
        detector_status =
            "Could not resolve LONG enum constant"

        log.error(
            "[WP07 Long Shelling] " ..
            detector_status
        )

        return
    end

    local player, player_path =
        get_master_player()

    if player == nil then
        detector_status =
            "Active player unavailable: " ..
            tostring(player_path)

        return
    end

    local result =
        find_shell_type_in_object_graph(player)

    if result == nil then
        detector_status =
            "No equipped SHELL_TYPE field found"

        log.info(
            "[WP07 Long Shelling] " ..
            detector_status
        )

        return
    end

    shell_type_detected = true
    current_shell_type_value = result.value
    current_shell_type_path = result.path

    if current_shell_type_value
        == long_shell_type_value then

        current_shell_type_name = "LONG"

        detector_status =
            "Long shelling detected"
    else
        current_shell_type_name =
            "Not Long (" ..
            tostring(current_shell_type_value) ..
            ")"

        detector_status =
            "Non-Long shelling detected"
    end

    log.info(
        "[WP07 Long Shelling] " ..
        detector_status ..
        " | value=" ..
        tostring(current_shell_type_value) ..
        " | LONG=" ..
        tostring(long_shell_type_value) ..
        " | path=" ..
        tostring(current_shell_type_path)
    )
end

local function is_long_shelling()
    local focus = refresh_gog_focus()

    if focus == 85 then
        return true
    elseif focus == 84 or focus == 83 then
        return false
    end

    return
        shell_type_detected
        and long_shell_type_value ~= nil
        and current_shell_type_value
            == long_shell_type_value
end

------------------------------------------------------------
-- WEAPON ATTRIBUTE CLASSIFICATION
------------------------------------------------------------

local function get_current_weapon_work()
    local equip_util =
        sdk.find_type_definition("app.EquipUtil")

    if equip_util == nil then
        return nil
    end

    local method =
        equip_util:get_method(
            "getEquipWorkWeapon",
            1
        )

    if method == nil then
        return nil
    end

    local ok, work = pcall(function()
        return method:call(nil, 0)
    end)

    if not ok or work == nil then
        return nil
    end

    return safe_to_managed_object(work) or work
end

local function get_current_weapon_data()
    local equip_util =
        sdk.find_type_definition(
            "app.EquipUtil"
        )

    if equip_util == nil then
        return nil
    end

    local methods = nil

    pcall(function()
        methods = equip_util:get_methods()
    end)

    if methods == nil then
        return nil
    end

    for _, method in ipairs(methods) do
        local method_name = nil
        local parameter_count = nil

        pcall(function()
            method_name = method:get_name()
        end)

        pcall(function()
            parameter_count =
                method:get_num_params()
        end)

        if parameter_count == nil then
            pcall(function()
                local parameters =
                    method:get_params()

                if parameters ~= nil then
                    parameter_count = #parameters
                end
            end)
        end

        if method_name ==
            "getEquipCurrentWeaponData"
            and tonumber(parameter_count) == 1 then

            local ok, result = pcall(function()
                return method:call(nil, 0)
            end)

            result =
                safe_to_managed_object(result)
                or result

            if ok and result ~= nil then
                return result
            end
        end
    end

    return nil
end

local function get_weapon_data_attribute_value()
    local weapon_data =
        get_current_weapon_data()

    if weapon_data == nil then
        return nil
    end

    local weapon_type =
        normalize_enum_value(
            safe_get_field(
                weapon_data,
                "_Type"
            )
        )

    if weapon_type ~= 7 then
        return nil
    end

    local attribute =
        safe_get_field(
            weapon_data,
            "_Attribute"
        )

    local attribute_value =
        normalize_enum_value(attribute)

    if attribute_value == nil then
        attribute_value =
            tonumber(
                safe_get_field(
                    attribute,
                    "_Value"
                )
            )
    end

    return attribute_value
end

local function classify_non_gog_weapon_data_attribute()
    if not is_long_shelling() then
        return nil
    end

    if refresh_gog_focus() ~= nil then
        return nil
    end

    local attribute_value =
        get_weapon_data_attribute_value()

    if attribute_value == nil then
        return nil
    end

    element_detector_source =
        "WeaponData._Attribute._Value"

    element_detector_path =
        "WeaponData._Attribute._Value"

    element_detector_value =
        attribute_value

    current_attribute_id =
        attribute_value

    if attribute_value == 0 then
        current_attribute_name = "RAW/OTHER"
        current_attribute_class = "RAW_OR_OTHER"
        element_detector_status =
            "RAW/OTHER WeaponData attribute [0]"
        return "RAW_OR_OTHER"
    end

    if attribute_value >= 1
        and attribute_value <= 5 then

        local element_name =
            WEAPON_DATA_ELEMENT_NAMES[attribute_value]
            or ("ELEMENT[" .. tostring(attribute_value) .. "]")

        current_attribute_name = element_name
        current_attribute_class = "TRUE_ELEMENT"
        element_detector_status =
            "TRUE ELEMENT " .. tostring(element_name) ..
            " [" .. tostring(attribute_value) .. "] via WeaponData"
        return "TRUE_ELEMENT"
    end

    current_attribute_name =
        "STATUS[" .. tostring(attribute_value) .. "]"
    current_attribute_class = "STATUS"
    element_detector_status =
        "STATUS [" .. tostring(attribute_value) .. "] via WeaponData"
    return "STATUS"
end

local function classify_weapon_attribute()
    local work = get_current_weapon_work()

    current_attribute_id = nil
    current_attribute_name = "UNKNOWN"
    current_attribute_class = "UNKNOWN"
    element_detector_source = "Unknown"

    qualifying_elemental_long = false
    qualifying_status_long = false

    if work == nil then
        element_detector_status =
            "Weapon work unavailable"

        return "UNKNOWN"
    end

    local attribute_id =
        tonumber(
            safe_get_field(
                work,
                "FreeVal2"
            )
        )

    current_attribute_id = attribute_id
    element_detector_path = "FreeVal2"
    element_detector_value = attribute_id
    element_detector_source = "cEquipWork.FreeVal2"

    if attribute_id == nil then
        element_detector_status =
            "FreeVal2 unavailable"

        return "UNKNOWN"
    end

    local element_name =
        TRUE_ELEMENT_FREEVAL2[
            attribute_id
        ]

    if element_name ~= nil then
        current_attribute_name =
            element_name

        current_attribute_class =
            "TRUE_ELEMENT"

        element_detector_status =
            "TRUE ELEMENT " ..
            element_name ..
            " [" ..
            tostring(attribute_id) ..
            "]"

        return "TRUE_ELEMENT"
    end

    local status_name =
        STATUS_FREEVAL2[
            attribute_id
        ]

    if status_name ~= nil then
        current_attribute_name =
            status_name

        current_attribute_class =
            "STATUS"

        element_detector_status =
            "STATUS " ..
            status_name ..
            " [" ..
            tostring(attribute_id) ..
            "]"

        return "STATUS"
    end

    local fallback_class =
        classify_non_gog_weapon_data_attribute()

    if fallback_class ~= nil then
        return fallback_class
    end

    current_attribute_name =
        "RAW/OTHER"

    current_attribute_class =
        "RAW_OR_OTHER"

    element_detector_status =
        "RAW/OTHER FreeVal2 [" ..
        tostring(attribute_id) ..
        "]"

    return "RAW_OR_OTHER"
end

local function refresh_qualifying_weapon()
    local long = is_long_shelling()
    local class = classify_weapon_attribute()

    qualifying_elemental_long =
        long and class == "TRUE_ELEMENT"

    qualifying_status_long =
        long and class == "STATUS"

    return qualifying_elemental_long
end

------------------------------------------------------------
-- ACTION CLASSIFICATION
------------------------------------------------------------

local function current_action_context()
    if frame <= action_state.wyvern_fire_until then
        return "WYVERN_FIRE"
    end

    if frame <= action_state.fullburst_until
        and action_state.active_fullburst ~= "NONE" then

        return action_state.active_fullburst
    end

    if frame <= action_state.charged_until then
        return "CHARGED"
    end

    return "UNCHARGED"
end

local function install_action_hooks()
    local handling_type =
        sdk.find_type_definition(
            "app.cHunterWp07Handling"
        )

    if handling_type == nil then
        return false,
            "app.cHunterWp07Handling not found"
    end

    hook_pre(
        handling_type,
        "requestChargeShot",
        1,
        function()
            action_state.charged_until =
                frame + 90
        end
    )

    hook_pre(
        handling_type,
        "setupChargeShotProcess",
        0,
        function()
            action_state.charged_until =
                frame + 90
        end
    )

    hook_pre(
        handling_type,
        "requestFullBurst",
        0,
        function()
            action_state.pending_fullburst =
                "FULLBURST"
        end
    )

    hook_pre(
        handling_type,
        "requestJumpFullBurst",
        0,
        function()
            action_state.pending_fullburst =
                "FULLBURST"
        end
    )

    hook_pre(
        handling_type,
        "requestBulletFire",
        0,
        function()
            action_state.pending_fullburst =
                "BF_FULLBURST"
        end
    )

    hook_pre(
        handling_type,
        "requestBulletFireReload",
        0,
        function()
            action_state.pending_fullburst =
                "RBF_FULLBURST"
        end
    )

    hook_pre(
        handling_type,
        "setupFullBurst",
        1,
        function()
            if action_state.pending_fullburst ==
                "NONE" then

                action_state.active_fullburst =
                    "FULLBURST"
            else
                action_state.active_fullburst =
                    action_state.pending_fullburst
            end

            action_state.pending_fullburst = "NONE"
            action_state.fullburst_until =
                frame + 120
        end
    )

    hook_pre(
        handling_type,
        "updateFullBurst",
        0,
        function()
            action_state.fullburst_until =
                frame + 12
        end
    )

    hook_pre(
        handling_type,
        "cancelFullBurst",
        0,
        function()
            action_state.pending_fullburst = "NONE"
            action_state.active_fullburst = "NONE"
            action_state.fullburst_until = -1
        end
    )

    hook_pre(
        handling_type,
        "shootRyuugekiShell",
        0,
        function()
            action_state.wyvern_fire_until =
                frame + 60
        end
    )

    return true, nil
end

------------------------------------------------------------
-- ARTILLERY VALUE OVERRIDE
------------------------------------------------------------

local function query_artillery_level()
    if hunter_skill == nil then
        current_artillery_level = 0
        return 0
    end

    local ok, result =
        call_method(
            hunter_skill,
            "getSkillLevel",
            ARTILLERY_SKILL_ID,
            true,
            false
        )

    if not ok or result == nil then
        current_artillery_level = 0
        return 0
    end

    current_artillery_level =
        math.max(
            0,
            math.min(
                3,
                tonumber(result) or 0
            )
        )

    return current_artillery_level
end

local function capture_artillery_data()
    if hunter_skill == nil then
        artillery_last_error =
            "No live cHunterSkill captured"

        return false
    end

    local raw_skill_array =
        safe_get_field(
            hunter_skill,
            "_CurrentSkillInfoDic"
        )

    local skill_array =
        safe_to_managed_object(
            raw_skill_array
        ) or raw_skill_array

    local entry =
        array_get(
            skill_array,
            ARTILLERY_SKILL_ID
        )

    if entry == nil then
        artillery_last_error =
            "Artillery entry absent; equip Artillery 1-3"

        return false
    end

    local raw_skill_data =
        safe_get_field(
            entry,
            "_SkillData"
        )

    local skill_data =
        safe_to_managed_object(
            raw_skill_data
        ) or raw_skill_data

    if skill_data == nil then
        artillery_last_error =
            "Artillery _SkillData unavailable"

        return false
    end

    local raw_level_data_list =
        safe_get_field(
            skill_data,
            "_SkillLevelDataList"
        )

    artillery_level_data_list =
        safe_to_managed_object(
            raw_level_data_list
        ) or raw_level_data_list

    if artillery_level_data_list == nil then
        artillery_last_error =
            "Artillery level-data list unavailable"

        return false
    end

    artillery_last_error = "Artillery data captured"
    return true
end

local function get_artillery_value_array(level_index)
    local level_data =
        array_get(
            artillery_level_data_list,
            level_index
        )

    if level_data == nil then
        return nil
    end

    local raw_values =
        safe_get_field(
            level_data,
            "_value"
        )

    return safe_to_managed_object(
        raw_values
    ) or raw_values
end

local function zero_artillery_values()
    artillery_retry_count =
        artillery_retry_count + 1

    if not capture_artillery_data() then
        return false
    end

    for level_index = 0, 2 do
        local values =
            get_artillery_value_array(
                level_index
            )

        if not array_set(
            values,
            ARTILLERY_RAW_VALUE_INDEX,
            0
        ) then
            artillery_last_error =
                "Failed to zero raw value at level " ..
                tostring(level_index + 1)

            return false
        end

        if not array_set(
            values,
            ARTILLERY_FIRE_VALUE_INDEX,
            0
        ) then
            artillery_last_error =
                "Failed to zero fixed-fire value at level " ..
                tostring(level_index + 1)

            return false
        end
    end

    artillery_values_zeroed = true
    artillery_last_error =
        "Artillery raw and fixed-fire values zeroed"

    if refresh_artillery_live_values ~= nil then
        refresh_artillery_live_values()
    end

    log.info(
        "[WP07 Long Shelling] " ..
        "Artillery raw and fixed-fire values zeroed"
    )

    return true
end

local function restore_artillery_values()
    if not capture_artillery_data() then
        artillery_last_error =
            "Could not capture Artillery data for canonical restore"

        return false
    end

    for level_index = 0, 2 do
        local values =
            get_artillery_value_array(
                level_index
            )

        if values == nil then
            artillery_last_error =
                "Restore: _value array unavailable at level " ..
                tostring(level_index + 1)

            return false
        end

        if not array_set(
            values,
            ARTILLERY_RAW_VALUE_INDEX,
            ARTILLERY_RAW_CANONICAL[level_index]
        ) then
            artillery_last_error =
                "Restore raw failed at level " ..
                tostring(level_index + 1)

            return false
        end

        if not array_set(
            values,
            ARTILLERY_FIRE_VALUE_INDEX,
            ARTILLERY_FIRE_CANONICAL[level_index]
        ) then
            artillery_last_error =
                "Restore fixed fire failed at level " ..
                tostring(level_index + 1)

            return false
        end
    end

    artillery_values_zeroed = false
    artillery_last_error =
        "Canonical Artillery values restored"

    if refresh_artillery_live_values ~= nil then
        refresh_artillery_live_values()
    end

    log.info(
        "[WP07 Long Shelling] " ..
        "Canonical Artillery values restored"
    )

    return true
end

refresh_artillery_live_values = function()
    if not capture_artillery_data() then
        artillery_live_values = "Unavailable"
        return
    end

    local parts = {}

    for level_index = 0, 2 do
        local values =
            get_artillery_value_array(
                level_index
            )

        if values == nil then
            table.insert(
                parts,
                "L" ..
                tostring(level_index + 1) ..
                "=?"
            )
        else
            table.insert(
                parts,
                "L" ..
                tostring(level_index + 1) ..
                "={" ..
                tostring(
                    array_get(
                        values,
                        ARTILLERY_RAW_VALUE_INDEX
                    )
                ) ..
                "," ..
                tostring(
                    array_get(
                        values,
                        ARTILLERY_FIRE_VALUE_INDEX
                    )
                ) ..
                "}"
            )
        end
    end

    artillery_live_values =
        table.concat(parts, " ")
end

local function update_artillery_override()
    query_artillery_level()

    local qualifying =
        refresh_qualifying_weapon()

    -- Always enforce the desired global SkillData state.
    -- Do not trust artillery_values_zeroed, because an older script or a
    -- prior failed restore may have left the shared values at zero.
    if qualifying then
        zero_artillery_values()
    else
        local restored =
            restore_artillery_values()

        if not restored then
            artillery_last_error =
                "Non-elemental weapon equipped, canonical restore failed"
        end
    end
end

local function install_skill_capture_hook()
    local skill_type =
        sdk.find_type_definition(
            "app.cHunterSkill"
        )

    if skill_type == nil then
        return false,
            "app.cHunterSkill not found"
    end

    local method =
        skill_type:get_method(
            "checkSkillActive(app.HunterDef.Skill)"
        )

    if method == nil then
        return false,
            "checkSkillActive exact method not found"
    end

    sdk.hook(
        method,

        function(args)
            hunter_skill =
                safe_to_managed_object(
                    args[2]
                ) or args[2]
        end,

        function(retval)
            return retval
        end
    )

    return true, nil
end

------------------------------------------------------------
-- CONDITIONAL LONG USER3 RAW-RATE OVERRIDE
------------------------------------------------------------

local function get_player_catalog_holder()
    local player_manager =
        sdk.get_managed_singleton(
            "app.PlayerManager"
        )

    if player_manager == nil then
        return nil
    end

    local method_names = {
        "get_PlData",
        "getPlData",
    }

    for _, method_name in ipairs(method_names) do
        local ok, result =
            call_method(
                player_manager,
                method_name
            )

        result =
            safe_to_managed_object(result) or result

        if ok and result ~= nil then
            return result
        end
    end

    local field_names = {
        "_Catalog",
        "_PlData",
    }

    for _, field_name in ipairs(field_names) do
        local result =
            safe_get_field(
                player_manager,
                field_name
            )

        result =
            safe_to_managed_object(result) or result

        if result ~= nil then
            return result
        end
    end

    return nil
end

local function get_long_shell_type_info()
    local holder =
        get_player_catalog_holder()

    if holder == nil then
        long_user3_rate_status =
            "Player catalog holder unavailable"

        return nil
    end

    local action_param = nil

    local method_names = {
        "get_Wp07ActionParam",
        "getWp07ActionParam",
        "get_Wp07ActionParam443780",
        "getWp07ActionParam443780",
    }

    for _, method_name in ipairs(method_names) do
        local ok, result =
            call_method(
                holder,
                method_name
            )

        result =
            safe_to_managed_object(result) or result

        if ok and result ~= nil then
            action_param = result
            break
        end
    end

    if action_param == nil then
        local field_names = {
            "_Wp07ActionParam",
            "Wp07ActionParam",
        }

        for _, field_name in ipairs(field_names) do
            local result =
                safe_get_field(
                    holder,
                    field_name
                )

            result =
                safe_to_managed_object(result) or result

            if result ~= nil then
                action_param = result
                break
            end
        end
    end

    if action_param == nil then
        long_user3_rate_status =
            "Wp07ActionParam unavailable"

        return nil
    end

    local info =
        safe_get_field(
            action_param,
            "_LongShellTypeInfo"
        )

    info =
        safe_to_managed_object(info) or info

    if info == nil then
        long_user3_rate_status =
            "_LongShellTypeInfo unavailable"

        return nil
    end

    return info
end

local function inspect_long_user3_rates()
    local info =
        get_long_shell_type_info()

    if info == nil then
        return false
    end

    long_charge_live =
        safe_get_field(
            info,
            "_ChargeShot_AttackRate"
        )

    long_fullburst_live =
        safe_get_field(
            info,
            "_FullBurst_AttackRate"
        )

    long_bf_live =
        safe_get_field(
            info,
            "_FullBurst_BF_AttackRate"
        )

    long_rbf_live =
        safe_get_field(
            info,
            "_FullBurst_RBF_AttackRate"
        )

    return true
end

local function set_long_user3_rates(
    charge_rate,
    fullburst_rate,
    bf_rate,
    rbf_rate
)
    local info =
        get_long_shell_type_info()

    if info == nil then
        return false
    end

    local writes = {
        {
            "_ChargeShot_AttackRate",
            charge_rate,
        },
        {
            "_FullBurst_AttackRate",
            fullburst_rate,
        },
        {
            "_FullBurst_BF_AttackRate",
            bf_rate,
        },
        {
            "_FullBurst_RBF_AttackRate",
            rbf_rate,
        },
    }

    for _, entry in ipairs(writes) do
        if not safe_set_field(
            info,
            entry[1],
            entry[2]
        ) then
            long_user3_rate_status =
                "Failed writing " ..
                tostring(entry[1])

            return false
        end
    end

    inspect_long_user3_rates()
    return true
end

local function neutralize_long_user3_rates()
    if set_long_user3_rates(
        1.0,
        1.0,
        1.0,
        1.0
    ) then
        long_user3_rates_neutralized = true
        long_user3_rate_status =
            "Elemental Long rates set to 1.0"

        return true
    end

    return false
end

local function restore_long_user3_rates()
    if set_long_user3_rates(
        LONG_CHARGE_CANONICAL,
        LONG_FULLBURST_CANONICAL,
        LONG_BF_CANONICAL,
        LONG_RBF_CANONICAL
    ) then
        long_user3_rates_neutralized = false
        long_user3_rate_status =
            "Canonical Long rates restored"

        return true
    end

    return false
end

local function update_long_user3_rate_override()
    refresh_qualifying_weapon()

    if qualifying_elemental_long then
        if not long_user3_rates_neutralized then
            neutralize_long_user3_rates()
        end
    else
        -- Restore for status/raw/non-Long weapons. This also repairs values
        -- left at 1.0 by an older script in the current game process.
        restore_long_user3_rates()
    end
end

------------------------------------------------------------
-- ELEMENTAL RATE CALCULATION
------------------------------------------------------------

local function get_artillery_element_multiplier()
    local level =
        query_artillery_level()

    local multiplier =
        ARTILLERY_ELEMENT_MULTIPLIER[level]
        or 1.0

    current_artillery_element_multiplier =
        multiplier

    return multiplier
end

local function get_action_element_multiplier()
    local context =
        current_action_context()

    last_action_context = context

    local multiplier =
        ELEMENT_ACTION_MULTIPLIER[context]
        or 1.0

    current_element_action_multiplier =
        multiplier

    return multiplier
end

local function get_effective_element_rate()
    local rate =
        ELEMENT_RATE
        * get_artillery_element_multiplier()
        * get_action_element_multiplier()

    current_effective_element_rate = rate

    return rate
end

------------------------------------------------------------
-- SHELL ELEMENT/STATUS OVERRIDE
------------------------------------------------------------

local function is_wyrmstake_tick(source, request)
    -- The runtime request provides the cleanest distinction:
    --   ordinary shell collision index = 2
    --   Wyrmstake insertion          = 15
    --   Wyrmstake ticking hit        = 16
    local collision_data =
        safe_get_field(
            request,
            "_CollisionDataID"
        )

    collision_data =
        safe_to_managed_object(
            collision_data
        ) or collision_data

    local collision_index =
        tonumber(
            safe_get_field(
                collision_data,
                "_Index"
            )
        )

    if collision_index == 16 then
        return true
    end

    -- Defensive fallback confirmed by the captured tick source.
    -- Requiring all three values avoids relying on the broad Pile timing
    -- window and prevents ordinary shells fired during an active stake
    -- from being reduced to the Wyrmstake rate.
    local hit_effect =
        normalize_enum_value(
            safe_get_field(
                source,
                "_HitEffectTypeFixed"
            )
        )

    local parts_break_rate =
        tonumber(
            safe_get_field(
                source,
                "_PartsBreakRate"
            )
        )

    local friend_damage_type =
        normalize_enum_value(
            safe_get_field(
                source,
                "_FriendDamageTypeFixed"
            )
        )

    return
        hit_effect == 1
        and approximately_equal(
            parts_break_rate,
            0.3
        )
        and friend_damage_type == 55
end

local function apply_long_shell_override(source, request)
    if source == nil then
        return
    end

    refresh_qualifying_weapon()
    update_artillery_override()

    if not is_long_shelling() then
        return
    end

    local is_sensor =
        safe_get_field(source, "_IsSensor")

    if is_sensor == true then
        return
    end

    -- True-element Long:
    --   * Artillery raw + fixed-fire values are zeroed globally.
    --   * Artillery is reapplied as an elemental multiplier.
    --   * Action-specific elemental multipliers are applied.
    --   * Raw motion values and raw action multipliers are untouched.
    --   * Weapon element is enabled on shells.
    --
    -- Status Long:
    --   * Artillery remains untouched.
    --   * Fixed shell fire remains.
    --   * Status buildup is enabled on shells.
    --
    -- Raw/other Long:
    --   * Left unchanged.
    if not qualifying_elemental_long
        and not qualifying_status_long then

        return
    end

    local changed = false

    local old_enabled =
        safe_get_field(
            source,
            "_UseStatusAttrPower"
        )

    local old_element_rate =
        safe_get_field(
            source,
            "_StatusAttrRate"
        )

    local old_status_rate =
        safe_get_field(
            source,
            "_StatusConditionRate"
        )

    if old_enabled ~= true then
        if safe_set_field(
            source,
            "_UseStatusAttrPower",
            true
        ) then
            changed = true
        end
    end

    if qualifying_elemental_long then
        local wyrmstake_tick =
            is_wyrmstake_tick(
                source,
                request
            )

        local desired_element_rate = nil

        if wyrmstake_tick then
            desired_element_rate =
                WYRMSTAKE_ELEMENT_RATE

            last_shell_param_kind =
                "WYRMSTAKE_TICK"
        else
            desired_element_rate =
                get_effective_element_rate()

            last_shell_param_kind =
                current_action_context()
        end

        if not approximately_equal(
            old_element_rate,
            desired_element_rate
        ) then
            if safe_set_field(
                source,
                "_StatusAttrRate",
                desired_element_rate
            ) then
                changed = true
            end
        end
    end

    if qualifying_status_long then
        if not approximately_equal(
            old_status_rate,
            STATUS_RATE
        ) then
            if safe_set_field(
                source,
                "_StatusConditionRate",
                STATUS_RATE
            ) then
                changed = true
            end
        end
    end

    if changed then
        modified_calls = modified_calls + 1
    end
end

------------------------------------------------------------
-- INSTALL HOOK
------------------------------------------------------------

local shell_param_type =
    sdk.find_type_definition(SHELL_PARAM_TYPE)

if shell_param_type == nil then
    error_message =
        "Could not find type: " ..
        SHELL_PARAM_TYPE
else
    local method =
        shell_param_type:get_method(
            "createRuntimeAttackParam(" ..
            "app.cRequestSetAttackParamRuntimeData)"
        )

    if method == nil then
        method = shell_param_type:get_method(
            SHELL_PARAM_METHOD
        )
    end

    if method == nil then
        error_message =
            "Could not find shell runtime method"
    else
        local ok, hook_error = pcall(function()
            sdk.hook(
                method,

                function(args)
                    runtime_calls =
                        runtime_calls + 1

                    local source =
                        safe_to_managed_object(
                            args[2]
                        )

                    local request =
                        safe_to_managed_object(
                            args[3]
                        )

                    apply_long_shell_override(
                        source,
                        request
                    )
                end,

                function(retval)
                    return retval
                end
            )
        end)

        if ok then
            hook_installed = true

            log.info(
                "[WP07 Long Shelling] " ..
                "Hook installed."
            )
        else
            error_message =
                tostring(hook_error)
        end
    end
end

------------------------------------------------------------
-- LIVE HANDLING HOOK + INITIAL DETECTION
------------------------------------------------------------

do
    local ok, hook_error =
        install_handling_hook()

    if not ok then
        error_message =
            tostring(hook_error)

        log.error(
            "[WP07 Long Shelling] " ..
            tostring(hook_error)
        )
    end
end

do
    local ok, hook_error =
        install_action_hooks()

    if not ok then
        error_message =
            tostring(hook_error)

        log.error(
            "[WP07 Long Shelling] " ..
            tostring(hook_error)
        )
    end
end

do
    local ok, hook_error =
        install_skill_capture_hook()

    if not ok then
        error_message =
            tostring(hook_error)

        log.error(
            "[WP07 Long Shelling] " ..
            tostring(hook_error)
        )
    end
end

refresh_gog_focus()
refresh_shell_type()
refresh_qualifying_weapon()
inspect_long_user3_rates()
update_long_user3_rate_override()

re.on_frame(function()
    frame = frame + 1

    if frame > action_state.fullburst_until then
        action_state.active_fullburst = "NONE"
    end

    -- Keep the global Artillery data matched to the currently
    -- qualifying weapon in case the equipment changes.
    if frame % 10 == 0 then
        update_artillery_override()
        update_long_user3_rate_override()
    end
end)

------------------------------------------------------------
-- UI
------------------------------------------------------------

re.on_draw_ui(function()
    if not imgui.tree_node(
        "WP07 Long Attribute Shelling v13" ..
        "##wp07_long_elemental_shelling"
    ) then
        return
    end

    local overall_status = "Ready"

    if error_message ~= nil then
        overall_status = "Error"
    elseif not hook_installed then
        overall_status = "Shell hook unavailable"
    elseif not shell_type_detected then
        overall_status = "Weapon detection unavailable"
    end

    imgui.text(
        "Status: " ..
        tostring(overall_status)
    )

    imgui.text(
        "Shell type: " ..
        tostring(current_shell_type_name)
    )

    imgui.text(
        "Attribute: " ..
        tostring(current_attribute_name)
    )

    local active_mode = "None"

    if qualifying_elemental_long then
        active_mode = "Elemental Long"
    elseif qualifying_status_long then
        active_mode = "Status Long"
    elseif is_long_shelling() then
        active_mode = "Raw Long"
    end

    imgui.text(
        "Active mode: " ..
        tostring(active_mode)
    )

    if qualifying_elemental_long then
        imgui.text(
            "Element rate: " ..
            tostring(current_effective_element_rate)
        )

        imgui.text(
            "Artillery level: " ..
            tostring(query_artillery_level())
        )

        imgui.text(
            "User3 raw rates neutralized: " ..
            tostring(long_user3_rates_neutralized)
        )
    elseif qualifying_status_long then
        imgui.text(
            "Status rate: " ..
            tostring(STATUS_RATE)
        )

        imgui.text(
            "User3 raw rates preserved: " ..
            tostring(
                not long_user3_rates_neutralized
            )
        )
    end

    if gog_focus_value ~= nil then
        imgui.text(
            "Gog focus: " ..
            tostring(gog_focus_name)
        )
    end

    if error_message ~= nil then
        imgui.text(
            "Error: " ..
            tostring(error_message)
        )
    end

    if imgui.button(
        "Refresh weapon##wp07_refresh_shell"
    ) then
        refresh_shell_type()
        refresh_qualifying_weapon()
        update_artillery_override()
        update_long_user3_rate_override()
        inspect_long_user3_rates()
    end

    if imgui.tree_node(
        "Diagnostics##wp07_diagnostics"
    ) then
        imgui.text(
            "Detector: " ..
            tostring(detector_status)
        )

        imgui.text(
            "Attribute detector: " ..
            tostring(element_detector_status)
        )

        imgui.text(
            "Attribute source: " ..
            tostring(element_detector_source)
        )

        imgui.text(
            "Artillery state: " ..
            tostring(artillery_last_error)
        )

        imgui.text(
            "User3 state: " ..
            tostring(long_user3_rate_status)
        )

        imgui.text(
            "User3 C/FB/BF/RBF: " ..
            tostring(long_charge_live) ..
            " / " ..
            tostring(long_fullburst_live) ..
            " / " ..
            tostring(long_bf_live) ..
            " / " ..
            tostring(long_rbf_live)
        )

        imgui.text(
            "Action context: " ..
            tostring(current_action_context())
        )

        imgui.text(
            "Last shell parameter: " ..
            tostring(last_shell_param_kind)
        )

        imgui.text(
            "Runtime calls: " ..
            tostring(runtime_calls)
        )

        imgui.text(
            "Modified calls: " ..
            tostring(modified_calls)
        )

        imgui.text(
            "Combat shell state: " ..
            tostring(combat_shell_status)
        )

        if current_shell_type_path ~= nil then
            imgui.text(
                "Detection path: " ..
                tostring(current_shell_type_path)
            )
        end

        if imgui.button(
            "Refresh diagnostics##wp07_refresh_diagnostics"
        ) then
            refresh_artillery_live_values()
            inspect_long_user3_rates()
        end

        imgui.tree_pop()
    end

    imgui.tree_pop()
end)