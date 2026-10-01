-- v2_gl_override_v2_4.lua
--
-- Gunlance melee baseline overrides used alongside the elemental shelling mod
-- and Heat Blade.
--
-- Runtime baseline changes:
--   Lateral Thrust: 24 MV -> 30 MV
--   Guard Thrust:   18 MV -> 24 MV
--   Wide Sweep:     40 MV -> 57 MV
--
-- Element-rate changes retained from the original override:
--   Lateral Thrust -> 2.0
--   Guard Thrust   -> 2.0
--   Wide Sweep     -> 2.0
--
-- V2.4 IMPORTANT CHANGE:
--   The source AttackParamPl object is NO LONGER permanently rewritten.
--   The override is applied only while createRuntimeAttackParam is executing,
--   then the source is restored in the post-hook.
--
--   This removes the 24-MV ambiguity that caused an already-overridden Guard
--   Thrust (24 MV) to be mistaken for vanilla Lateral Thrust (also 24 MV).
--   Between runtime calls the real source records remain vanilla:
--       Guard 18 / Lateral 24 / Wide 40.
--
-- Heat Blade compatibility:
--   Heat Blade may temporarily add +4/+8 to the same source before this hook.
--   V2.4 recognizes vanilla+Heat values and preserves that bonus when building
--   the temporary runtime baseline. The post-hook is also tolerant of either
--   hook's post callback running first.
--
-- NOTE:
--   Because older versions permanently changed source records, do ONE full game
--   restart when replacing an older persistent-write override with V2.4. Reset Scripts alone may leave the
--   old 24/30/57 source values alive for the current process.
--
-- V2.4 reentrancy fix:
--   createRuntimeAttackParam can re-enter for the same AttackParamPl source while
--   an outer temporary baseline is still present. Active sources are locked so
--   nested calls reuse that temporary baseline instead of re-identifying Guard as
--   Lateral (or otherwise applying the baseline twice).

local TYPE_NAME = "app.col_user_data.AttackParamPl"
local METHOD_NAME = "createRuntimeAttackParam"
local GUNLANCE_TYPE = 7
local ENABLE_OVERRIDES = true

local HEAT_OFFSETS = { 0.0, 4.0, 8.0 }

local MOVES = {
    {
        id = "lateral_thrust",
        name = "Lateral Thrust",
        original_attack = 24.0,
        new_attack = 30.0,
        new_ele = 2.0,
    },
    {
        id = "guard_thrust",
        name = "Guard Thrust",
        original_attack = 18.0,
        new_attack = 24.0,
        new_ele = 2.0,
    },
    {
        id = "wide_sweep",
        name = "Wide Sweep",
        original_attack = 40.0,
        new_attack = 57.0,
        new_ele = 2.0,
        requires_status_condition_15 = true,
    },
}

local installed = false
local error_message = nil
local total_calls = 0
local gunlance_calls = 0
local recognized_calls = 0
local writes = 0
local restores = 0
local stack = {}
local active_sources = {}
local nested_reuses = 0

local application_counts = {}
for _, move in ipairs(MOVES) do
    application_counts[move.id] = 0
end

local last_attack_id = nil -- diagnostic only
local last_move_name = "<none>"
local last_attack_before = nil
local last_attack_runtime = nil
local last_attack_after_restore = nil
local last_ele_before = nil
local last_ele_runtime = nil
local last_bonus = nil
local last_detection = "<none>"
local last_restore_mode = "<none>"

local function safe_to_managed_object(value)
    if value == nil then return nil end
    local ok, object = pcall(function()
        return sdk.to_managed_object(value)
    end)
    if ok and object ~= nil then return object end
    return value
end

local function safe_get_field(object, field_name)
    if object == nil then return nil end
    local ok, value = pcall(function()
        return object:get_field(field_name)
    end)
    if ok then return value end
    return nil
end

local function safe_set_field(object, field_name, value)
    if object == nil or value == nil then return false end
    return pcall(function()
        object:set_field(field_name, value)
    end)
end

local function safe_address(object)
    object = safe_to_managed_object(object)
    if object == nil then return nil end
    local ok, address = pcall(function()
        return object:get_address()
    end)
    if ok and address ~= nil then return tostring(address) end
    return nil
end

local function to_number(value)
    if value == nil then return nil end
    if type(value) == "number" then return value end

    local direct = tonumber(tostring(value))
    if direct ~= nil then return direct end

    local object = safe_to_managed_object(value)
    if object == nil then return nil end

    for _, field_name in ipairs({ "value__", "_Value", "value", "mValue" }) do
        local n = tonumber(tostring(safe_get_field(object, field_name)))
        if n ~= nil then return n end
    end

    return nil
end

local function approximately_equal(a, b)
    a = to_number(a)
    b = to_number(b)
    return a ~= nil and b ~= nil and math.abs(a - b) < 0.001
end

local get_weapon_work_method = nil
local tried_get_weapon_work_method = false

local function resolve_get_weapon_work_method()
    if tried_get_weapon_work_method then
        return get_weapon_work_method
    end

    tried_get_weapon_work_method = true

    local td = sdk.find_type_definition("app.EquipUtil")
    if td == nil then return nil end

    local methods = nil
    pcall(function() methods = td:get_methods() end)
    if methods == nil then return nil end

    for _, method in ipairs(methods) do
        local name, count = nil, nil
        pcall(function() name = method:get_name() end)
        pcall(function() count = method:get_num_params() end)

        if count == nil then
            pcall(function()
                local params = method:get_parameters()
                count = params and #params or 0
            end)
        end

        if tostring(name) == "getEquipWorkWeapon"
            and tonumber(count) == 1 then
            get_weapon_work_method = method
            return method
        end
    end

    return nil
end

local function is_gunlance_equipped()
    local method = resolve_get_weapon_work_method()
    if method == nil then return false end

    local ok, work = pcall(function()
        return method:call(nil, 0)
    end)

    work = safe_to_managed_object(work)
    if not ok or work == nil then return false end

    local free0 = to_number(safe_get_field(work, "FreeVal0"))
    return free0 ~= nil and math.floor(free0) == GUNLANCE_TYPE
end

local function is_valid_melee_record(source)
    local is_sensor = safe_get_field(source, "_IsSensor")
    local fix_attack = to_number(safe_get_field(source, "_FixAttack"))
    local attr_value = to_number(safe_get_field(source, "_AttrValue"))
    local break_rate = to_number(safe_get_field(source, "_PartsBreakRate"))

    return is_sensor == false
        and fix_attack ~= nil and math.abs(fix_attack) < 0.001
        and attr_value ~= nil and math.abs(attr_value) < 0.001
        and break_rate ~= nil and math.abs(break_rate - 1.0) < 0.001
end

local function get_heat_bridge_context(source)
    local bridge = rawget(_G, "__HB_MELEE_RUNTIME_BRIDGE")
    if bridge == nil or bridge.active_by_source == nil then
        return nil
    end

    local address = safe_address(source)
    if address == nil then return nil end

    return bridge.active_by_source[address]
end

local function match_original_plus_heat(original_attack, attack)
    for _, bonus in ipairs(HEAT_OFFSETS) do
        if approximately_equal(attack, original_attack + bonus) then
            return bonus
        end
    end
    return nil
end

local function identify_move(source)
    local live_attack = to_number(safe_get_field(source, "_Attack"))
    if live_attack == nil then return nil, nil, nil end

    local status_cond = to_number(
        safe_get_field(source, "_StatusConditionRate")
    )

    -- If Heat Blade ran before us, it publishes the exact value it saw before
    -- adding its temporary +4/+8. Prefer that value because it is maximally
    -- unambiguous.
    local bridge = get_heat_bridge_context(source)
    local identity_attack = live_attack
    local bridge_bonus = nil

    if bridge ~= nil then
        local original = to_number(bridge.original_attack)
        local heat_bonus = to_number(bridge.heat_bonus)

        if original ~= nil then
            identity_attack = original
        end
        if heat_bonus ~= nil then
            bridge_bonus = heat_bonus
        end
    end

    -- Guard first: vanilla 18, or 18+4/8 if Heat Blade ran first without the
    -- bridge being visible for some reason.
    local guard = MOVES[2]
    local guard_bonus = match_original_plus_heat(
        guard.original_attack,
        live_attack
    )

    if approximately_equal(identity_attack, guard.original_attack) then
        return guard, bridge_bonus or 0.0,
            bridge ~= nil and "guard via Heat bridge" or "guard vanilla"
    elseif bridge == nil and guard_bonus ~= nil then
        return guard, guard_bonus, "guard vanilla+Heat"
    end

    -- Lateral remains unambiguous because V2.3 restores Guard to 18 after every
    -- runtime request instead of leaving it parked at 24.
    local lateral = MOVES[1]
    local lateral_bonus = match_original_plus_heat(
        lateral.original_attack,
        live_attack
    )

    if approximately_equal(identity_attack, lateral.original_attack) then
        return lateral, bridge_bonus or 0.0,
            bridge ~= nil and "lateral via Heat bridge" or "lateral vanilla"
    elseif bridge == nil and lateral_bonus ~= nil then
        return lateral, lateral_bonus, "lateral vanilla+Heat"
    end

    -- Wide Sweep uses its stable StatusConditionRate=1.5 signature in addition
    -- to 40 MV, so another 40-MV record cannot be accidentally rewritten.
    local wide = MOVES[3]
    local wide_bonus = match_original_plus_heat(
        wide.original_attack,
        live_attack
    )

    local wide_signature =
        status_cond ~= nil
        and approximately_equal(status_cond, 1.5)

    if wide_signature
        and approximately_equal(identity_attack, wide.original_attack) then
        return wide, bridge_bonus or 0.0,
            bridge ~= nil and "wide via Heat bridge" or "wide signature"
    elseif bridge == nil
        and wide_signature
        and wide_bonus ~= nil then
        return wide, wide_bonus, "wide signature+Heat"
    end

    return nil, nil, nil
end

local function is_known_heat_delta(value)
    if value == nil then return false end
    local a = math.abs(value)
    return approximately_equal(a, 4.0)
        or approximately_equal(a, 8.0)
end

local function pre_hook(args)
    total_calls = total_calls + 1

    local context = {
        source = nil,
        restore_attack = nil,
        restore_ele = nil,
        temporary_attack = nil,
        temporary_ele = nil,
        move = nil,
        bonus = 0.0,
        active_key = nil,
        active_token = nil,
        nested_reuse = false,
    }
    table.insert(stack, context)

    if not ENABLE_OVERRIDES then return end

    local source = safe_to_managed_object(args[2])
    local request_data = safe_to_managed_object(args[3])

    if source == nil
        or not is_valid_melee_record(source)
        or not is_gunlance_equipped() then
        return
    end

    gunlance_calls = gunlance_calls + 1

    -- Runtime attack creation can re-enter for the same source before our outer
    -- post-hook restores the vanilla MV. Do not classify the temporary 24/30/57
    -- value again; simply let the nested runtime request reuse it.
    local source_key = safe_address(source)
    if source_key ~= nil
        and active_sources[source_key] ~= nil then

        local active = active_sources[source_key]
        nested_reuses = nested_reuses + 1
        context.nested_reuse = true

        last_move_name = active.move_name or "<nested>"
        last_attack_before = to_number(safe_get_field(source, "_Attack"))
        last_attack_runtime = last_attack_before
        last_attack_after_restore = last_attack_before
        last_bonus = active.bonus or 0.0
        last_detection = "nested reuse"
        last_restore_mode = "nested reuse"
        return
    end

    local move, preserved_bonus, detection = identify_move(source)
    if move == nil then return end

    recognized_calls = recognized_calls + 1
    preserved_bonus = preserved_bonus or 0.0

    local old_attack = to_number(safe_get_field(source, "_Attack"))
    local old_ele = to_number(safe_get_field(source, "_StatusAttrRate"))

    if old_attack == nil then return end

    local target_attack = move.new_attack + preserved_bonus
    local target_ele = move.new_ele

    context.source = source
    context.restore_attack = old_attack
    context.restore_ele = old_ele
    context.temporary_attack = target_attack
    context.temporary_ele = target_ele
    context.move = move
    context.bonus = preserved_bonus

    if source_key ~= nil then
        local active_token = {}
        active_sources[source_key] = {
            token = active_token,
            move_name = move.name,
            bonus = preserved_bonus,
            target_attack = target_attack,
        }
        context.active_key = source_key
        context.active_token = active_token
    end

    local changed = false

    if not approximately_equal(old_attack, target_attack) then
        if safe_set_field(source, "_Attack", target_attack) then
            changed = true
        end
    end

    if target_ele ~= nil
        and not approximately_equal(old_ele, target_ele) then
        if safe_set_field(source, "_StatusAttrRate", target_ele) then
            changed = true
        end
    end

    if changed then
        writes = writes + 1
        application_counts[move.id] =
            (application_counts[move.id] or 0) + 1
    end

    local attack_id = nil
    if request_data ~= nil then
        attack_id = to_number(
            safe_get_field(request_data, "_AttackUniqueID")
        )
        if attack_id ~= nil then
            attack_id = math.floor(attack_id)
        end
    end

    last_attack_id = attack_id
    last_move_name = move.name
    last_attack_before = old_attack
    last_attack_runtime = target_attack
    last_ele_before = old_ele
    last_ele_runtime = target_ele
    last_bonus = preserved_bonus
    last_detection = detection or "<unknown>"
end

local function post_hook(retval)
    local context = table.remove(stack)

    if context == nil
        or context.source == nil
        or context.restore_attack == nil then
        return retval
    end

    local source = context.source
    local current_attack = to_number(safe_get_field(source, "_Attack"))

    -- Usually current_attack == our temporary target. If Heat Blade's other
    -- post-hook has already run (or has not run yet), the current value can be
    -- target +/- 4/8. Carry that transient delta back onto our original value so
    -- the other hook can remove its own layer cleanly.
    local restore_attack = context.restore_attack
    local restore_mode = "exact"

    if current_attack ~= nil
        and context.temporary_attack ~= nil then

        local delta = current_attack - context.temporary_attack

        if is_known_heat_delta(delta) then
            restore_attack = context.restore_attack + delta
            restore_mode = "preserve Heat delta " .. tostring(delta)
        elseif not approximately_equal(current_attack, context.temporary_attack) then
            -- Unknown third-party change: prefer the exact source value we saw
            -- before V2.3 touched it rather than making a speculative adjustment.
            restore_mode = "fallback exact"
        end
    end

    safe_set_field(source, "_Attack", restore_attack)

    if context.restore_ele ~= nil then
        safe_set_field(source, "_StatusAttrRate", context.restore_ele)
    end

    if context.active_key ~= nil then
        local active = active_sources[context.active_key]
        if active ~= nil
            and active.token == context.active_token then
            active_sources[context.active_key] = nil
        end
    end

    restores = restores + 1
    last_attack_after_restore = restore_attack
    last_restore_mode = restore_mode

    return retval
end

local type_definition = sdk.find_type_definition(TYPE_NAME)
if type_definition == nil then
    error_message = "Could not find type: " .. TYPE_NAME
else
    local method = type_definition:get_method(METHOD_NAME)

    if method == nil then
        method = type_definition:get_method(
            "createRuntimeAttackParam(app.cRequestSetAttackParamRuntimeData)"
        )
    end

    if method == nil then
        error_message =
            "Could not find method: " .. TYPE_NAME .. "." .. METHOD_NAME
    else
        local ok, hook_error = pcall(function()
            sdk.hook(method, pre_hook, post_hook)
        end)

        if ok then
            installed = true
            log.info(
                "[WP07 Override V2.4] Reentrant-safe temporary runtime override installed."
            )
        else
            error_message = tostring(hook_error)
        end
    end
end

re.on_draw_ui(function()
    if not imgui.tree_node(
        "WP07 Melee Override V2.4##wp07_melee_override_v24"
    ) then
        return
    end

    imgui.text("Hook installed: " .. tostring(installed))
    imgui.text("Overrides enabled: " .. tostring(ENABLE_OVERRIDES))
    imgui.text("Runtime calls: " .. tostring(total_calls))
    imgui.text("Gunlance melee calls: " .. tostring(gunlance_calls))
    imgui.text("Recognized calls: " .. tostring(recognized_calls))
    imgui.text("Temporary writes: " .. tostring(writes))
    imgui.text("Restores: " .. tostring(restores))
    imgui.text("Nested source reuses: " .. tostring(nested_reuses))

    if error_message ~= nil then
        imgui.text("Error: " .. tostring(error_message))
    end

    imgui.separator()
    imgui.text("V2.4 uses reentrant-safe temporary runtime writes; source MVs stay vanilla.")
    imgui.text("Do one FULL game restart after replacing an older persistent-write override.")

    imgui.separator()
    imgui.text("Last move: " .. tostring(last_move_name))
    imgui.text("Last AttackUniqueID (diagnostic): " .. tostring(last_attack_id))
    imgui.text("Detection: " .. tostring(last_detection))
    imgui.text(
        "Attack source -> runtime -> restored: "
        .. tostring(last_attack_before)
        .. " -> " .. tostring(last_attack_runtime)
        .. " -> " .. tostring(last_attack_after_restore)
    )
    imgui.text(
        "Element source -> runtime: "
        .. tostring(last_ele_before)
        .. " -> " .. tostring(last_ele_runtime)
    )
    imgui.text("Preserved Heat bonus: " .. tostring(last_bonus))
    imgui.text("Restore mode: " .. tostring(last_restore_mode))

    imgui.separator()
    for index, move in ipairs(MOVES) do
        if imgui.tree_node(
            move.name .. "##wp07_v23_move_" .. tostring(index)
        ) then
            imgui.text("Vanilla MV: " .. tostring(move.original_attack))
            imgui.text("Runtime base MV: " .. tostring(move.new_attack))
            imgui.text("Runtime element rate: " .. tostring(move.new_ele))
            imgui.text(
                "Applications: " .. tostring(application_counts[move.id] or 0)
            )
            imgui.tree_pop()
        end
    end

    imgui.tree_pop()
end)
