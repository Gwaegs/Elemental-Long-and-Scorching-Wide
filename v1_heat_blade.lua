-- mhws_heat_blade_v2c_direct_razor_test.lua
--
-- HEAT BLADE V6.5 RELEASE - PASSIVE HEAT + ACTIVATED SCORCHER RIDER
--
-- V3.9:
--   * Keeps V3.8's live cHunterWp07Handling._ShellType Wide detection.
--   * Fixes synthetic Scorcher provenance across Wide Gunlance swaps.
--
-- V3.8 bug:
--   Synthetic carrier ownership was stored against a fingerprint containing
--   the WEAPON identity. When switching from a Gog Wide to a non-Gog Wide
--   with the SAME armor, the armor-side synthetic Scorcher was no longer
--   recognized as synthetic because only the weapon key changed.
--
--   Result:
--       stale synthetic Scorcher -> miscounted as 2 genuine pieces
--       carrierNeeded = 0
--       next rebuild removes the old carrier
--       Razor Sharp still works, but Heat Blade has no Scorcher machinery
--
-- V3.9:
--   Synthetic carrier ownership uses an ARMOR-ONLY fingerprint:
--       final armor source + ordinary-skill signatures
--   It deliberately excludes weapon identity.
--
--   Therefore:
--       Wide A + no Scorcher armor -> synthetic carrier
--       switch to Wide B, same armor -> still recognized as synthetic
--       -> carrier is rebuilt for Wide B
--
--   Changing armor changes the armor fingerprint, so genuine Scorcher armor
--   is still allowed to replace the previous carrier provenance.
--
-- Built from the stable V2A/V2B no-injection Heat Blade path.
--
-- IMPORTANT:
--   V3.3 keeps the stable V2C direct Razor Sharp implementation.
--   V3.3 adds Scorcher only through native calcTotalSkill armor-source inputs.
--   It never directly writes _CurrentSkillInfoDic or _NextSkillInfo.
--   Genuine Scorcher pieces are counted separately from synthetic carriers.
--
-- V6 Heat behavior:
--   PASSIVE Heat controls Razor Sharp + lance MV at all times while Wide is equipped.
--   Before Wyvern Fire, PASSIVE Heat is current WHITE.
--   During an active Wyvern Fire snapshot, PASSIVE Heat is max(WHITE, BLACK), so
--   firing Wyvern Fire never erases the lance/Razor bonuses:
--     YELLOW 0-43:  Razor Sharp Lv1, +0 lance MV
--     ORANGE 44-86: Razor Sharp Lv2, +4 lance MV
--     RED 87-129:   Razor Sharp Lv3, +8 lance MV
--
--   WYVERN FIRE snapshots White into BLACK/BLUE and spends White to 0.
--   Only the hijacked Scorcher rider requires this activation:
--     YELLOW snapshot: no Heat Blade damage rider
--     ORANGE snapshot: 8 raw MV @ assumed HZV 50, +20 element
--     RED snapshot:   16 raw MV @ assumed HZV 50, +40 element
--
--   Blue expiry disables only the activated Scorcher rider. When BLACK is removed,
--   passive Razor Sharp / lance-MV immediately fall back to current WHITE Heat.
--
-- V6.4 runtime-MV fix:
--   createRuntimeAttackParam can re-enter on the same AttackParamPl source before
--   an outer temporary +4/+8 write has been restored. V6.4 locks each active
--   source so nested calls reuse the already-adjusted MV instead of adding Heat
--   a second time.
--
-- V6.5 release cleanup:
--   * Routine diagnostics are kept in the dedicated Heat Blade log file but are
--     no longer mirrored into REFramework's ScriptRunner log.
--   * The REFramework UI is read-only: no gauge-time, gauge-position, reset,
--     forced-proc, carrier-rescan, or other development/tuning controls.
--   * Gameplay behavior is otherwise unchanged from V6.4.
--
-- Direct Razor Sharp route:
--   app.cHunterWeaponHandlingBase.consumeKireajiFromAttack
--
-- Probe result:
--   Normal melee consumption:
--       _RequestedConsumeKireaji 0 -> 10
--       return value 10
--       then cWeaponKireaji.consumeKireaji runs
--
--   Native Razor Sharp successful proc:
--       _RequestedConsumeKireaji stays 0
--       return value 0
--       cWeaponKireaji.consumeKireaji does not follow
--
-- V2C reproduces that successful-proc state in the POST hook:
--   1) Let the native function run first.
--   2) Only for the local player's WeaponHandling.
--   3) If the native result wants to consume sharpness and Heat Blade procs:
--       - set _RequestedConsumeKireaji = 0
--       - return 0
--
-- This test intentionally DOES NOT alter direct consumeKireaji(...) calls
-- that bypass consumeKireajiFromAttack. We will verify melee first.
--
-- Razor Sharp equivalent rates used here:
--   Lv1 = 10%
--   Lv2 = 25%
--   Lv3 = 50%
--
-- If genuine Razor Sharp is equipped, V2C does not simply stack a second
-- full proc chance. It applies only the additional conditional chance needed
-- to reach max(real Razor Sharp level, Heat Blade granted level).
--
-- Raw Heat Blade rider:
--   raw * expectedCrit * MV * assumedRawHZV * liveRawSharpnessMultiplier
--
-- Live sharpness path:
--   HunterCharacter
--     -> get_WeaponHandling()
--     -> get_Kireaji()
--     -> get_CurrentType()
--
-- Sharpness enum:
--   0 Red
--   1 Orange
--   2 Yellow
--   3 Green
--   4 Blue
--   5 White
--   6 Purple
--
-- TEST PROCEDURE:
--   1) Disable ALL older Heat Blade / Scorcher / Razor Sharp test scripts.
--   2) FULL game restart.
--   3) Equip the intended Wide Gunlance and your normal armor.
--   4) Land one melee hit and open the V3 UI.
--   5) V3 auto-scans genuine Scorcher on weapon + armor and plans carriers.
--   6) If "carrier needed" is above 0, switch weapon away and back ONCE.
--   7) Confirm "carrier ready=true", then compare OFF/YELLOW/ORANGE/RED.
--   8) For the cleanest Razor test, equip no native Razor Sharp.
--
-- A "Force next eligible protection" button is included so the hook can be
-- validated deterministically before relying on random proc rates.
--
-- Log:
--   reframework/data/mhws_heat_blade_v2c_direct_razor_test.log

------------------------------------------------------------
-- CONFIG
------------------------------------------------------------
local LOG_PATH =
    "reframework/data/mhws_heat_blade_v6_5_release.log"

local HUNTER_SKILL_TYPE =
    "app.cHunterSkill"

local HUNTER_HANDLING_TYPE =
    "app.cHunterWeaponHandlingBase"

local CRIT_BOOST_ID =
    3

local WEAKNESS_EXPLOIT_ID =
    63

local RAZOR_SHARP_ID =
    16

local SCORCHER_ID =
    191

-- Proven native equipment-source layout:
--   source 0 = weapon contribution
--   sources 1..5 = armor-piece contributions
local ARMOR_SOURCE_MIN =
    1

local ARMOR_SOURCE_MAX =
    5

local WEAPON_SOURCE =
    0

local GUNLANCE_TYPE =
    7

local SHELL_NORMAL =
    0

local SHELL_WIDE =
    1

local SHELL_LONG =
    2

-- Balance choice:
-- use 33% of native Scorcher proc damage as the per-hit expected-value
-- compensation.
local SCORCHER_AVERAGE_RATE =
    0.33

-- Current native Scorcher proc payloads.
local SCORCHER_1_FIXED =
    20.0

local SCORCHER_1_FIRE =
    60.0

local SCORCHER_2_FIXED =
    40.0

local SCORCHER_2_FIRE =
    120.0

-- Native armor calcTotalSkill inputs observed so far have seven slots.
-- Carrier selection prefers pieces with an unused slot.
local ARMOR_SKILL_SLOT_LIMIT =
    7

local RAZOR_SHARP_CHANCE = {
    [0] = 0.00,
    [1] = 0.10,
    [2] = 0.25,
    [3] = 0.50,
}

local ASSUMED_RAW_HZV =
    0.50

local ORANGE_MV =
    0.08

local RED_MV =
    0.16

local ORANGE_ELEMENT =
    20.0

local RED_ELEMENT =
    40.0

local WEX_AFFINITY = {
    [0] = 0,
    [1] = 8,
    [2] = 15,
    [3] = 25,
    [4] = 35,
    [5] = 50,
}

local STAT_REFRESH_FRAMES =
    15

------------------------------------------------------------
-- HEAT STATE
------------------------------------------------------------

local HEAT_OFF = 0
local HEAT_YELLOW = 1
local HEAT_ORANGE = 2
local HEAT_RED = 3

local heat_state =
    HEAT_OFF

------------------------------------------------------------
-- V6.2 PASSIVE HEAT LANCE MV BONUS
------------------------------------------------------------

-- Permanent Gunlance base-MV changes belong to v2_gl_override_v2_1.lua.
-- Heat Blade only adds its passive +4 Orange / +8 Red MV bonus here.
-- AttackUniqueID is diagnostic only because probe testing showed that it shifts
-- between sessions. Stake Thrust is excluded by its stable AttackParamPl field
-- signature. Shells use AttackParamPlShell and never pass through this hook.
HB_MELEE = {
    type_name = "app.col_user_data.AttackParamPl",
    method_name = "createRuntimeAttackParam",

    -- AttackUniqueID is retained only as a diagnostic value. Testing showed
    -- that these IDs shift between game sessions, so V6.4 never uses them
    -- to decide whether an attack receives the Heat Blade MV bonus.
    hook_installed = false,
    calls = 0,
    writes = 0,
    stack = {},
    active_sources = {},
    nested_reuses = 0,
    last_id = nil,
    last_before = nil,
    last_after = nil,
    last_runtime_attack = nil,
    last_bonus = 0.0,
    last_stake_excluded = false,
    last_error = nil,
}

-- Cross-script bridge for v2_gl_override. If Heat Blade's pre-hook runs first,
-- the override can still see the exact source MV from before the temporary
-- +4/+8 write. This removes the 24-MV ambiguity between vanilla Lateral Thrust
-- and the rebalanced Guard Thrust.
_G.__HB_MELEE_RUNTIME_BRIDGE =
    _G.__HB_MELEE_RUNTIME_BRIDGE
    or {
        active_by_source = {},
    }

HB_MELEE.runtime_bridge =
    _G.__HB_MELEE_RUNTIME_BRIDGE

HB_MELEE.heat_bonus =
    function()
        if heat_state == HEAT_RED then
            return 8.0
        end

        if heat_state == HEAT_ORANGE then
            return 4.0
        end

        return 0.0
    end

------------------------------------------------------------
-- SHARPNESS
------------------------------------------------------------

-- app.WeaponDef.KIREAJI_TYPE -> normal raw sharpness modifier.
-- Probe confirmed live get_CurrentType() values 5 -> 4 -> 3 -> 2 -> 1
-- while degrading White -> Blue -> Green -> Yellow -> Orange.
local SHARPNESS = {
    [0] = { name = "Red",    raw = 0.50 },
    [1] = { name = "Orange", raw = 0.75 },
    [2] = { name = "Yellow", raw = 1.00 },
    [3] = { name = "Green",  raw = 1.05 },
    [4] = { name = "Blue",   raw = 1.20 },
    [5] = { name = "White",  raw = 1.32 },
    [6] = { name = "Purple", raw = 1.39 },
}

local cached_sharpness_type =
    nil

local cached_sharpness_name =
    "<none>"

local cached_sharpness_raw =
    nil

local last_logged_sharpness_type =
    nil

------------------------------------------------------------
-- DIRECT RAZOR SHARP STATE
------------------------------------------------------------

local razor_consume_hook_installed =
    false

local razor_consume_stack = {}

local cached_native_razor_level =
    0

local razor_calls_total =
    0

local razor_calls_local =
    0

local razor_original_consumes =
    0

local razor_native_protections =
    0

local razor_heat_protections =
    0

local razor_write_failures =
    0

local last_razor_original_consume =
    nil

local last_razor_requested_before =
    nil

local last_razor_requested_after =
    nil

local last_razor_roll =
    nil

local last_razor_extra_chance =
    nil

local last_razor_real_level =
    nil

local last_razor_target_level =
    nil

local force_next_razor_protection =
    false

-- Private deterministic PRNG so Heat Blade does not disturb Lua's global
-- math.random state used by any other mod.
local RNG_MOD =
    2147483647

local rng_state =
    (
        (os.time() or 1)
        % (RNG_MOD - 1)
    ) + 1

local function next_razor_roll()
    rng_state =
        (
            rng_state
            * 48271
        )
        % RNG_MOD

    return
        rng_state
        / RNG_MOD
end

local function heat_razor_level()
    if heat_state == HEAT_YELLOW then
        return 1
    end

    if heat_state == HEAT_ORANGE then
        return 2
    end

    if heat_state == HEAT_RED then
        return 3
    end

    return 0
end

local function razor_chance_for_level(level)
    local n =
        math.floor(
            tonumber(level)
            or 0
        )

    if n < 0 then
        n = 0
    elseif n > 3 then
        n = 3
    end

    return
        RAZOR_SHARP_CHANCE[n]
        or 0.0
end

local function effective_razor_target_level()
    return
        math.max(
            cached_native_razor_level
            or 0,
            heat_razor_level()
        )
end

local function conditional_extra_razor_chance(
    real_level,
    target_level
)
    local real_chance =
        razor_chance_for_level(
            real_level
        )

    local target_chance =
        razor_chance_for_level(
            target_level
        )

    if target_chance <=
        real_chance then

        return 0.0
    end

    if real_chance >= 1.0 then
        return 0.0
    end

    return
        (
            target_chance
            - real_chance
        )
        /
        (
            1.0
            - real_chance
        )
end

------------------------------------------------------------
-- RUNTIME STATE
------------------------------------------------------------

local frame =
    0

local live_skill =
    nil

local live_hunter =
    nil

local live_handling =
    nil

local live_kireaji =
    nil

local live_handling_addr =
    nil

local live_kireaji_addr =
    nil


local datapack_resolved =
    false

local scorch_index7 =
    nil

local scorch_index8 =
    nil

local original_index7 =
    nil

local original_index8 =
    nil

local hook_write_active =
    false

------------------------------------------------------------
-- V3 SCORCHER CARRIER STATE
------------------------------------------------------------

-- carrier_sources[source] = {
--     signature = sorted non-Scorcher native skills for that armor source,
--     signature_text = "...",
--     matches = N,
--     writes = N,
-- }
local carrier_sources = {}

local carrier_source_indices = {}

local carrier_injection_enabled =
    false

local carrier_ready_for_heat =
    false

local carrier_scan_complete =
    false

local carrier_auto_scan_pending =
    true

local carrier_status =
    "Waiting for live equipment state"

local carrier_needed =
    0

local real_scorcher_piece_count =
    0

local real_scorcher_armor_piece_count =
    0

local real_scorcher_weapon_piece_count =
    0

local scorcher_comp_tier =
    0

local cached_scorcher_comp_fixed =
    0.0

local cached_scorcher_comp_fire =
    0.0

local cached_is_gunlance =
    false

local cached_shell_type =
    nil

local cached_shell_name =
    "<unknown>"

local cached_shell_detection_source =
    "<none>"

local live_handling_shell_reads =
    0

local live_handling_shell_failures =
    0

local cached_is_wide_gunlance =
    false

local cached_weapon_free0 =
    nil

local cached_weapon_free1 =
    nil

local cached_weapon_free2 =
    nil

local cached_weapon_key =
    nil

local planned_wide_weapon_key =
    nil

local shell_observer_installed =
    false

-- shell_type_cache[weapon_key] = { shell = 0/1/2, source = "..." }
-- We populate this for every EquipSet seen by WeaponUtil.getWp07ShellType,
-- whether or not it was already recognized as the current weapon.
local shell_type_cache = {}

local shell_query_calls =
    0

local shell_current_matches =
    0

local last_logged_shell_type =
    nil

local cached_get_weapon_work_method =
    nil

local tried_get_weapon_work_method =
    false

local cached_is_gog_method =
    nil

local tried_is_gog_method =
    false

local carrier_total_matches =
    0

local carrier_total_writes =
    0

local carrier_log_budget =
    40

local carrier_calc_stack = {}

-- The fingerprint describes the CURRENT non-Scorcher equipment skill
-- contributions by final armor source. It prevents stale carrier ownership
-- from one loadout being applied to another loadout that reused source 1/2/etc.
local current_equipment_fingerprint =
    nil

-- Same armor-source signatures as current_equipment_fingerprint, but without
-- the weapon key. Synthetic Scorcher is injected into armor contribution
-- paths, so provenance must survive weapon swaps using the same armor.
local current_armor_fingerprint =
    nil

local carrier_plan_fingerprint =
    nil

-- native_scorcher_confirmations[source] = {
--     fingerprint = "...",
--     signature_text = "...",
-- }
-- Set only when calcTotalSkill presented an already-existing 191 BEFORE
-- Heat Blade attempted a carrier write.
local native_scorcher_confirmations = {}

local carrier_rescan_not_before_frame =
    nil

-- synthetic_carrier_registry[source][signature_text] = armor_fingerprint
-- native_scorcher_registry[source][signature_text] = true
--
-- These survive loadout fingerprints. A stale carrier is only discounted
-- when the SAME final source still has the SAME non-Scorcher signature.
-- A raw native 191 observation overrides the synthetic registry.
local synthetic_carrier_registry = {}
local native_scorcher_registry = {}

local function is_current_synthetic_carrier(
    source,
    signature_text_value
)
    local per_source =
        synthetic_carrier_registry[
            source
        ]

    if per_source == nil then
        return false
    end

    local owner_armor_fingerprint =
        per_source[
            signature_text_value
        ]

    return
        owner_armor_fingerprint ~= nil
        and owner_armor_fingerprint ==
            current_armor_fingerprint
end

-- Latest final non-Scorcher signatures, used to map raw native Scorcher
-- calcTotalSkill inputs even when no carrier is currently planned.
local current_source_signatures_cache = {}

-- Prevent duplicate automatic rebuild requests for the same carrier plan.
local carrier_rebuild_request_key =
    nil

------------------------------------------------------------
-- CACHED LIVE STATS
------------------------------------------------------------

local cached_raw =
    nil

local cached_base_affinity =
    nil

local cached_cb_level =
    0

local cached_wex_level =
    0

local cached_wex_add =
    0

local cached_effective_affinity =
    nil

local cached_crit_mult =
    1.25

local cached_expected_crit =
    1.0

local cached_index7 =
    nil

local cached_index8 =
    nil

local cached_ready =
    false

local last_error =
    nil

------------------------------------------------------------
-- LOGGING
------------------------------------------------------------

local function reset_log()
    local f =
        io.open(
            LOG_PATH,
            "w"
        )

    if f then
        f:write(
            "=== MHWS Heat Blade V6.5 Release - Passive Heat + Activated Scorcher Rider ===\n\n"
        )

        f:close()
    end
end

local function record(label, details)
    local line =
        tostring(label) ..
        " | " ..
        tostring(details or "")

    local f =
        io.open(
            LOG_PATH,
            "a"
        )

    if f then
        f:write(
            line,
            "\n"
        )

        f:close()
    end

    -- Release build: routine diagnostics stay in the dedicated file only.
    -- Mirroring every record() call to ScriptRunner made the public build noisy.
end

------------------------------------------------------------
-- HELPERS
------------------------------------------------------------

local function safe_to_managed(value)
    if value == nil then
        return nil
    end

    local ok, result =
        pcall(
            sdk.to_managed_object,
            value
        )

    if ok and result ~= nil then
        return result
    end

    return nil
end

local function normalize(value)
    if value == nil then
        return nil
    end

    return
        safe_to_managed(value)
        or value
end

local function safe_address(value)
    local obj =
        normalize(
            value
        )

    if obj == nil then
        return nil
    end

    local ok, result =
        pcall(function()
            return obj:get_address()
        end)

    if ok
        and result ~= nil then

        return
            tostring(
                result
            )
    end

    return nil
end

local function safe_call(
    object,
    method_name,
    ...
)
    local obj =
        normalize(
            object
        )

    if obj == nil then
        return nil, false
    end

    local argv = { ... }

    local ok, result =
        pcall(function()
            return obj:call(
                method_name,
                table.unpack(argv)
            )
        end)

    if ok then
        return result, true
    end

    return nil, false
end

local function safe_get_field(
    object,
    field_name
)
    local obj =
        normalize(
            object
        )

    if obj == nil then
        return nil, false
    end

    local ok, result =
        pcall(function()
            return obj:get_field(
                field_name
            )
        end)

    if ok then
        return result, true
    end

    return nil, false
end

local function safe_set_field(
    object,
    field_name,
    value
)
    local obj =
        normalize(
            object
        )

    if obj == nil then
        return false
    end

    local ok =
        pcall(function()
            obj:set_field(
                field_name,
                value
            )
        end)

    return ok
end

local function to_num(value, default)
    local n =
        tonumber(
            tostring(value)
        )

    if n ~= nil then
        return n
    end

    return default
end

local function normalize_enum_value(
    value
)
    if value == nil then
        return nil
    end

    if type(value) ==
        "number" then

        return value
    end

    local direct =
        to_num(
            value,
            nil
        )

    if direct ~= nil then
        return direct
    end

    local obj =
        normalize(
            value
        )

    if obj == nil then
        return nil
    end

    local fields = {
        "value__",
        "_Value",
        "value",
        "mValue",
    }

    for _, field_name in ipairs(
        fields
    ) do

        local field_value =
            select(
                1,
                safe_get_field(
                    obj,
                    field_name
                )
            )

        local number =
            to_num(
                field_value,
                nil
            )

        if number ~= nil then
            return number
        end
    end

    return nil
end

local function clamp(value, lo, hi)
    if value < lo then
        return lo
    end

    if value > hi then
        return hi
    end

    return value
end

local function retval_to_int(retval, default)
    local ok, value =
        pcall(
            sdk.to_int64,
            retval
        )

    if ok then
        local n = tonumber(value)
        if n ~= nil then
            return n
        end
    end

    return to_num(retval, default or 0)
end

------------------------------------------------------------
-- V3 REFLECTION / EQUIPMENT HELPERS
------------------------------------------------------------

local function find_method(
    td,
    wanted_name,
    wanted_params
)
    if td == nil then
        return nil
    end

    local methods =
        nil

    pcall(function()
        methods =
            td:get_methods()
    end)

    if methods == nil then
        return nil
    end

    for _, method in ipairs(methods) do
        local name =
            nil

        local params =
            nil

        pcall(function()
            name =
                method:get_name()
        end)

        pcall(function()
            params =
                method:get_num_params()
        end)

        if params == nil then
            pcall(function()
                local p =
                    method:get_parameters()

                params =
                    p
                    and #p
                    or 0
            end)
        end

        if tostring(name) ==
            wanted_name
        and tonumber(params) ==
            wanted_params then

            return method
        end
    end

    return nil
end

local function get_current_weapon_work()
    if not tried_get_weapon_work_method then
        tried_get_weapon_work_method =
            true

        local td =
            sdk.find_type_definition(
                "app.EquipUtil"
            )

        cached_get_weapon_work_method =
            find_method(
                td,
                "getEquipWorkWeapon",
                1
            )
    end

    if cached_get_weapon_work_method == nil then
        return nil
    end

    local ok, result =
        pcall(function()
            return cached_get_weapon_work_method:call(
                nil,
                0
            )
        end)

    if ok then
        return
            normalize(
                result
            )
    end

    return nil
end

local function make_weapon_key(
    free0,
    free1,
    free2
)
    if free0 == nil
        or free1 == nil
        or free2 == nil then

        return nil
    end

    return
        tostring(free0)
        .. "/"
        .. tostring(free1)
        .. "/"
        .. tostring(free2)
end

local function shell_name(
    value
)
    if value == SHELL_NORMAL then
        return "NORMAL [0]"
    end

    if value == SHELL_WIDE then
        return "WIDE [1]"
    end

    if value == SHELL_LONG then
        return "LONG [2]"
    end

    if value == nil then
        return "<unknown>"
    end

    return
        "OTHER ["
        .. tostring(value)
        .. "]"
end

local function refresh_weapon_gate()
    local work =
        get_current_weapon_work()

    if work == nil then
        cached_is_gunlance =
            false

        cached_weapon_free0 =
            nil

        cached_weapon_free1 =
            nil

        cached_weapon_free2 =
            nil

        cached_weapon_key =
            nil

        cached_shell_type =
            nil

        cached_shell_name =
            "<unknown>"

        cached_shell_detection_source =
            "<none>"

        cached_is_wide_gunlance =
            false

        return
    end

    local free0 =
        math.floor(
            to_num(
                select(
                    1,
                    safe_get_field(
                        work,
                        "FreeVal0"
                    )
                ),
                -1
            )
        )

    local free1 =
        math.floor(
            to_num(
                select(
                    1,
                    safe_get_field(
                        work,
                        "FreeVal1"
                    )
                ),
                -1
            )
        )

    local free2 =
        math.floor(
            to_num(
                select(
                    1,
                    safe_get_field(
                        work,
                        "FreeVal2"
                    )
                ),
                -1
            )
        )

    local new_key =
        make_weapon_key(
            free0,
            free1,
            free2
        )

    local changed =
        new_key ~=
        cached_weapon_key

    cached_weapon_free0 =
        free0

    cached_weapon_free1 =
        free1

    cached_weapon_free2 =
        free2

    cached_weapon_key =
        new_key

    cached_is_gunlance =
        free0 ==
        GUNLANCE_TYPE

    if changed
        and not cached_is_gunlance
        and HB_GAUGE ~= nil
        and HB_GAUGE.reset_for_non_wide ~=
            nil then

        HB_GAUGE.reset_for_non_wide(
            "non-Gunlance equipped"
        )
    end

    if changed then
        local cached_shell =
            shell_type_cache[
                new_key
            ]

        if cached_shell ~= nil then
            cached_shell_type =
                cached_shell.shell

            cached_shell_name =
                shell_name(
                    cached_shell.shell
                )

            cached_shell_detection_source =
                "shell cache: "
                .. tostring(
                    cached_shell.source
                )

            cached_is_wide_gunlance =
                cached_is_gunlance
                and cached_shell.shell ==
                    SHELL_WIDE

            record(
                "SHELL CACHE HIT",
                "weapon="
                .. tostring(
                    new_key
                )
                .. " | "
                .. tostring(
                    cached_shell_name
                )
                .. " | WideEligible="
                .. tostring(
                    cached_is_wide_gunlance
                )
                .. " | cachedSource="
                .. tostring(
                    cached_shell.source
                )
            )

            if cached_is_wide_gunlance then
                carrier_auto_scan_pending =
                    true

                carrier_scan_complete =
                    false

                carrier_ready_for_heat =
                    false

                carrier_status =
                    "Wide Gunlance detected from cached native shell type"
            else
                carrier_ready_for_heat =
                    false

                carrier_status =
                    "Heat Blade disabled: "
                    .. tostring(
                        cached_shell_name
                    )

                if HB_GAUGE ~= nil
                    and HB_GAUGE.reset_for_non_wide ~=
                        nil then

                    HB_GAUGE.reset_for_non_wide(
                        "cached shell type "
                        .. tostring(
                            cached_shell_name
                        )
                    )
                end
            end
        else
            cached_shell_type =
                nil

            cached_shell_name =
                "<waiting for live handling/native query>"

            cached_shell_detection_source =
                "<waiting>"

            cached_is_wide_gunlance =
                false

            if planned_wide_weapon_key ~= nil
                and new_key ~= planned_wide_weapon_key then

                carrier_ready_for_heat =
                    false
            end
        end
    end
end

local function get_is_gog_method()
    if tried_is_gog_method then
        return cached_is_gog_method
    end

    tried_is_gog_method =
        true

    local td =
        sdk.find_type_definition(
            "app.Em0078_ArtianUtil"
        )

    cached_is_gog_method =
        find_method(
            td,
            "isEm0078_ArtianWeapon",
            1
        )

    return cached_is_gog_method
end

local function equip_set_work(
    equip_set
)
    equip_set =
        normalize(
            equip_set
        )

    if equip_set == nil then
        return nil
    end

    local work_info =
        select(
            1,
            safe_call(
                equip_set,
                "get_WorkInfo"
            )
        )

    work_info =
        normalize(
            work_info
        )

    if work_info == nil then
        return nil
    end

    local work =
        select(
            1,
            safe_call(
                work_info,
                "get_Work"
            )
        )

    return
        normalize(
            work
        )
end

local function equip_set_identity(
    equip_set
)
    local work =
        equip_set_work(
            equip_set
        )

    if work == nil then
        return nil
    end

    local free0 =
        math.floor(
            to_num(
                select(
                    1,
                    safe_get_field(
                        work,
                        "FreeVal0"
                    )
                ),
                -999
            )
        )

    local free1 =
        math.floor(
            to_num(
                select(
                    1,
                    safe_get_field(
                        work,
                        "FreeVal1"
                    )
                ),
                -999
            )
        )

    local free2 =
        math.floor(
            to_num(
                select(
                    1,
                    safe_get_field(
                        work,
                        "FreeVal2"
                    )
                ),
                -999
            )
        )

    return {
        free0 =
            free0,

        free1 =
            free1,

        free2 =
            free2,

        key =
            make_weapon_key(
                free0,
                free1,
                free2
            ),
    }
end

local function equip_set_matches_current(
    equip_set
)
    if cached_weapon_key == nil then
        return false, nil
    end

    local identity =
        equip_set_identity(
            equip_set
        )

    if identity == nil then
        return false, nil
    end

    return
        identity.key ==
        cached_weapon_key,
        identity
end

local function effective_gog_shell(
    equip_set,
    free1
)
    local is_gog_method =
        get_is_gog_method()

    if is_gog_method == nil then
        return nil
    end

    local weapon_data =
        select(
            1,
            safe_call(
                equip_set,
                "get_WeaponData"
            )
        )

    weapon_data =
        normalize(
            weapon_data
        )

    if weapon_data == nil then
        return nil
    end

    local ok,
        is_gog =
        pcall(function()
            return is_gog_method:call(
                nil,
                weapon_data
            )
        end)

    if not ok
        or is_gog ~= true then

        return nil
    end

    -- Mirrors the user's gog_manager.lua effective shell mapping:
    --   Attack focus   [83] -> Normal
    --   Affinity focus [84] -> Wide
    --   Element focus  [85] -> Long
    if free1 == 83 then
        return SHELL_NORMAL
    end

    if free1 == 84 then
        return SHELL_WIDE
    end

    if free1 == 85 then
        return SHELL_LONG
    end

    return nil
end

local function apply_current_shell_type(
    shell_type,
    source_label
)
    if shell_type == nil then
        return
    end

    shell_type =
        math.floor(
            to_num(
                shell_type,
                -1
            )
        )

    if shell_type < SHELL_NORMAL
        or shell_type > SHELL_LONG then

        return
    end

    local old_shell =
        cached_shell_type

    cached_shell_type =
        shell_type

    cached_shell_name =
        shell_name(
            shell_type
        )

    cached_shell_detection_source =
        tostring(
            source_label
            or "<unknown>"
        )

    cached_is_wide_gunlance =
        cached_is_gunlance
        and shell_type ==
            SHELL_WIDE

    if cached_weapon_key ~= nil then
        shell_type_cache[
            cached_weapon_key
        ] = {
            shell =
                shell_type,

            source =
                source_label,
        }
    end

    if old_shell ~= shell_type
        or last_logged_shell_type ~= shell_type then

        last_logged_shell_type =
            shell_type

        record(
            "SHELL TYPE",
            "weapon="
            .. tostring(
                cached_weapon_key
            )
            .. " | "
            .. tostring(
                cached_shell_name
            )
            .. " | WideEligible="
            .. tostring(
                cached_is_wide_gunlance
            )
            .. " | source="
            .. tostring(
                source_label
            )
        )
    end

    if cached_is_wide_gunlance then
        if planned_wide_weapon_key ~=
            cached_weapon_key then

            carrier_auto_scan_pending =
                true

            carrier_scan_complete =
                false

            carrier_ready_for_heat =
                false

            carrier_status =
                "Wide Gunlance detected; scanning Scorcher setup"
        end
    else
        carrier_ready_for_heat =
            false

        carrier_status =
            "Heat Blade disabled: "
            .. tostring(
                cached_shell_name
            )

        if HB_GAUGE ~= nil
            and HB_GAUGE.reset_for_non_wide ~=
                nil then

            HB_GAUGE.reset_for_non_wide(
                "shell type "
                .. tostring(
                    cached_shell_name
                )
            )
        end
    end
end

local function install_shell_type_observer()
    local td =
        sdk.find_type_definition(
            "app.WeaponUtil"
        )

    local method =
        find_method(
            td,
            "getWp07ShellType",
            1
        )

    if method == nil then
        record(
            "HOOK SHELL FAILED",
            "WeaponUtil.getWp07ShellType(EquipSet) not found"
        )

        return false
    end

    local ok,
        err =
        pcall(function()
            sdk.hook(
                method,

                function(args)
                    shell_query_calls =
                        shell_query_calls + 1

                    local storage =
                        thread.get_hook_storage()

                    storage.hb_v35_shell_key =
                        nil

                    storage.hb_v35_shell_gog =
                        nil

                    local equip_set =
                        normalize(
                            args[2]
                        )

                    if equip_set == nil then
                        return
                    end

                    local identity =
                        equip_set_identity(
                            equip_set
                        )

                    if identity == nil
                        or identity.key == nil
                        or identity.free0 ~=
                            GUNLANCE_TYPE then

                        return
                    end

                    storage.hb_v35_shell_key =
                        identity.key

                    storage.hb_v35_shell_gog =
                        effective_gog_shell(
                            equip_set,
                            identity.free1
                        )

                    if identity.key ==
                        cached_weapon_key then

                        shell_current_matches =
                            shell_current_matches + 1
                    end
                end,

                function(retval)
                    local storage =
                        thread.get_hook_storage()

                    local weapon_key =
                        storage.hb_v35_shell_key

                    if weapon_key == nil then
                        return retval
                    end

                    local gog_shell =
                        storage.hb_v35_shell_gog

                    local shell_type =
                        nil

                    local source_label =
                        nil

                    if gog_shell ~= nil then
                        shell_type =
                            gog_shell

                        source_label =
                            "Gog focus mapping"
                    else
                        shell_type =
                            to_num(
                                retval,
                                nil
                            )

                        source_label =
                            "WeaponUtil.getWp07ShellType"
                    end

                    if shell_type ~= nil then
                        shell_type =
                            math.floor(
                                shell_type
                            )

                        if shell_type >=
                            SHELL_NORMAL
                        and shell_type <=
                            SHELL_LONG then

                            shell_type_cache[
                                weapon_key
                            ] = {
                                shell =
                                    shell_type,

                                source =
                                    source_label,
                            }

                            -- Apply immediately if this query belongs to the
                            -- currently equipped weapon. Otherwise the cache
                            -- will be consumed by refresh_weapon_gate on swap.
                            if weapon_key ==
                                cached_weapon_key then

                                apply_current_shell_type(
                                    shell_type,
                                    source_label
                                )
                            end
                        end
                    end

                    return retval
                end
            )
        end)

    shell_observer_installed =
        ok

    record(
        ok
        and "HOOKED SHELL"
        or "HOOK SHELL FAILED",
        ok
        and "WeaponUtil.getWp07ShellType(EquipSet) observer/cache"
        or tostring(err)
    )

    return ok
end

local function current_scorcher_compensation()
    if real_scorcher_piece_count >= 4 then
        scorcher_comp_tier =
            2

        return
            SCORCHER_2_FIXED
            * SCORCHER_AVERAGE_RATE,
            SCORCHER_2_FIRE
            * SCORCHER_AVERAGE_RATE
    end

    if real_scorcher_piece_count >= 2 then
        scorcher_comp_tier =
            1

        return
            SCORCHER_1_FIXED
            * SCORCHER_AVERAGE_RATE,
            SCORCHER_1_FIRE
            * SCORCHER_AVERAGE_RATE
    end

    scorcher_comp_tier =
        0

    return 0.0, 0.0
end

------------------------------------------------------------
-- SAFE OUT-OF-HOOK PLAYER ACCESS
------------------------------------------------------------

local function get_master_hunter()
    local manager =
        sdk.get_managed_singleton(
            "app.PlayerManager"
        )

    if manager == nil then
        return nil
    end

    local player,
        ok =
        safe_call(
            manager,
            "getMasterPlayer"
        )

    if not ok
        or player == nil then

        return nil
    end

    local hunter

    hunter,
    ok =
        safe_call(
            player,
            "get_Character"
        )

    if not ok
        or hunter == nil then

        return nil
    end

    return
        normalize(
            hunter
        )
end

local function get_hunter_status(
    hunter
)
    local status,
        ok =
        safe_call(
            hunter,
            "get_HunterStatus"
        )

    if not ok
        or status == nil then

        return nil
    end

    return
        normalize(
            status
        )
end

local function refresh_live_handling_shell_type(
    handling
)
    if not cached_is_gunlance
        or handling == nil then

        return false
    end

    local shell_field,
        ok =
        safe_get_field(
            handling,
            "_ShellType"
        )

    if not ok
        or shell_field == nil then

        live_handling_shell_failures =
            live_handling_shell_failures + 1

        return false
    end

    local shell_type =
        normalize_enum_value(
            shell_field
        )

    if shell_type == nil then
        live_handling_shell_failures =
            live_handling_shell_failures + 1

        return false
    end

    shell_type =
        math.floor(
            shell_type
        )

    if shell_type < SHELL_NORMAL
        or shell_type > SHELL_LONG then

        live_handling_shell_failures =
            live_handling_shell_failures + 1

        return false
    end

    live_handling_shell_reads =
        live_handling_shell_reads + 1

    local changed =
        cached_shell_type ~=
        shell_type
        or cached_shell_detection_source ~=
            "cHunterWp07Handling._ShellType"

    cached_shell_type =
        shell_type

    cached_shell_name =
        shell_name(
            shell_type
        )

    cached_shell_detection_source =
        "cHunterWp07Handling._ShellType"

    cached_is_wide_gunlance =
        shell_type ==
        SHELL_WIDE

    -- Cache the live result too so weapon-switch transitions can use it
    -- immediately before the next handling refresh.
    if cached_weapon_key ~= nil then
        shell_type_cache[
            cached_weapon_key
        ] = {
            shell =
                shell_type,

            source =
                "cHunterWp07Handling._ShellType",
        }
    end

    if changed then
        record(
            "LIVE HANDLING SHELL",
            "weapon="
            .. tostring(
                cached_weapon_key
            )
            .. " | "
            .. tostring(
                cached_shell_name
            )
            .. " | WideEligible="
            .. tostring(
                cached_is_wide_gunlance
            )
        )

        if cached_is_wide_gunlance then
            if planned_wide_weapon_key ~=
                cached_weapon_key then

                carrier_auto_scan_pending =
                    true

                carrier_scan_complete =
                    false

                carrier_ready_for_heat =
                    false

                carrier_status =
                    "Wide Gunlance detected from live handling"
            end
        else
            carrier_ready_for_heat =
                false

            carrier_status =
                "Heat Blade disabled: "
                .. tostring(
                    cached_shell_name
                )

            if HB_GAUGE ~= nil
                and HB_GAUGE.reset_for_non_wide ~=
                    nil then

                HB_GAUGE.reset_for_non_wide(
                    "live shell type "
                    .. tostring(
                        cached_shell_name
                    )
                )
            end
        end
    end

    return true
end

local function get_live_sharpness(
    hunter
)
    if hunter == nil then
        return nil, nil, nil, false
    end

    local handling,
        ok =
        safe_call(
            hunter,
            "get_WeaponHandling"
        )

    if not ok
        or handling == nil then

        return nil, nil, nil, false
    end

    handling =
        normalize(
            handling
        )

    live_handling =
        handling

    live_handling_addr =
        safe_address(
            handling
        )

    -- V3.8 primary shell-type detector. This is the same live field used by
    -- the working non-Gog Long shelling script.
    refresh_live_handling_shell_type(
        handling
    )

    local kireaji

    kireaji,
    ok =
        safe_call(
            handling,
            "get_Kireaji"
        )

    if not ok
        or kireaji == nil then

        return nil, nil, nil, false
    end

    kireaji =
        normalize(
            kireaji
        )

    live_kireaji =
        kireaji

    live_kireaji_addr =
        safe_address(
            kireaji
        )

    local current_type

    current_type,
    ok =
        safe_call(
            kireaji,
            "get_CurrentType"
        )

    if not ok
        or current_type == nil then

        return nil, nil, nil, false
    end

    local sharpness_type =
        math.floor(
            to_num(
                current_type,
                -1
            )
        )

    local entry =
        SHARPNESS[sharpness_type]

    if entry == nil then
        return
            sharpness_type,
            "Unknown(" ..
            tostring(
                sharpness_type
            ) ..
            ")",
            nil,
            false
    end

    return
        sharpness_type,
        entry.name,
        entry.raw,
        true
end

local function get_skill_level(
    skill,
    skill_id
)
    if skill == nil then
        return 0
    end

    local value,
        ok =
        safe_call(
            skill,
            "getSkillLevel",
            skill_id,
            true,
            false
        )

    if not ok then
        return 0
    end

    local level =
        math.floor(
            to_num(
                value,
                0
            )
        )

    return
        clamp(
            level,
            0,
            5
        )
end

local function refresh_cached_stats()
    refresh_weapon_gate()

    local hunter =
        get_master_hunter()

    if hunter == nil then
        cached_ready =
            false

        return
    end

    local status =
        get_hunter_status(
            hunter
        )

    if status == nil then
        cached_ready =
            false

        return
    end

    local attack_power,
        ok =
        safe_call(
            status,
            "get_AttackPower"
        )

    if not ok
        or attack_power == nil then

        cached_ready =
            false

        return
    end

    local critical_rate

    critical_rate,
    ok =
        safe_call(
            status,
            "get_CriticalRate"
        )

    if not ok
        or critical_rate == nil then

        cached_ready =
            false

        return
    end

    local hunter_skill

    hunter_skill,
    ok =
        safe_call(
            status,
            "get_HunterSkill"
        )

    if not ok
        or hunter_skill == nil then

        cached_ready =
            false

        return
    end

    attack_power =
        normalize(
            attack_power
        )

    critical_rate =
        normalize(
            critical_rate
        )

    hunter_skill =
        normalize(
            hunter_skill
        )

    local raw_value,
        raw_ok =
        safe_call(
            attack_power,
            "get_CurrentAttackPower"
        )

    local affinity_value,
        affinity_ok =
        safe_call(
            critical_rate,
            "get_CurrentCriticalRate"
        )

    if not raw_ok
        or not affinity_ok then

        cached_ready =
            false

        return
    end

    local raw =
        to_num(
            raw_value,
            nil
        )

    local base_affinity =
        to_num(
            affinity_value,
            nil
        )

    if raw == nil
        or base_affinity == nil then

        cached_ready =
            false

        return
    end

    local cb_level =
        get_skill_level(
            hunter_skill,
            CRIT_BOOST_ID
        )

    local wex_level =
        get_skill_level(
            hunter_skill,
            WEAKNESS_EXPLOIT_ID
        )

    cached_native_razor_level =
        clamp(
            get_skill_level(
                hunter_skill,
                RAZOR_SHARP_ID
            ),
            0,
            3
        )

    local wex_add =
        WEX_AFFINITY[wex_level]
        or 0

    local effective_affinity =
        clamp(
            base_affinity
            + wex_add,
            -100,
            100
        )

    local positive_crit_mult =
        1.25
        + (0.03 * cb_level)

    local expected_crit

    if effective_affinity >= 0 then
        expected_crit =
            1.0
            +
            (
                effective_affinity
                / 100.0
            )
            *
            (
                positive_crit_mult
                - 1.0
            )
    else
        expected_crit =
            1.0
            +
            (
                math.abs(
                    effective_affinity
                )
                / 100.0
            )
            *
            (0.75 - 1.0)
    end

    -- V6: the Scorcher rider is controlled by BLACK/BLUE activation, not by
    -- current White Heat. White Heat separately controls Razor Sharp and the
    -- direct lance-MV bonus.
    local rider_state =
        HEAT_OFF

    if HB_GAUGE ~= nil
        and HB_GAUGE.activation_active
        and HB_GAUGE.locked_value ~= nil
        and HB_GAUGE.blue_value ~= nil
        and HB_GAUGE.blue_value > 0.0 then

        rider_state =
            HB_GAUGE.state_for_value(
                HB_GAUGE.locked_value
            )
    end

    local mv
    local element

    if rider_state ==
        HEAT_ORANGE then

        mv =
            ORANGE_MV

        element =
            ORANGE_ELEMENT

    elseif rider_state ==
        HEAT_RED then

        mv =
            RED_MV

        element =
            RED_ELEMENT

    else
        mv =
            0

        element =
            0
    end

    cached_raw =
        raw

    cached_base_affinity =
        base_affinity

    cached_cb_level =
        cb_level

    cached_wex_level =
        wex_level

    cached_wex_add =
        wex_add

    cached_effective_affinity =
        effective_affinity

    cached_crit_mult =
        positive_crit_mult

    cached_expected_crit =
        expected_crit

    local sharp_type,
        sharp_name,
        sharp_raw,
        sharp_ok =
        get_live_sharpness(
            hunter
        )

    cached_sharpness_type =
        sharp_type

    cached_sharpness_name =
        sharp_name
        or "<unavailable>"

    cached_sharpness_raw =
        sharp_raw

    if not sharp_ok
        or sharp_raw == nil then

        cached_ready =
            false

        return
    end

    if last_logged_sharpness_type ~=
        sharp_type then

        last_logged_sharpness_type =
            sharp_type

        record(
            "SHARPNESS",
            "type=" ..
            tostring(
                sharp_type
            )
            .. " | " ..
            tostring(
                sharp_name
            )
            .. " | raw x" ..
            tostring(
                sharp_raw
            )
        )
    end

    local scorcher_fixed,
        scorcher_fire =
        current_scorcher_compensation()

    cached_scorcher_comp_fixed =
        scorcher_fixed

    cached_scorcher_comp_fire =
        scorcher_fire

    cached_index7 =
        (
            raw
            * expected_crit
            * mv
            * ASSUMED_RAW_HZV
            * sharp_raw
        )
        + scorcher_fixed

    -- IMPORTANT:
    -- index8 remains elemental. Wilds applies the ACTUAL struck fire HZV.
    -- The assumed 0.50 HZV above applies ONLY to the Heat Blade raw MV.
    cached_index8 =
        element
        + scorcher_fire

    cached_ready =
        true

    live_hunter =
        hunter

    live_skill =
        hunter_skill
end

------------------------------------------------------------
-- ARRAY ITEM HELPER
------------------------------------------------------------

local function get_array_item(
    array,
    index
)
    local value,
        ok =
        safe_call(
            array,
            "get_Item",
            index
        )

    if ok then
        return
            normalize(
                value
            )
    end

    value,
    ok =
        safe_call(
            array,
            "Get",
            index
        )

    if ok then
        return
            normalize(
                value
            )
    end

    return nil
end

------------------------------------------------------------
-- V3 NATIVE SCORCHER CARRIER
------------------------------------------------------------

local function array_length(
    array
)
    local value,
        ok =
        safe_call(
            array,
            "get_Length"
        )

    if ok then
        return
            math.floor(
                to_num(
                    value,
                    -1
                )
            )
    end

    return nil
end

local function list_count(
    list
)
    local value,
        ok =
        safe_call(
            list,
            "get_Count"
        )

    if ok then
        return
            math.floor(
                to_num(
                    value,
                    -1
                )
            )
    end

    return nil
end

local function list_get(
    list,
    index
)
    local value,
        ok =
        safe_call(
            list,
            "get_Item",
            index
        )

    if ok then
        return value
    end

    return nil
end

local function list_set(
    list,
    index,
    value
)
    local _,
        ok =
        safe_call(
            list,
            "set_Item",
            index,
            value
        )

    return ok
end

local function list_numbers(
    list
)
    local count =
        list_count(
            list
        )

    if count == nil
        or count < 0 then

        return nil
    end

    local out = {}

    for i = 0,
        count - 1 do

        out[
            #out + 1
        ] =
            math.floor(
                to_num(
                    list_get(
                        list,
                        i
                    ),
                    0
                )
            )
    end

    return out
end

local function signature_text(
    signature
)
    if signature == nil then
        return "<nil>"
    end

    local out = {}

    for _, item in ipairs(signature) do
        out[
            #out + 1
        ] =
            tostring(
                item.skill
            )
            .. ":"
            .. tostring(
                item.level
            )
    end

    return
        table.concat(
            out,
            ","
        )
end

local function sort_signature(
    signature
)
    table.sort(
        signature,
        function(a, b)
            if a.skill == b.skill then
                return a.level < b.level
            end

            return a.skill < b.skill
        end
    )
end

local function make_armor_fingerprint(
    source_signatures
)
    local parts = {}

    for source = ARMOR_SOURCE_MIN,
        ARMOR_SOURCE_MAX do

        parts[
            #parts + 1
        ] =
            tostring(source)
            .. "=["
            .. signature_text(
                source_signatures[
                    source
                ]
                or {}
            )
            .. "]"
    end

    return
        table.concat(
            parts,
            "|"
        )
end

local function make_equipment_fingerprint(
    source_signatures
)
    return
        "weapon="
        .. tostring(
            cached_weapon_key
            or "<none>"
        )
        .. "|"
        .. make_armor_fingerprint(
            source_signatures
        )
end

local function signatures_equal(
    a,
    b
)
    if a == nil
        or b == nil
        or #a ~= #b then

        return false
    end

    for i = 1, #a do
        if a[i].skill ~= b[i].skill
            or a[i].level ~= b[i].level then

            return false
        end
    end

    return true
end

-- Some final EquipSkillInfo source levels are already aggregated when we
-- inspect _CurrentSkillInfoDic, while calcTotalSkill may receive the same
-- armor piece before that aggregation. V3.1 therefore has a conservative
-- fallback that requires the exact SAME skill-id set even when levels differ.
local function signature_skill_ids_equal(
    a,
    b
)
    if a == nil
        or b == nil
        or #a ~= #b then

        return false
    end

    for i = 1, #a do
        if a[i].skill ~= b[i].skill then
            return false
        end
    end

    return true
end

local function list_contains_skill(
    skills,
    skill_id
)
    local values =
        list_numbers(
            skills
        )

    if values == nil then
        return false
    end

    for _, value in ipairs(values) do
        if value == skill_id then
            return true
        end
    end

    return false
end

local function list_nonzero_signature(
    skills,
    levels
)
    local skill_values =
        list_numbers(
            skills
        )

    local level_values =
        list_numbers(
            levels
        )

    if skill_values == nil
        or level_values == nil then

        return nil
    end

    local count =
        math.min(
            #skill_values,
            #level_values
        )

    local out = {}

    for i = 1, count do
        local skill_id =
            skill_values[i]

        local level =
            level_values[i]

        if skill_id ~= 0
            and skill_id ~= SCORCHER_ID
            and level > 0 then

            out[
                #out + 1
            ] = {
                skill =
                    skill_id,

                level =
                    level,
            }
        end
    end

    sort_signature(
        out
    )

    return out
end

local function first_empty_pair(
    skills,
    levels
)
    local skill_values =
        list_numbers(
            skills
        )

    local level_values =
        list_numbers(
            levels
        )

    if skill_values == nil
        or level_values == nil then

        return nil
    end

    local count =
        math.min(
            #skill_values,
            #level_values
        )

    for i = 1, count do
        if skill_values[i] == 0
            and level_values[i] == 0 then

            return i - 1
        end
    end

    return nil
end

local function read_active_source_level(
    entry,
    source
)
    local active_index =
        select(
            1,
            safe_get_field(
                entry,
                "_ActiveEquipIndex"
            )
        )

    local active_lv =
        select(
            1,
            safe_get_field(
                entry,
                "_ActiveEquipLv"
            )
        )

    if active_index == nil
        or active_lv == nil then

        return false, 0
    end

    local active =
        get_array_item(
            active_index,
            source
        )

    local level =
        math.floor(
            to_num(
                get_array_item(
                    active_lv,
                    source
                ),
                0
            )
        )

    return
        active == true,
        level
end

local function count_table_keys(
    t
)
    local count =
        0

    for _, _ in pairs(t) do
        count =
            count + 1
    end

    return count
end

local function scan_and_plan_scorcher_carrier()
    if live_skill == nil then
        carrier_status =
            "No live HunterSkill yet"

        return false
    end

    local work =
        get_current_weapon_work()

    if work == nil then
        carrier_status =
            "Current weapon work unavailable"

        return false
    end

    refresh_weapon_gate()

    if not cached_is_gunlance then
        carrier_status =
            "Heat Blade disabled: current weapon is not Gunlance"

        return false
    end

    if cached_shell_type == nil then
        carrier_status =
            "Waiting for native Gunlance shell-type query"

        return false
    end

    if not cached_is_wide_gunlance then
        carrier_status =
            "Heat Blade disabled: "
            .. tostring(
                cached_shell_name
            )

        return false
    end

    planned_wide_weapon_key =
        cached_weapon_key

    local current =
        select(
            1,
            safe_get_field(
                live_skill,
                "_CurrentSkillInfoDic"
            )
        )

    local length =
        array_length(
            current
        )

    if current == nil
        or length == nil
        or length <= 0 then

        carrier_status =
            "Current skill array unavailable"

        return false
    end

    --------------------------------------------------------
    -- PASS 1: build CURRENT non-Scorcher armor signatures.
    --
    -- This must happen BEFORE deciding whether a Scorcher source is
    -- synthetic, because synthetic ownership is only valid for the exact
    -- equipment fingerprint that created it.
    --------------------------------------------------------

    local source_signatures = {}

    for source = ARMOR_SOURCE_MIN,
        ARMOR_SOURCE_MAX do

        source_signatures[source] =
            {}
    end

    for i = 0,
        length - 1 do

        local entry =
            get_array_item(
                current,
                i
            )

        if entry ~= nil then
            local skill_id =
                math.floor(
                    to_num(
                        select(
                            1,
                            safe_get_field(
                                entry,
                                "_Skill"
                            )
                        ),
                        -1
                    )
                )

            if skill_id >= 0
                and skill_id ~= SCORCHER_ID then

                for source = ARMOR_SOURCE_MIN,
                    ARMOR_SOURCE_MAX do

                    local active,
                        source_level =
                        read_active_source_level(
                            entry,
                            source
                        )

                    if active
                        and source_level > 0 then

                        source_signatures[source][
                            #source_signatures[source] + 1
                        ] = {
                            skill =
                                skill_id,

                            level =
                                source_level,
                        }
                    end
                end
            end
        end
    end

    for source = ARMOR_SOURCE_MIN,
        ARMOR_SOURCE_MAX do

        sort_signature(
            source_signatures[source]
        )
    end

    current_armor_fingerprint =
        make_armor_fingerprint(
            source_signatures
        )

    current_equipment_fingerprint =
        make_equipment_fingerprint(
            source_signatures
        )

    current_source_signatures_cache =
        source_signatures

    --------------------------------------------------------
    -- PASS 2: classify Scorcher sources as GENUINE vs carrier.
    --------------------------------------------------------

    local genuine_scorcher_sources = {}

    local scorcher_entry =
        get_array_item(
            current,
            SCORCHER_ID
        )

    if scorcher_entry ~= nil then

        -- Weapon contribution was never synthetic in the production carrier,
        -- so source 0 is always genuine when present.
        local weapon_active,
            weapon_level =
            read_active_source_level(
                scorcher_entry,
                WEAPON_SOURCE
            )

        if weapon_active
            and weapon_level > 0 then

            genuine_scorcher_sources[
                WEAPON_SOURCE
            ] =
                true
        end

        for source = ARMOR_SOURCE_MIN,
            ARMOR_SOURCE_MAX do

            local active,
                source_level =
                read_active_source_level(
                    scorcher_entry,
                    source
                )

            if active
                and source_level > 0 then

                local current_signature =
                    source_signatures[
                        source
                    ]

                local current_signature_text =
                    signature_text(
                        current_signature
                    )

                local native_for_source =
                    native_scorcher_registry[
                        source
                    ]

                local synthetic_for_source =
                    synthetic_carrier_registry[
                        source
                    ]

                local raw_native_confirmed =
                    native_for_source ~= nil
                    and native_for_source[
                        current_signature_text
                    ] ==
                        true

                local synthetic_known =
                    synthetic_for_source ~= nil
                    and synthetic_for_source[
                        current_signature_text
                    ] ~= nil
                    and synthetic_for_source[
                        current_signature_text
                    ] ==
                        current_armor_fingerprint

                -- Exact source + ordinary-skill signature + ARMOR
                -- fingerprint determines synthetic ownership. Weapon identity
                -- is intentionally excluded so the carrier survives Wide-to-
                -- Wide weapon swaps with unchanged armor.
                local synthetic =
                    synthetic_known
                    and not raw_native_confirmed

                if not synthetic then
                    genuine_scorcher_sources[
                        source
                    ] =
                        true
                end
            end
        end
    end

    real_scorcher_piece_count =
        0

    real_scorcher_armor_piece_count =
        0

    real_scorcher_weapon_piece_count =
        0

    for source, _ in pairs(
        genuine_scorcher_sources
    ) do

        real_scorcher_piece_count =
            real_scorcher_piece_count + 1

        if source == WEAPON_SOURCE then
            real_scorcher_weapon_piece_count =
                real_scorcher_weapon_piece_count + 1
        elseif source >= ARMOR_SOURCE_MIN
            and source <= ARMOR_SOURCE_MAX then

            real_scorcher_armor_piece_count =
                real_scorcher_armor_piece_count + 1
        end
    end

    -- Genuine weapon + armor Scorcher pieces both count toward the user's
    -- requested 2/4 damage tiers.
    carrier_needed =
        math.max(
            0,
            2
            - real_scorcher_piece_count
        )

    -- Native activation fallback: our experiments proved two distinct armor
    -- contributions activate the hidden Scorcher machinery. If total genuine
    -- pieces >= 2 but Wilds still reports no Scorcher hit rate, add only the
    -- minimum extra armor carrier contributions needed to activate it.
    if carrier_needed == 0
        and real_scorcher_piece_count >= 2
        and real_scorcher_armor_piece_count < 2 then

        local native_rate =
            select(
                1,
                safe_call(
                    live_skill,
                    "getSkillScorchingHeatHitRate"
                )
            )

        native_rate =
            to_num(
                native_rate,
                0
            )

        if native_rate <= 0 then
            carrier_needed =
                math.max(
                    0,
                    2
                    - real_scorcher_armor_piece_count
                )

            record(
                "CARRIER FALLBACK",
                "total genuine pieces >=2 but native hitRate=0; "
                .. "using proven two-armor-source activation path"
            )
        end
    end

    local candidates = {}

    for source = ARMOR_SOURCE_MIN,
        ARMOR_SOURCE_MAX do

        local signature =
            source_signatures[
                source
            ]

        if not genuine_scorcher_sources[source]
            and signature ~= nil
            and #signature > 0
            and #signature < ARMOR_SKILL_SLOT_LIMIT then

            candidates[
                #candidates + 1
            ] = {
                source =
                    source,

                signature =
                    signature,
            }
        end
    end

    -- Prefer armor pieces with the most empty native skill slots.
    table.sort(
        candidates,
        function(a, b)
            if #a.signature == #b.signature then
                return a.source < b.source
            end

            return #a.signature < #b.signature
        end
    )

    carrier_sources = {}

    carrier_source_indices = {}

    carrier_plan_fingerprint =
        current_equipment_fingerprint

    for i = 1,
        math.min(
            carrier_needed,
            #candidates
        ) do

        local candidate =
            candidates[i]

        carrier_sources[
            candidate.source
        ] = {
            final_source =
                candidate.source,

            signature =
                candidate.signature,

            signature_text =
                signature_text(
                    candidate.signature
                ),

            calc_source =
                nil,

            calc_source_readable =
                false,

            mapping_learned =
                false,

            match_mode =
                nil,

            matches =
                0,

            writes =
                0,

            native_scorcher_seen =
                false,
        }

        carrier_source_indices[
            #carrier_source_indices + 1
        ] =
            candidate.source
    end

    carrier_scan_complete =
        true

    local comp_fixed,
        comp_fire =
        current_scorcher_compensation()

    cached_scorcher_comp_fixed =
        comp_fixed

    cached_scorcher_comp_fire =
        comp_fire

    if carrier_needed <= 0 then
        carrier_injection_enabled =
            false

        carrier_ready_for_heat =
            true

        carrier_status =
            "Native Scorcher already satisfies activation"

        carrier_rebuild_request_key =
            nil
    elseif #carrier_source_indices <
        carrier_needed then

        carrier_injection_enabled =
            false

        carrier_ready_for_heat =
            false

        carrier_status =
            "Not enough non-Scorcher armor sources with an empty skill slot"
    else
        carrier_injection_enabled =
            true

        carrier_ready_for_heat =
            false

        carrier_status =
            "Carrier planned; requesting native skill rebuild"

        local rebuild_key =
            tostring(
                current_equipment_fingerprint
            )
            .. "|need="
            .. tostring(
                carrier_needed
            )

        if carrier_rebuild_request_key ~=
            rebuild_key then

            local _,
                request_ok,
                request_err =
                safe_call(
                    live_skill,
                    "requestUpdateCurrentSkillInfo"
                )

            carrier_rebuild_request_key =
                rebuild_key

            record(
                "AUTO REBUILD REQUEST",
                "ok="
                .. tostring(
                    request_ok
                )
                .. " | err="
                .. tostring(
                    request_err
                )
                .. " | key="
                .. tostring(
                    rebuild_key
                )
            )

            if request_ok then
                carrier_status =
                    "Carrier planned; native rebuild requested"
            else
                carrier_status =
                    "Carrier planned; auto rebuild request failed, switch away/back once"
            end
        end
    end

    record(
        "SCORCHER PLAN",
        "realPieces="
        .. tostring(
            real_scorcher_piece_count
        )
        .. " | realArmor="
        .. tostring(
            real_scorcher_armor_piece_count
        )
        .. " | realWeapon="
        .. tostring(
            real_scorcher_weapon_piece_count
        )
        .. " | tier="
        .. tostring(
            scorcher_comp_tier
        )
        .. " | compFixed="
        .. tostring(
            cached_scorcher_comp_fixed
        )
        .. " | compFire="
        .. tostring(
            cached_scorcher_comp_fire
        )
        .. " | carrierNeeded="
        .. tostring(
            carrier_needed
        )
        .. " | carrierPlanned="
        .. tostring(
            #carrier_source_indices
        )
        .. " | fp="
        .. tostring(
            current_equipment_fingerprint
        )
        .. " | armorFp="
        .. tostring(
            current_armor_fingerprint
        )
    )

    for _, source in ipairs(
        carrier_source_indices
    ) do
        local info =
            carrier_sources[
                source
            ]

        record(
            "CARRIER SOURCE",
            "finalSource="
            .. tostring(source)
            .. " | signature=["
            .. tostring(
                info.signature_text
            )
            .. "] | calcSource=<learn>"
        )
    end

    refresh_cached_stats()

    return true
end

local function verify_scorcher_carrier()
    if not carrier_scan_complete
        or live_skill == nil then

        return
    end

    if carrier_needed <= 0 then
        carrier_ready_for_heat =
            true

        return
    end

    local current =
        select(
            1,
            safe_get_field(
                live_skill,
                "_CurrentSkillInfoDic"
            )
        )

    local entry =
        current
        and get_array_item(
            current,
            SCORCHER_ID
        )
        or nil

    if entry == nil then
        carrier_ready_for_heat =
            false

        carrier_status =
            "Carrier planned but not rebuilt yet"

        return
    end

    local active_armor_sources =
        0

    local active_source_text = {}

    for source = ARMOR_SOURCE_MIN,
        ARMOR_SOURCE_MAX do

        local source_active,
            source_level =
            read_active_source_level(
                entry,
                source
            )

        if source_active
            and source_level > 0 then

            active_armor_sources =
                active_armor_sources + 1

            active_source_text[
                #active_source_text + 1
            ] =
                tostring(source)
                .. ":"
                .. tostring(source_level)
        end
    end

    local active =
        select(
            1,
            safe_call(
                live_skill,
                "checkSkillActive",
                SCORCHER_ID
            )
        )

    if active_armor_sources >= 2
        and active == true then

        if not carrier_ready_for_heat then
            record(
                "CARRIER READY",
                "ScorcherArmorSources={"
                .. table.concat(
                    active_source_text,
                    ","
                )
                .. "} | active=true"
            )
        end

        carrier_ready_for_heat =
            true

        carrier_status =
            "Carrier active"
    else
        carrier_ready_for_heat =
            false

        carrier_status =
            "Carrier not active yet; trigger equipment rebuild"
    end
end

local function install_scorcher_carrier_hook()
    local td =
        sdk.find_type_definition(
            "app.EquipUtil"
        )

    local method =
        find_method(
            td,
            "calcTotalSkill",
            4
        )

    if method == nil then
        record(
            "HOOK CARRIER FAILED",
            "EquipUtil.calcTotalSkill(4) not found"
        )

        return false
    end

    local ok, err =
        pcall(function()
            sdk.hook(
                method,

                function(args)
                    local raw_calc_source =
                        to_num(
                            args[2],
                            nil
                        )

                    local context = {
                        -- On some native calls REFramework does not expose
                        -- calcTotalSkill arg[2] as a numeric value. V3.1
                        -- converted that failure to -1, then accidentally
                        -- treated -1 as a real shared source and blocked the
                        -- second carrier. V3.2 keeps unreadable == nil.
                        calc_source =
                            raw_calc_source ~= nil
                            and math.floor(
                                raw_calc_source
                            )
                            or nil,

                        matched_final_source =
                            nil,

                        match_mode =
                            nil,

                        wrote =
                            false,
                    }

                    table.insert(
                        carrier_calc_stack,
                        context
                    )

                    local allow_carrier_write =
                        carrier_injection_enabled
                        and cached_is_wide_gunlance

                    local skills =
                        normalize(
                            args[3]
                        )

                    local levels =
                        normalize(
                            args[4]
                        )

                    if skills == nil
                        or levels == nil then

                        return
                    end

                    local candidate =
                        list_nonzero_signature(
                            skills,
                            levels
                        )

                    if candidate == nil then
                        return
                    end

                    -- Observe genuine Scorcher independently of carrier
                    -- planning. If this raw native list already contains 191,
                    -- map its non-Scorcher signature against the current final
                    -- armor-source signatures and mark it native.
                    if list_contains_skill(
                        skills,
                        SCORCHER_ID
                    ) then

                        for source = ARMOR_SOURCE_MIN,
                            ARMOR_SOURCE_MAX do

                            local final_signature =
                                current_source_signatures_cache[
                                    source
                                ]

                            if final_signature ~= nil
                                and signatures_equal(
                                    candidate,
                                    final_signature
                                ) then

                                local sig_text =
                                    signature_text(
                                        final_signature
                                    )

                                if is_current_synthetic_carrier(
                                    source,
                                    sig_text
                                ) then

                                    if carrier_log_budget > 0 then
                                        carrier_log_budget =
                                            carrier_log_budget - 1

                                        record(
                                            "SYNTHETIC SCORCHER ECHO",
                                            "finalSource="
                                            .. tostring(
                                                source
                                            )
                                            .. " | signature=["
                                            .. tostring(
                                                sig_text
                                            )
                                            .. "] | ignored as genuine"
                                        )
                                    end
                                else
                                    native_scorcher_registry[
                                        source
                                    ] =
                                        native_scorcher_registry[
                                            source
                                        ]
                                        or {}

                                    local was_new =
                                        native_scorcher_registry[
                                            source
                                        ][
                                            sig_text
                                        ] ~=
                                        true

                                    native_scorcher_registry[
                                        source
                                    ][
                                        sig_text
                                    ] =
                                        true

                                    if was_new then
                                        record(
                                            "NATIVE SCORCHER OBSERVED",
                                            "finalSource="
                                            .. tostring(
                                                source
                                            )
                                            .. " | signature=["
                                            .. tostring(
                                                sig_text
                                            )
                                            .. "]"
                                        )

                                        carrier_auto_scan_pending =
                                            true

                                        carrier_rescan_not_before_frame =
                                            frame + 4
                                    end
                                end
                            end
                        end
                    end

                    if not allow_carrier_write then
                        return
                    end

                    --------------------------------------------------------
                    -- V3.1 IMPORTANT CHANGE
                    --
                    -- V3 incorrectly assumed:
                    --
                    --   final _ActiveEquipIndex == calcTotalSkill arg[2]
                    --
                    -- We already knew from the source-mapping probe that
                    -- this is NOT universally safe. The successful two-piece
                    -- POC happened to use source 4/5 where they lined up.
                    --
                    -- V3.1 instead identifies the real calcTotalSkill call
                    -- by the armor piece's signature, then LEARNS its actual
                    -- calc source number. Once learned, later calls are
                    -- locked to that calc source.
                    --------------------------------------------------------

                    local matched_info =
                        nil

                    local matched_final_source =
                        nil

                    local match_mode =
                        nil

                    -- Pass 1: exact skill + level signature.
                    for _, final_source in ipairs(
                        carrier_source_indices
                    ) do
                        local info =
                            carrier_sources[
                                final_source
                            ]

                        if info ~= nil
                            and (
                                not info.calc_source_readable
                                or context.calc_source == nil
                                or info.calc_source ==
                                    context.calc_source
                            )
                            and signatures_equal(
                                candidate,
                                info.signature
                            ) then

                            matched_info =
                                info

                            matched_final_source =
                                final_source

                            match_mode =
                                "exact"

                            break
                        end
                    end

                    -- Pass 2: exact skill-id set only. This is deliberately
                    -- conservative: same count + same sorted skill IDs.
                    if matched_info == nil then
                        for _, final_source in ipairs(
                            carrier_source_indices
                        ) do
                            local info =
                                carrier_sources[
                                    final_source
                                ]

                            if info ~= nil
                                and (
                                    info.calc_source == nil
                                    or info.calc_source ==
                                        context.calc_source
                                )
                                and signature_skill_ids_equal(
                                    candidate,
                                    info.signature
                                ) then

                                matched_info =
                                    info

                                matched_final_source =
                                    final_source

                                match_mode =
                                    "skill_ids"

                                break
                            end
                        end
                    end

                    if matched_info == nil then
                        return
                    end

                    -- Do not let two planned armor pieces bind themselves
                    -- to the same learned calc-source path.
                    if not matched_info.mapping_learned then
                        -- Only use calc-source uniqueness if the native
                        -- argument was actually readable. An unreadable value
                        -- must NOT collapse every armor piece onto the same
                        -- fake source (the V3.1 "-1" bug).
                        if context.calc_source ~= nil then
                            for other_final_source, other_info in pairs(
                                carrier_sources
                            ) do
                                if other_final_source ~=
                                    matched_final_source
                                    and other_info.calc_source_readable
                                    and other_info.calc_source ==
                                        context.calc_source then

                                    return
                                end
                            end

                            matched_info.calc_source =
                                context.calc_source

                            matched_info.calc_source_readable =
                                true
                        end

                        matched_info.mapping_learned =
                            true

                        matched_info.match_mode =
                            match_mode

                        record(
                            "CARRIER MAPPING LEARNED",
                            "finalSource="
                            .. tostring(
                                matched_final_source
                            )
                            .. " -> calcSource="
                            .. (
                                context.calc_source ~= nil
                                and tostring(
                                    context.calc_source
                                )
                                or "<unreadable>"
                            )
                            .. " | mode="
                            .. tostring(
                                match_mode
                            )
                            .. " | finalSignature=["
                            .. tostring(
                                matched_info.signature_text
                            )
                            .. "] | calcSignature=["
                            .. signature_text(
                                candidate
                            )
                            .. "]"
                        )
                    end

                    context.matched_final_source =
                        matched_final_source

                    context.match_mode =
                        match_mode

                    matched_info.matches =
                        matched_info.matches + 1

                    carrier_total_matches =
                        carrier_total_matches + 1

                    -- If 191 is already present, first ask whether it is
                    -- simply our own earlier write coming back through another
                    -- calcTotalSkill pass.
                    if list_contains_skill(
                        skills,
                        SCORCHER_ID
                    ) then

                        if is_current_synthetic_carrier(
                            matched_final_source,
                            matched_info.signature_text
                        ) then

                            if carrier_log_budget > 0 then
                                carrier_log_budget =
                                    carrier_log_budget - 1

                                record(
                                    "SYNTHETIC SCORCHER ECHO",
                                    "finalSource="
                                    .. tostring(
                                        matched_final_source
                                    )
                                    .. " | signature=["
                                    .. tostring(
                                        matched_info.signature_text
                                    )
                                    .. "] | no duplicate write"
                                )
                            end

                            return
                        end

                        matched_info.native_scorcher_seen =
                            true

                        native_scorcher_registry[
                            matched_final_source
                        ] =
                            native_scorcher_registry[
                                matched_final_source
                            ]
                            or {}

                        native_scorcher_registry[
                            matched_final_source
                        ][
                            matched_info.signature_text
                        ] =
                            true

                        if carrier_log_budget > 0 then
                            carrier_log_budget =
                                carrier_log_budget - 1

                            record(
                                "NATIVE SCORCHER CONFIRMED",
                                "finalSource="
                                .. tostring(
                                    matched_final_source
                                )
                                .. " | signature=["
                                .. tostring(
                                    matched_info.signature_text
                                )
                                .. "] | no carrier write"
                            )
                        end

                        carrier_auto_scan_pending =
                            true

                        carrier_rescan_not_before_frame =
                            frame + 4

                        return
                    end

                    local empty_slot =
                        first_empty_pair(
                            skills,
                            levels
                        )

                    if empty_slot == nil then
                        if carrier_log_budget > 0 then
                            carrier_log_budget =
                                carrier_log_budget - 1

                            record(
                                "CARRIER WRITE SKIPPED",
                                "finalSource="
                                .. tostring(
                                    matched_final_source
                                )
                                .. " | calcSource="
                                .. tostring(
                                    context.calc_source
                                )
                                .. " | no 0/0 slot"
                            )
                        end

                        return
                    end

                    local skill_ok =
                        list_set(
                            skills,
                            empty_slot,
                            SCORCHER_ID
                        )

                    local level_ok =
                        list_set(
                            levels,
                            empty_slot,
                            1
                        )

                    local skill_after =
                        math.floor(
                            to_num(
                                list_get(
                                    skills,
                                    empty_slot
                                ),
                                -1
                            )
                        )

                    local level_after =
                        math.floor(
                            to_num(
                                list_get(
                                    levels,
                                    empty_slot
                                ),
                                -1
                            )
                        )

                    context.wrote =
                        skill_ok
                        and level_ok
                        and skill_after == SCORCHER_ID
                        and level_after == 1

                    if context.wrote then
                        matched_info.writes =
                            matched_info.writes + 1

                        carrier_total_writes =
                            carrier_total_writes + 1

                        synthetic_carrier_registry[
                            matched_final_source
                        ] =
                            synthetic_carrier_registry[
                                matched_final_source
                            ]
                            or {}

                        synthetic_carrier_registry[
                            matched_final_source
                        ][
                            matched_info.signature_text
                        ] =
                            current_armor_fingerprint
                    end

                    if carrier_log_budget > 0 then
                        carrier_log_budget =
                            carrier_log_budget - 1

                        record(
                            "CARRIER WRITE",
                            "finalSource="
                            .. tostring(
                                matched_final_source
                            )
                            .. " | calcSource="
                            .. (
                                context.calc_source ~= nil
                                and tostring(
                                    context.calc_source
                                )
                                or "<unreadable>"
                            )
                            .. " | mode="
                            .. tostring(
                                match_mode
                            )
                            .. " | slot="
                            .. tostring(
                                empty_slot
                            )
                            .. " | verified="
                            .. tostring(
                                context.wrote
                            )
                            .. " | calcSignature=["
                            .. signature_text(
                                candidate
                            )
                            .. "]"
                        )
                    end
                end,

                function(retval)
                    table.remove(
                        carrier_calc_stack
                    )

                    return retval
                end
            )
        end)

    record(
        ok
        and "HOOKED CARRIER"
        or "HOOK CARRIER FAILED",
        ok
        and "EquipUtil.calcTotalSkill(4) dynamic signature mapper"
        or tostring(err)
    )

    return ok
end

------------------------------------------------------------
-- SCORCHER DATAPACK
------------------------------------------------------------

local function read_inner_value(
    element
)
    local value,
        ok =
        safe_get_field(
            element,
            "_Value"
        )

    if not ok then
        return nil
    end

    return
        to_num(
            value,
            nil
        )
end

local function resolve_datapack()
    refresh_cached_stats()

    if live_skill == nil then
        last_error =
            "No HunterSkill available"

        return false
    end

    local skill_param,
        ok =
        safe_call(
            live_skill,
            "get__SkillParam"
        )

    if not ok
        or skill_param == nil then

        last_error =
            "get__SkillParam failed"

        return false
    end

    skill_param =
        normalize(
            skill_param
        )

    local scorching_heat

    scorching_heat,
    ok =
        safe_call(
            skill_param,
            "get_ScorchingHeatData"
        )

    if not ok
        or scorching_heat == nil then

        scorching_heat,
        ok =
            safe_get_field(
                skill_param,
                "_ScorchingHeatData"
            )
    end

    if not ok
        or scorching_heat == nil then

        last_error =
            "ScorchingHeatData unavailable"

        return false
    end

    scorching_heat =
        normalize(
            scorching_heat
        )

    local datapack

    datapack,
    ok =
        safe_get_field(
            scorching_heat,
            "_DataPack"
        )

    if not ok
        or datapack == nil then

        last_error =
            "_DataPack unavailable"

        return false
    end

    datapack =
        normalize(
            datapack
        )

    scorch_index7 =
        get_array_item(
            datapack,
            7
        )

    scorch_index8 =
        get_array_item(
            datapack,
            8
        )

    if scorch_index7 == nil
        or scorch_index8 == nil then

        last_error =
            "DataPack 7/8 unavailable"

        return false
    end

    original_index7 =
        read_inner_value(
            scorch_index7
        )

    original_index8 =
        read_inner_value(
            scorch_index8
        )

    if original_index7 == nil
        or original_index8 == nil then

        last_error =
            "Could not read DataPack 7/8 _Value"

        return false
    end

    datapack_resolved =
        true

    last_error =
        nil

    record(
        "DATAPACK RESOLVED",
        "index7=" ..
        tostring(
            original_index7
        )
        .. " | index8=" ..
        tostring(
            original_index8
        )
    )

    return true
end

local function write_inner_value(
    element,
    value
)
    return
        safe_set_field(
            element,
            "_Value",
            value
        )
end

------------------------------------------------------------
-- MINIMAL HOOK WORK
------------------------------------------------------------

local function force_proc_state(
    skill
)
    local info,
        ok =
        safe_get_field(
            skill,
            "_HunterSkillParamInfo"
        )

    if not ok
        or info == nil then

        return false
    end

    info =
        normalize(
            info
        )

    local ok1 =
        safe_set_field(
            info,
            "_ScorchingHeatIntervalTime",
            0.0
        )

    local ok2 =
        safe_set_field(
            info,
            "_ScorchingHeatNoHitCount",
            2
        )

    return ok1 and ok2
end

local function pre_hook(args)
    live_skill =
        normalize(
            args[2]
        )

    live_hunter =
        normalize(
            args[5]
        )

    hook_write_active =
        false

    if not datapack_resolved
        or live_skill == nil then

        return
    end

    -- V3.7 SAFETY BOUNDARY:
    -- Heat Blade is completely hands-off on native Scorcher whenever the
    -- current weapon is not Wide. This prevents stale Wide carrier state from
    -- damaging genuine Scorcher behavior on Long/Normal Gunlances.
    if not cached_is_wide_gunlance then
        return
    end

    -- V6.3: passive Heat controls Razor Sharp/MV, but the synthetic
    -- Scorcher carrier must remain damage-suppressed until Wyvern Fire has
    -- actually activated BLACK/BLUE.
    local suppress_synthetic =
        carrier_needed > 0
        and (
            HB_GAUGE == nil
            or not HB_GAUGE.activation_active
            or not carrier_ready_for_heat
        )

    if suppress_synthetic then
        local ok7 =
            write_inner_value(
                scorch_index7,
                0.0
            )

        local ok8 =
            write_inner_value(
                scorch_index8,
                0.0
            )

        hook_write_active =
            ok7
            and ok8

        -- Do NOT force the proc state while suppressing. If native Scorcher
        -- happens to roll, it resolves for zero and its normal counter state
        -- remains native.
        return
    end

    if HB_GAUGE == nil
        or not HB_GAUGE.activation_active
        or HB_GAUGE.locked_value == nil
        or HB_GAUGE.blue_value == nil
        or HB_GAUGE.blue_value <= 0.0
        or not carrier_ready_for_heat then

        return
    end

    if not cached_ready then
        return
    end

    local ok7 =
        write_inner_value(
            scorch_index7,
            cached_index7
        )

    local ok8 =
        write_inner_value(
            scorch_index8,
            cached_index8
        )

    if not ok7
        or not ok8 then

        return
    end

    -- Heat Blade hijacks the Scorcher event into one deterministic payload:
    -- Heat Blade damage + balanced expected-value genuine Scorcher damage.
    if not force_proc_state(
        live_skill
    ) then
        return
    end

    hook_write_active =
        true
end

local function post_hook(retval)
    if hook_write_active
        and datapack_resolved then

        write_inner_value(
            scorch_index7,
            original_index7
        )

        write_inner_value(
            scorch_index8,
            original_index8
        )
    end

    hook_write_active =
        false

    return retval
end


------------------------------------------------------------
-- DIRECT RAZOR SHARP CONSUMPTION HOOK
------------------------------------------------------------

local function read_requested_consume(
    kireaji
)
    if kireaji == nil then
        return nil
    end

    local value,
        ok =
        safe_get_field(
            kireaji,
            "_RequestedConsumeKireaji"
        )

    if not ok then
        return nil
    end

    return
        to_num(
            value,
            nil
        )
end

local function direct_razor_pre_hook(args)
    razor_calls_total =
        razor_calls_total + 1

    local handling =
        normalize(
            args[2]
        )

    local handling_addr =
        safe_address(
            handling
        )

    local real_level =
        cached_native_razor_level
        or 0

    local target_level =
        math.max(
            real_level,
            heat_razor_level()
        )

    local context = {
        local_player =
            false,

        eligible =
            false,

        kireaji =
            nil,

        requested_before =
            nil,

        real_level =
            real_level,

        target_level =
            target_level,
    }

    if handling_addr ~= nil
        and live_handling_addr ~= nil
        and handling_addr ==
            live_handling_addr then

        context.local_player =
            true

        razor_calls_local =
            razor_calls_local + 1
    end

    if context.local_player
        and cached_is_wide_gunlance
        and target_level >
            real_level
        and heat_razor_level() >
            0
        and live_kireaji ~= nil then

        context.eligible =
            true

        context.kireaji =
            live_kireaji

        context.requested_before =
            read_requested_consume(
                live_kireaji
            )
    end

    table.insert(
        razor_consume_stack,
        context
    )
end

local function direct_razor_post_hook(
    retval
)
    local context =
        table.remove(
            razor_consume_stack
        )

    if context == nil
        or not context.local_player then

        return retval
    end

    local original_consume =
        retval_to_int(
            retval,
            0
        )

    last_razor_original_consume =
        original_consume

    last_razor_requested_before =
        context.requested_before

    last_razor_real_level =
        context.real_level

    last_razor_target_level =
        context.target_level

    -- Native Razor Sharp already protected this attack.
    if original_consume <= 0 then
        if (context.real_level or 0) > 0 then
            razor_native_protections =
                razor_native_protections + 1
        end

        last_razor_requested_after =
            read_requested_consume(
                context.kireaji
                or live_kireaji
            )

        last_razor_roll =
            nil

        last_razor_extra_chance =
            0.0

        return retval
    end

    razor_original_consumes =
        razor_original_consumes + 1

    if not context.eligible
        or context.kireaji == nil then

        last_razor_requested_after =
            read_requested_consume(
                context.kireaji
                or live_kireaji
            )

        last_razor_roll =
            nil

        last_razor_extra_chance =
            0.0

        return retval
    end

    local extra_chance =
        conditional_extra_razor_chance(
            context.real_level,
            context.target_level
        )

    last_razor_extra_chance =
        extra_chance

    if extra_chance <= 0.0 then
        last_razor_requested_after =
            read_requested_consume(
                context.kireaji
            )

        last_razor_roll =
            nil

        return retval
    end

    local forced =
        force_next_razor_protection

    if forced then
        force_next_razor_protection =
            false
    end

    local roll =
        forced
        and 0.0
        or next_razor_roll()

    last_razor_roll =
        roll

    if forced
        or roll <
            extra_chance then

        local write_ok =
            safe_set_field(
                context.kireaji,
                "_RequestedConsumeKireaji",
                0
            )

        last_razor_requested_after =
            read_requested_consume(
                context.kireaji
            )

        if write_ok
            and last_razor_requested_after == 0 then

            razor_heat_protections =
                razor_heat_protections + 1

            record(
                "HEAT RAZOR PROC",
                "realLv=" ..
                tostring(
                    context.real_level
                )
                .. " | targetLv=" ..
                tostring(
                    context.target_level
                )
                .. " | original=" ..
                tostring(
                    original_consume
                )
                .. " | chance=" ..
                tostring(
                    extra_chance
                )
                .. " | roll=" ..
                tostring(
                    roll
                )
                .. " | forced=" ..
                tostring(
                    forced
                )
            )

            -- Native successful Razor Sharp returns 0 from
            -- consumeKireajiFromAttack, preventing the subsequent
            -- cWeaponKireaji.consumeKireaji call.
            return
                sdk.to_ptr(
                    0
                )
        end

        razor_write_failures =
            razor_write_failures + 1

        record(
            "HEAT RAZOR WRITE FAILED",
            "original=" ..
            tostring(
                original_consume
            )
            .. " | requested_after=" ..
            tostring(
                last_razor_requested_after
            )
        )

        return retval
    end

    last_razor_requested_after =
        read_requested_consume(
            context.kireaji
        )

    return retval
end


------------------------------------------------------------
-- V6.2 DIRECT GUNLANCE MELEE MV HOOK
------------------------------------------------------------

HB_MELEE.valid_record =
    function(source)
        local is_sensor =
            select(
                1,
                safe_get_field(
                    source,
                    "_IsSensor"
                )
            )

        local fix_attack =
            to_num(
                select(
                    1,
                    safe_get_field(
                        source,
                        "_FixAttack"
                    )
                ),
                nil
            )

        local attr_value =
            to_num(
                select(
                    1,
                    safe_get_field(
                        source,
                        "_AttrValue"
                    )
                ),
                nil
            )

        local break_rate =
            to_num(
                select(
                    1,
                    safe_get_field(
                        source,
                        "_PartsBreakRate"
                    )
                ),
                nil
            )

        return
            is_sensor == false
            and fix_attack ~= nil
            and math.abs(fix_attack) < 0.001
            and attr_value ~= nil
            and math.abs(attr_value) < 0.001
            and break_rate ~= nil
            and math.abs(break_rate - 1.0) < 0.001
    end

-- The stake thrust record is structurally distinct in the probe: it is the
-- point-attack / pre-point-reaction / raw-scar-limit / weak-point-limit record.
-- These fields are part of AttackParamPl and stay with the source record, unlike
-- _AttackUniqueID, which shifts between sessions. Everything else passing the
-- normal Gunlance melee filter receives the passive Heat MV bonus.
HB_MELEE.is_stake_thrust =
    function(source)
        local is_point =
            select(1, safe_get_field(source, "_IsPointAttack"))

        local is_pre_point =
            select(1, safe_get_field(source, "_IsPrePointHitReaction"))

        local is_raw_scar_limit =
            select(1, safe_get_field(source, "_IsRawScarLimit"))

        local is_weak_point_limit =
            select(1, safe_get_field(source, "_IsWeakPointLimit"))

        return
            is_point == true
            and is_pre_point == true
            and is_raw_scar_limit == true
            and is_weak_point_limit == true
    end

HB_MELEE.pre_hook =
    function(args)
        HB_MELEE.calls =
            HB_MELEE.calls + 1

        local context = {
            source = nil,
            restore_attack = nil,
            temporary_attack = nil,
            bonus = 0.0,
            bridge_key = nil,
            bridge_token = nil,
            active_key = nil,
            active_token = nil,
            nested_reuse = false,
        }

        table.insert(
            HB_MELEE.stack,
            context
        )

        -- Heat Blade owns only the passive Heat MV bonus. Permanent Gunlance
        -- baseline changes are handled separately by v2_gl_override.lua.
        if not cached_is_wide_gunlance then
            return
        end

        local source =
            normalize(
                args[2]
            )

        local request_data =
            normalize(
                args[3]
            )

        if source == nil
            or not HB_MELEE.valid_record(
                source
            ) then

            return
        end

        local attack_id = -1

        if request_data ~= nil then
            attack_id =
                math.floor(
                    to_num(
                        select(
                            1,
                            safe_get_field(
                                request_data,
                                "_AttackUniqueID"
                            )
                        ),
                        -1
                    )
                )
        end

        local old_attack =
            to_num(
                select(
                    1,
                    safe_get_field(
                        source,
                        "_Attack"
                    )
                ),
                nil
            )

        if old_attack == nil then
            return
        end

        -- createRuntimeAttackParam can re-enter for the same AttackParamPl
        -- source before the outer post-hook restores our temporary MV. Without
        -- this guard, the inner call sees the already-buffed source and adds
        -- +4/+8 a second time. Reuse the outer call's temporary value instead.
        local source_key =
            safe_address(
                source
            )

        if source_key ~= nil
            and HB_MELEE.active_sources[source_key] ~= nil then

            local active =
                HB_MELEE.active_sources[source_key]

            context.nested_reuse =
                true

            HB_MELEE.nested_reuses =
                HB_MELEE.nested_reuses + 1

            HB_MELEE.last_id =
                attack_id

            HB_MELEE.last_before =
                old_attack

            HB_MELEE.last_after =
                old_attack

            HB_MELEE.last_runtime_attack =
                old_attack

            HB_MELEE.last_bonus =
                active.bonus
                or 0.0

            HB_MELEE.last_stake_excluded =
                active.stake_excluded
                or false

            return
        end

        local stake_excluded =
            HB_MELEE.is_stake_thrust(
                source
            )

        local heat_bonus =
            stake_excluded
            and 0.0
            or HB_MELEE.heat_bonus()

        -- Publish the exact pre-Heat source MV for v2_gl_override if that
        -- hook runs later in this same createRuntimeAttackParam call.
        local bridge_key =
            source_key

        local call_token = {}

        if bridge_key ~= nil then
            HB_MELEE.active_sources[
                bridge_key
            ] = {
                token = call_token,
                bonus = heat_bonus,
                stake_excluded = stake_excluded,
                original_attack = old_attack,
            }

            context.active_key =
                bridge_key

            context.active_token =
                call_token
        end

        if bridge_key ~= nil
            and HB_MELEE.runtime_bridge ~= nil
            and HB_MELEE.runtime_bridge.active_by_source ~= nil then

            HB_MELEE.runtime_bridge.active_by_source[
                bridge_key
            ] = {
                token = call_token,
                original_attack = old_attack,
                heat_bonus = heat_bonus,
                stake_excluded = stake_excluded,
            }

            context.bridge_key =
                bridge_key

            context.bridge_token =
                call_token
        end

        local target_attack =
            old_attack
            + heat_bonus

        HB_MELEE.last_id =
            attack_id

        HB_MELEE.last_before =
            old_attack

        HB_MELEE.last_after =
            target_attack

        HB_MELEE.last_bonus =
            heat_bonus

        HB_MELEE.last_stake_excluded =
            stake_excluded

        if math.abs(
            target_attack
            - old_attack
        ) < 0.001 then

            return
        end

        if safe_set_field(
            source,
            "_Attack",
            target_attack
        ) then

            context.source =
                source

            context.restore_attack =
                old_attack

            context.temporary_attack =
                target_attack

            context.bonus =
                heat_bonus

            HB_MELEE.writes =
                HB_MELEE.writes + 1
        end
    end

HB_MELEE.post_hook =
    function(retval)
        local context =
            table.remove(
                HB_MELEE.stack
            )

        -- Remove only the bridge marker published by this exact call.
        if context ~= nil
            and context.bridge_key ~= nil
            and HB_MELEE.runtime_bridge ~= nil
            and HB_MELEE.runtime_bridge.active_by_source ~= nil then

            local active =
                HB_MELEE.runtime_bridge.active_by_source[
                    context.bridge_key
                ]

            if active ~= nil
                and active.token ==
                    context.bridge_token then

                HB_MELEE.runtime_bridge.active_by_source[
                    context.bridge_key
                ] = nil
            end
        end

        if context ~= nil
            and context.source ~= nil
            and context.restore_attack ~= nil then

            local current_attack =
                to_num(
                    select(
                        1,
                        safe_get_field(
                            context.source,
                            "_Attack"
                        )
                    ),
                    nil
                )

            HB_MELEE.last_runtime_attack =
                current_attack

            if current_attack ~= nil
                and context.temporary_attack ~= nil
                and math.abs(
                    current_attack
                    - context.temporary_attack
                ) < 0.001 then

                -- No other hook changed the source while the runtime parameter
                -- was being created: restore the exact value we temporarily read.
                safe_set_field(
                    context.source,
                    "_Attack",
                    context.restore_attack
                )

            elseif current_attack ~= nil
                and context.bonus ~= nil
                and context.bonus > 0.0 then

                -- Another createRuntimeAttackParam hook (notably
                -- v2_gl_override) changed the source after Heat Blade's pre-hook.
                -- Preserve that hook's new baseline while removing only our
                -- temporary +4/+8 contribution. This makes hook load order safe.
                safe_set_field(
                    context.source,
                    "_Attack",
                    current_attack - context.bonus
                )
            else
                safe_set_field(
                    context.source,
                    "_Attack",
                    context.restore_attack
                )
            end
        end

        -- Clear only the active-source lock owned by this exact outer call.
        -- Nested reuses never own a token and therefore cannot clear it early.
        if context ~= nil
            and context.active_key ~= nil then

            local active =
                HB_MELEE.active_sources[
                    context.active_key
                ]

            if active ~= nil
                and active.token ==
                    context.active_token then

                HB_MELEE.active_sources[
                    context.active_key
                ] = nil
            end
        end

        return retval
    end

HB_MELEE.install =
    function()
        local td =
            sdk.find_type_definition(
                HB_MELEE.type_name
            )

        if td == nil then
            HB_MELEE.last_error =
                "Could not find "
                .. tostring(HB_MELEE.type_name)

            return false
        end

        local method =
            td:get_method(
                HB_MELEE.method_name
            )

        if method == nil then
            method =
                td:get_method(
                    "createRuntimeAttackParam(app.cRequestSetAttackParamRuntimeData)"
                )
        end

        if method == nil then
            HB_MELEE.last_error =
                "Could not find AttackParamPl.createRuntimeAttackParam"

            return false
        end

        local ok, err =
            pcall(function()
                sdk.hook(
                    method,
                    HB_MELEE.pre_hook,
                    HB_MELEE.post_hook
                )
            end)

        HB_MELEE.hook_installed =
            ok

        HB_MELEE.last_error =
            ok
            and nil
            or tostring(err)

        record(
            ok
            and "HOOKED MELEE MV"
            or "HOOK MELEE MV FAILED",
            ok
            and "AttackParamPl.createRuntimeAttackParam; structural stake exclusion"
            or tostring(err)
        )

        return ok
    end

------------------------------------------------------------
--
-- Probe-confirmed boundaries:
--   shootShell(1)           -> one ordinary shell fired
--   requestChargeShot(1)    -> one charged shell released
--   onShell_PostShoot(1)    -> one shell completion; while Full Burst is
--                              active, this occurs once per Full Burst shell
--
-- Full Burst family:
--   requestFullBurst / requestJumpFullBurst
--   requestBulletFire
--   requestBulletFireReload
-- all feed setupFullBurst, so they share the same per-shell +8 counting path.
--
-- Generation values:
--   Regular shell        +10
--   Charged shell        +18
--   Full Burst shell      +8
--   BF / RBF shell        +8
--
-- Heat state is derived automatically from the gauge.

HB_GAUGE = {
    -- WHITE: stored Heat that shells build and Wyvern Fire spends.
    value = 0.0,

    max = 129.0,
    orange_start = 44.0,
    red_start = 87.0,

    regular_gain = 12.0,
    charged_gain = 26.4,
    fullburst_gain = 9.6,

    -- White Heat cools from 129 -> 0 in 150 seconds.
    decay_seconds = 150.0,
    decay_rate = 129.0 / 150.0,

    -- BLACK: stationary activation snapshot.
    locked_value = nil,

    -- BLUE: remaining Heat Blade duration.
    blue_value = nil,
    blue_decay_seconds = 210.0,
    blue_decay_rate = 129.0 / 210.0,

    activation_active = false,
    activation_count = 0,
    last_wyvern_activation_frame = -999999,

    pending_fullburst = "NONE",
    active_fullburst = "NONE",
    fullburst_until = -1,

    regular_count = 0,
    charged_count = 0,
    fullburst_count = 0,

    last_kind = "NONE",
    last_gain = 0.0,

    action_hooks_installed = 0,
    regular_hook_ok = false,
    charged_hook_ok = false,
    postshoot_hook_ok = false,
    wyvern_hook_ok = false,

    -- Gauge overlay defaults.
    display_left = 310,
    display_top = 171,
    display_width = 129,
    display_height = 10,

    white_marker_width = 3,
    black_marker_width = 5,
    blue_marker_width = 3,
    border = 2,

    application_type = nil,
    uptime_method = nil,
    last_uptime = nil,

    -- Ignore pathological frame gaps from loading/equipment swaps.
    max_decay_step = 0.25,

    fallback_clock = os.clock(),
    delta_source = "<not initialized>",
    last_delta = 0.0,
    timing_clamps = 0,

    stats_refresh_pending = false,
    last_error = nil,
}

HB_GAUGE.state_for_value =
    function(value)
        local v =
            tonumber(value)
            or 0.0

        if v >= HB_GAUGE.red_start then
            return HEAT_RED
        end

        if v >= HB_GAUGE.orange_start then
            return HEAT_ORANGE
        end

        return HEAT_YELLOW
    end

HB_GAUGE.passive_heat_value =
    function()
        local passive_value =
            tonumber(
                HB_GAUGE.value
            )
            or 0.0

        -- BLACK is active Heat. WHITE is newly stored Heat for the next
        -- activation. Use whichever is higher so Wyvern Fire cannot erase the
        -- passive Razor Sharp / lance-MV tier, while newly generated WHITE can
        -- still raise that passive tier during an activation.
        if HB_GAUGE.activation_active
            and HB_GAUGE.locked_value ~= nil then

            passive_value =
                math.max(
                    passive_value,
                    tonumber(
                        HB_GAUGE.locked_value
                    )
                    or 0.0
                )
        end

        return passive_value
    end

HB_GAUGE.sync_heat_state =
    function(reason)
        -- V6.3 PASSIVE STATE: Razor Sharp and direct lance MV use effective
        -- passive Heat = max(WHITE, BLACK while active). A Wide Gunlance at
        -- zero Heat with no active BLACK is therefore YELLOW, never OFF.
        local desired_state =
            HEAT_OFF

        local passive_value =
            0.0

        if cached_is_wide_gunlance then
            passive_value =
                HB_GAUGE.passive_heat_value()

            desired_state =
                HB_GAUGE.state_for_value(
                    passive_value
                )
        end

        if heat_state ==
            desired_state then

            return
        end

        heat_state =
            desired_state

        -- Refresh combat caches on the next frame rather than doing heavier
        -- object traversal from a weapon action hook.
        HB_GAUGE.stats_refresh_pending =
            true

        record(
            "HEAT STATE",
            "state="
            .. (
                heat_state == HEAT_RED
                and "RED"
                or heat_state == HEAT_ORANGE
                and "ORANGE"
                or heat_state == HEAT_YELLOW
                and "YELLOW"
                or "OFF"
            )
            .. " | passive="
            .. string.format(
                "%.2f",
                passive_value
            )
            .. " | white="
            .. string.format(
                "%.2f",
                HB_GAUGE.value
            )
            .. " | black="
            .. (
                HB_GAUGE.locked_value ~= nil
                and string.format(
                    "%.2f",
                    HB_GAUGE.locked_value
                )
                or "<none>"
            )
            .. " | blue="
            .. (
                HB_GAUGE.blue_value ~= nil
                and string.format(
                    "%.2f",
                    HB_GAUGE.blue_value
                )
                or "<none>"
            )
            .. " | reason="
            .. tostring(
                reason
                or "<none>"
            )
        )
    end

HB_GAUGE.deactivate =
    function(reason)
        local was_active =
            HB_GAUGE.activation_active
            or heat_state ~= HEAT_OFF
            or HB_GAUGE.locked_value ~= nil
            or HB_GAUGE.blue_value ~= nil

        HB_GAUGE.activation_active =
            false

        HB_GAUGE.locked_value =
            nil

        HB_GAUGE.blue_value =
            nil

        HB_GAUGE.sync_heat_state(
            reason
            or "deactivate"
        )

        -- Rider activation changed even if White stayed in the same passive tier.
        HB_GAUGE.stats_refresh_pending =
            true

        if was_active then
            record(
                "SCORCHER RIDER OFF",
                "white="
                .. string.format(
                    "%.2f",
                    HB_GAUGE.value
                )
                .. " | reason="
                .. tostring(
                    reason
                    or "deactivate"
                )
            )
        end
    end

HB_GAUGE.activate_from_white =
    function(reason)
        if not cached_is_wide_gunlance then
            return
        end

        -- Defensive same-frame guard in case the native method is reached
        -- more than once for one Wyvern Fire.
        if HB_GAUGE.last_wyvern_activation_frame ==
            frame then

            return
        end

        HB_GAUGE.last_wyvern_activation_frame =
            frame

        local snapshot =
            math.max(
                0.0,
                math.min(
                    HB_GAUGE.max,
                    tonumber(
                        HB_GAUGE.value
                    )
                    or 0.0
                )
            )

        -- Wyvern Fire spends all currently stored White Heat.
        HB_GAUGE.value =
            0.0

        -- Any stale Full Burst context should not survive into Wyvern Fire.
        HB_GAUGE.pending_fullburst =
            "NONE"

        HB_GAUGE.active_fullburst =
            "NONE"

        HB_GAUGE.fullburst_until =
            -1

        if snapshot <= 0.0 then
            HB_GAUGE.deactivate(
                "Wyvern Fire at 0 Heat"
            )

            record(
                "WYVERN ACTIVATE",
                "snapshot=0.00 | no duration"
            )

            return
        end

        HB_GAUGE.locked_value =
            snapshot

        HB_GAUGE.blue_value =
            snapshot

        HB_GAUGE.activation_active =
            true

        HB_GAUGE.activation_count =
            HB_GAUGE.activation_count + 1

        HB_GAUGE.sync_heat_state(
            reason
            or "Wyvern Fire"
        )

        -- BLACK/BLUE rider state changed; passive Heat retains the active snapshot tier.
        HB_GAUGE.stats_refresh_pending =
            true

        local activated_state =
            HB_GAUGE.state_for_value(
                snapshot
            )

        record(
            "WYVERN ACTIVATE",
            "snapshot="
            .. string.format(
                "%.2f",
                snapshot
            )
            .. " | riderTier="
            .. (
                activated_state == HEAT_RED
                and "RED"
                or activated_state == HEAT_ORANGE
                and "ORANGE"
                or "YELLOW"
            )
            .. " | passiveTier="
            .. (
                activated_state == HEAT_RED
                and "RED"
                or activated_state == HEAT_ORANGE
                and "ORANGE"
                or "YELLOW"
            )
            .. " | white=0"
        )
    end

HB_GAUGE.reset_for_non_wide =
    function(reason)
        local had_anything =
            HB_GAUGE.value > 0.0
            or HB_GAUGE.activation_active
            or HB_GAUGE.locked_value ~= nil
            or HB_GAUGE.blue_value ~= nil
            or heat_state ~= HEAT_OFF

        HB_GAUGE.value =
            0.0

        HB_GAUGE.pending_fullburst =
            "NONE"

        HB_GAUGE.active_fullburst =
            "NONE"

        HB_GAUGE.fullburst_until =
            -1

        HB_GAUGE.activation_active =
            false

        HB_GAUGE.locked_value =
            nil

        HB_GAUGE.blue_value =
            nil

        HB_GAUGE.sync_heat_state(
            reason
            or "non-Wide detected"
        )

        if had_anything then
            record(
                "GAUGE RESET",
                "white=0 | black=<none> | blue=<none> | reason="
                .. tostring(
                    reason
                    or "non-Wide detected"
                )
            )
        end
    end

HB_GAUGE.reset_all =
    function(reason)
        HB_GAUGE.value =
            0.0

        HB_GAUGE.pending_fullburst =
            "NONE"

        HB_GAUGE.active_fullburst =
            "NONE"

        HB_GAUGE.fullburst_until =
            -1

        HB_GAUGE.activation_active =
            false

        HB_GAUGE.locked_value =
            nil

        HB_GAUGE.blue_value =
            nil

        HB_GAUGE.last_kind =
            "NONE"

        HB_GAUGE.last_gain =
            0.0

        HB_GAUGE.sync_heat_state(
            reason
            or "manual reset"
        )
    end

HB_GAUGE.init_delta_time =
    function()
        if HB_GAUGE.application_type ==
            nil then

            local ok_type,
                app_type =
                pcall(function()
                    return
                        sdk.find_type_definition(
                            "via.Application"
                        )
                end)

            if ok_type then
                HB_GAUGE.application_type =
                    app_type
            end
        end

        if HB_GAUGE.uptime_method ==
            nil
            and HB_GAUGE.application_type ~=
                nil then

            local ok_method,
                method =
                pcall(function()
                    return
                        HB_GAUGE.application_type:
                            get_method(
                                "get_UpTimeSecond"
                            )
                end)

            if ok_method then
                HB_GAUGE.uptime_method =
                    method
            end
        end
    end

HB_GAUGE.get_delta_time =
    function()
        HB_GAUGE.init_delta_time()

        if HB_GAUGE.uptime_method ~=
            nil then

            local ok,
                now =
                pcall(function()
                    return
                        HB_GAUGE.uptime_method:
                            call(nil)
                end)

            now =
                tonumber(now)

            if ok
                and now ~= nil
                and now >= 0.0 then

                if HB_GAUGE.last_uptime ==
                    nil then

                    HB_GAUGE.last_uptime =
                        now

                    HB_GAUGE.delta_source =
                        "via.Application.get_UpTimeSecond"

                    HB_GAUGE.last_delta =
                        0.0

                    return 0.0
                end

                local dt =
                    now
                    - HB_GAUGE.last_uptime

                HB_GAUGE.last_uptime =
                    now

                if dt < 0.0 then
                    dt = 0.0
                elseif dt >
                    HB_GAUGE.max_decay_step then

                    HB_GAUGE.timing_clamps =
                        HB_GAUGE.timing_clamps + 1

                    dt =
                        HB_GAUGE.max_decay_step
                end

                HB_GAUGE.delta_source =
                    "via.Application.get_UpTimeSecond"

                HB_GAUGE.last_delta =
                    dt

                return dt
            end
        end

        local now =
            os.clock()

        local dt =
            now
            - (
                HB_GAUGE.fallback_clock
                or now
            )

        HB_GAUGE.fallback_clock =
            now

        if dt < 0.0 then
            dt = 0.0
        elseif dt >
            HB_GAUGE.max_decay_step then

            HB_GAUGE.timing_clamps =
                HB_GAUGE.timing_clamps + 1

            dt =
                HB_GAUGE.max_decay_step
        end

        HB_GAUGE.delta_source =
            "os.clock fallback"

        HB_GAUGE.last_delta =
            dt

        return dt
    end

HB_GAUGE.update_decay =
    function()
        local dt =
            HB_GAUGE.get_delta_time()

        if dt > 0.0 then
            -- WHITE always cools, whether the Scorcher rider is active or not.
            if HB_GAUGE.value >
                0.0 then

                HB_GAUGE.value =
                    math.max(
                        0.0,
                        HB_GAUGE.value
                        - (
                            HB_GAUGE.decay_rate
                            * dt
                        )
                    )
            end

            -- BLUE is the activated Scorcher-rider lifetime. BLACK stays fixed.
            if HB_GAUGE.activation_active
                and HB_GAUGE.blue_value ~= nil then

                HB_GAUGE.blue_value =
                    math.max(
                        0.0,
                        HB_GAUGE.blue_value
                        - (
                            HB_GAUGE.blue_decay_rate
                            * dt
                        )
                    )

                if HB_GAUGE.blue_value <=
                    0.0 then

                    HB_GAUGE.deactivate(
                        "Blue bar expired"
                    )
                end
            end
        end

        -- This also initializes a newly detected Wide Gunlance to YELLOW at 0 Heat.
        HB_GAUGE.sync_heat_state(
            "White Heat decay/update"
        )
    end

HB_GAUGE.draw_marker =
    function(x, width, extra_height, color)
        local top =
            HB_GAUGE.display_top

        local height =
            HB_GAUGE.display_height

        draw.filled_rect(
            x - (width / 2),
            top - extra_height,
            width,
            height + extra_height * 2,
            color
        )
    end

HB_GAUGE.draw =
    function()
        if not cached_is_wide_gunlance then
            return
        end

        if draw == nil
            or draw.filled_rect ==
                nil then

            return
        end

        local left =
            HB_GAUGE.display_left

        local top =
            HB_GAUGE.display_top

        local width =
            HB_GAUGE.display_width

        local height =
            HB_GAUGE.display_height

        local border =
            HB_GAUGE.border

        -- Three 43-point Heat regions.
        draw.filled_rect(
            left,
            top,
            43,
            height,
            0xff00ffff
        )

        draw.filled_rect(
            left + 43,
            top,
            43,
            height,
            0xff006aff
        )

        draw.filled_rect(
            left + 86,
            top,
            43,
            height,
            0xff0016e4
        )

        -- Explicit black border drawn on top of the colored bar.
        draw.filled_rect(
            left - border,
            top - border,
            width + border * 2,
            border,
            0xFF000000
        )

        draw.filled_rect(
            left - border,
            top + height,
            width + border * 2,
            border,
            0xFF000000
        )

        draw.filled_rect(
            left - border,
            top,
            border,
            height,
            0xFF000000
        )

        draw.filled_rect(
            left + width,
            top,
            border,
            height,
            0xFF000000
        )

        -- BLACK: locked activation tier. Draw it wider so its edges remain
        -- visible when BLUE begins directly on top of it.
        if HB_GAUGE.activation_active
            and HB_GAUGE.locked_value ~= nil then

            local black_offset =
                (
                    HB_GAUGE.locked_value
                    / HB_GAUGE.max
                )
                * width

            HB_GAUGE.draw_marker(
                left + black_offset,
                HB_GAUGE.black_marker_width,
                7,
                0xFF000000
            )
        end

        -- BLUE: remaining Heat Blade lifetime.
        if HB_GAUGE.activation_active
            and HB_GAUGE.blue_value ~= nil then

            local blue_offset =
                (
                    HB_GAUGE.blue_value
                    / HB_GAUGE.max
                )
                * width

            -- ABGR: light blue (RGB approximately 112, 208, 255).
            HB_GAUGE.draw_marker(
                left + blue_offset,
                HB_GAUGE.blue_marker_width,
                6,
                0xFFFFD070
            )
        end

        -- WHITE: current stored Heat, independently rebuilding/cooling.
        local white_offset =
            (
                HB_GAUGE.value
                / HB_GAUGE.max
            )
            * width

        HB_GAUGE.draw_marker(
            left + white_offset,
            HB_GAUGE.white_marker_width,
            5,
            0xFFFFFFFF
        )
    end

HB_GAUGE.add =
    function(kind, amount)
        if not cached_is_wide_gunlance then
            return
        end

        HB_GAUGE.value =
            math.min(
                HB_GAUGE.max,
                HB_GAUGE.value
                + amount
            )

        HB_GAUGE.last_kind =
            kind

        HB_GAUGE.last_gain =
            amount

        -- Shell Heat immediately updates passive Razor Sharp / lance MV tier.
        HB_GAUGE.sync_heat_state(
            "White Heat gain"
        )

        if kind == "REGULAR" then
            HB_GAUGE.regular_count =
                HB_GAUGE.regular_count + 1

        elseif kind == "CHARGED" then
            HB_GAUGE.charged_count =
                HB_GAUGE.charged_count + 1

        else
            HB_GAUGE.fullburst_count =
                HB_GAUGE.fullburst_count + 1
        end

        record(
            "GAUGE GAIN",
            "kind="
            .. tostring(kind)
            .. " | +"
            .. tostring(amount)
            .. " | white="
            .. string.format(
                "%.2f",
                HB_GAUGE.value
            )
            .. " | active="
            .. tostring(
                HB_GAUGE.activation_active
            )
        )
    end

HB_GAUGE.install_hook =
    function(type_def, method_name, param_count, callback)
        if type_def == nil then
            return false
        end

        local method =
            find_method(
                type_def,
                method_name,
                param_count
            )

        if method == nil then
            record(
                "GAUGE HOOK MISSING",
                tostring(method_name)
                .. "/"
                .. tostring(param_count)
            )

            return false
        end

        local ok,
            err =
            pcall(function()
                sdk.hook(
                    method,

                    function(args)
                        callback(args)
                    end,

                    function(retval)
                        return retval
                    end
                )
            end)

        if ok then
            HB_GAUGE.action_hooks_installed =
                HB_GAUGE.action_hooks_installed + 1
        else
            HB_GAUGE.last_error =
                tostring(err)

            record(
                "GAUGE HOOK FAILED",
                tostring(method_name)
                .. " | "
                .. tostring(err)
            )
        end

        return ok
    end

HB_GAUGE.install =
    function()
        local handling_td =
            sdk.find_type_definition(
                "app.cHunterWp07Handling"
            )

        if handling_td == nil then
            HB_GAUGE.last_error =
                "app.cHunterWp07Handling not found"

            return
        end

        ----------------------------------------------------
        -- REGULAR SHELL
        ----------------------------------------------------

        HB_GAUGE.regular_hook_ok =
            HB_GAUGE.install_hook(
                handling_td,
                "shootShell",
                1,
                function()
                    if cached_is_wide_gunlance then
                        HB_GAUGE.add(
                            "REGULAR",
                            HB_GAUGE.regular_gain
                        )
                    end
                end
            )

        ----------------------------------------------------
        -- CHARGED SHELL
        ----------------------------------------------------

        HB_GAUGE.charged_hook_ok =
            HB_GAUGE.install_hook(
                handling_td,
                "requestChargeShot",
                1,
                function()
                    if cached_is_wide_gunlance then
                        HB_GAUGE.add(
                            "CHARGED",
                            HB_GAUGE.charged_gain
                        )
                    end
                end
            )

        ----------------------------------------------------
        -- FULL BURST FAMILY CONTEXT
        ----------------------------------------------------

        HB_GAUGE.install_hook(
            handling_td,
            "requestFullBurst",
            0,
            function()
                HB_GAUGE.pending_fullburst =
                    "FULLBURST"
            end
        )

        HB_GAUGE.install_hook(
            handling_td,
            "requestJumpFullBurst",
            0,
            function()
                HB_GAUGE.pending_fullburst =
                    "FULLBURST"
            end
        )

        HB_GAUGE.install_hook(
            handling_td,
            "requestBulletFire",
            0,
            function()
                HB_GAUGE.pending_fullburst =
                    "BF_FULLBURST"
            end
        )

        HB_GAUGE.install_hook(
            handling_td,
            "requestBulletFireReload",
            0,
            function()
                HB_GAUGE.pending_fullburst =
                    "RBF_FULLBURST"
            end
        )

        HB_GAUGE.install_hook(
            handling_td,
            "setupFullBurst",
            1,
            function()
                if HB_GAUGE.pending_fullburst ==
                    "NONE" then

                    HB_GAUGE.active_fullburst =
                        "FULLBURST"
                else
                    HB_GAUGE.active_fullburst =
                        HB_GAUGE.pending_fullburst
                end

                HB_GAUGE.pending_fullburst =
                    "NONE"

                HB_GAUGE.fullburst_until =
                    frame + 120
            end
        )

        HB_GAUGE.install_hook(
            handling_td,
            "updateFullBurst",
            0,
            function()
                if HB_GAUGE.active_fullburst ~=
                    "NONE" then

                    HB_GAUGE.fullburst_until =
                        frame + 12
                end
            end
        )

        HB_GAUGE.install_hook(
            handling_td,
            "cancelFullBurst",
            0,
            function()
                HB_GAUGE.pending_fullburst =
                    "NONE"

                HB_GAUGE.active_fullburst =
                    "NONE"

                HB_GAUGE.fullburst_until =
                    -1
            end
        )

        ----------------------------------------------------
        -- FULL BURST SHELL
        ----------------------------------------------------

        HB_GAUGE.postshoot_hook_ok =
            HB_GAUGE.install_hook(
                handling_td,
                "onShell_PostShoot",
                1,
                function()
                    if not cached_is_wide_gunlance then
                        return
                    end

                    if HB_GAUGE.active_fullburst ==
                        "NONE" then

                        return
                    end

                    if frame >
                        HB_GAUGE.fullburst_until then

                        return
                    end

                    HB_GAUGE.add(
                        HB_GAUGE.active_fullburst,
                        HB_GAUGE.fullburst_gain
                    )
                end
            )

        ----------------------------------------------------
        -- WYVERN FIRE: activate / refresh Heat Blade
        ----------------------------------------------------

        HB_GAUGE.wyvern_hook_ok =
            HB_GAUGE.install_hook(
                handling_td,
                "shootRyuugekiShell",
                0,
                function()
                    HB_GAUGE.activate_from_white(
                        "Wyvern Fire"
                    )
                end
            )

        record(
            "GAUGE DIRECT READY",
            "regular="
            .. tostring(
                HB_GAUGE.regular_hook_ok
            )
            .. " | charged="
            .. tostring(
                HB_GAUGE.charged_hook_ok
            )
            .. " | postShoot="
            .. tostring(
                HB_GAUGE.postshoot_hook_ok
            )
            .. " | wyvern="
            .. tostring(
                HB_GAUGE.wyvern_hook_ok
            )
            .. " | totalHooks="
            .. tostring(
                HB_GAUGE.action_hooks_installed
            )
        )
    end

re.on_frame(function()
    if HB_GAUGE.active_fullburst ~=
        "NONE"
        and frame >
            HB_GAUGE.fullburst_until then

        HB_GAUGE.active_fullburst =
            "NONE"
    end

    HB_GAUGE.update_decay()
    HB_GAUGE.draw()
end)


------------------------------------------------------------
-- INSTALL
------------------------------------------------------------

reset_log()

record(
    "START",
    "Heat Blade V6.2 loaded"
)

-- Keep each install block in its own lexical scope. REFramework's Lua
-- runtime enforces the 200-local-variable limit per function/chunk; V3.9
-- crossed that limit because the damage-hook locals were still alive when
-- the Razor hook declared its own locals.

do
    --------------------------------------------------------
    -- HEAT BLADE DAMAGE
    --------------------------------------------------------

    local skill_td =
        sdk.find_type_definition(
            HUNTER_SKILL_TYPE
        )

    local damage_method =
        skill_td
        and skill_td:get_method(
            "calcSkillAdditionalDamage"
        )
        or nil

    if damage_method == nil then
        record(
            "HOOK FAILED",
            "calcSkillAdditionalDamage not found"
        )
    else
        local ok, err =
            pcall(function()
                sdk.hook(
                    damage_method,
                    pre_hook,
                    post_hook
                )
            end)

        record(
            ok
            and "HOOKED"
            or "HOOK FAILED",
            ok
            and "calcSkillAdditionalDamage"
            or tostring(err)
        )
    end
end

--------------------------------------------------------
-- NATIVE WIDE SHELL-TYPE OBSERVER
--------------------------------------------------------

install_shell_type_observer()

--------------------------------------------------------
-- NATIVE SCORCHER ARMOR CARRIER
--------------------------------------------------------

install_scorcher_carrier_hook()

do
    --------------------------------------------------------
    -- DIRECT RAZOR SHARP
    --------------------------------------------------------

    local handling_td =
        sdk.find_type_definition(
            HUNTER_HANDLING_TYPE
        )

    local consume_method =
        handling_td
        and handling_td:get_method(
            "consumeKireajiFromAttack"
        )
        or nil

    if consume_method == nil then
        record(
            "HOOK RAZOR FAILED",
            "consumeKireajiFromAttack not found"
        )
    else
        local hook_ok, hook_err =
            pcall(function()
                sdk.hook(
                    consume_method,
                    direct_razor_pre_hook,
                    direct_razor_post_hook
                )
            end)

        razor_consume_hook_installed =
            hook_ok

        record(
            hook_ok
            and "HOOKED DIRECT RAZOR"
            or "HOOK RAZOR FAILED",
            hook_ok
            and (
                HUNTER_HANDLING_TYPE ..
                ".consumeKireajiFromAttack"
            )
            or tostring(hook_err)
        )
    end
end

------------------------------------------------------------
-- PASSIVE MELEE MV HOOK
------------------------------------------------------------

HB_MELEE.install()

------------------------------------------------------------
-- HEAT GAUGE HOOKS
------------------------------------------------------------

HB_GAUGE.install()

------------------------------------------------------------
-- FRAME CACHE UPDATE / AUTO DATAPACK RESOLVE
------------------------------------------------------------

re.on_frame(function()
    frame =
        frame + 1

    if HB_GAUGE.stats_refresh_pending then
        HB_GAUGE.stats_refresh_pending =
            false

        refresh_cached_stats()
    end

    if frame %
        STAT_REFRESH_FRAMES ==
        0 then

        refresh_cached_stats()

        if not datapack_resolved
            and live_skill ~= nil then

            resolve_datapack()
        end

        if carrier_auto_scan_pending
            and live_skill ~= nil
            and cached_shell_type ~= nil
            and (
                carrier_rescan_not_before_frame == nil
                or frame >=
                    carrier_rescan_not_before_frame
            ) then

            if cached_is_wide_gunlance then
                if scan_and_plan_scorcher_carrier() then
                    carrier_auto_scan_pending =
                        false

                    carrier_rescan_not_before_frame =
                        nil
                end
            else
                carrier_auto_scan_pending =
                    false

                carrier_rescan_not_before_frame =
                    nil

                carrier_status =
                    "Heat Blade disabled: "
                    .. tostring(
                        cached_shell_name
                    )
            end
        end

        if cached_is_wide_gunlance then
            verify_scorcher_carrier()
        end
    end
end)

------------------------------------------------------------
-- RELEASE UI (READ-ONLY)
------------------------------------------------------------

local function heat_name()
    if heat_state == HEAT_YELLOW then
        return "YELLOW"
    end

    if heat_state == HEAT_ORANGE then
        return "ORANGE"
    end

    if heat_state == HEAT_RED then
        return "RED"
    end

    return "OFF"
end

local function rider_name()
    if not HB_GAUGE.activation_active
        or HB_GAUGE.locked_value == nil
        or HB_GAUGE.blue_value == nil
        or HB_GAUGE.blue_value <= 0.0 then

        return "OFF"
    end

    local state =
        HB_GAUGE.state_for_value(
            HB_GAUGE.locked_value
        )

    if state == HEAT_RED then
        return "RED"
    end

    if state == HEAT_ORANGE then
        return "ORANGE"
    end

    return "YELLOW"
end

local function release_error_text()
    if HB_GAUGE.last_error ~= nil then
        return "Gauge: " .. tostring(HB_GAUGE.last_error)
    end

    if HB_MELEE.last_error ~= nil then
        return "Melee MV: " .. tostring(HB_MELEE.last_error)
    end

    if last_error ~= nil then
        return tostring(last_error)
    end

    return nil
end

re.on_draw_ui(function()
    if not imgui.tree_node(
        "Heat Blade##heat_blade_release"
    ) then
        return
    end

    imgui.text("Heat Blade V6.5 Release")

    imgui.text(
        "Wide Gunlance: "
        .. tostring(cached_is_wide_gunlance)
        .. " | Shell type: "
        .. tostring(cached_shell_name)
    )

    imgui.separator()

    imgui.text(
        "Passive Heat: "
        .. heat_name()
        .. " | Razor Sharp Lv"
        .. tostring(heat_razor_level())
        .. " | Lance MV +"
        .. tostring(HB_MELEE.heat_bonus())
    )

    imgui.text(
        "White: "
        .. string.format("%.1f / %.0f", HB_GAUGE.value, HB_GAUGE.max)
        .. " | Rider: "
        .. rider_name()
    )

    if HB_GAUGE.activation_active then
        imgui.text(
            "Black: "
            .. string.format("%.1f", HB_GAUGE.locked_value or 0.0)
            .. " | Blue: "
            .. string.format("%.1f", HB_GAUGE.blue_value or 0.0)
        )
    end

    imgui.separator()

    imgui.text("Yellow: Razor Sharp Lv1 | +0 lance MV")
    imgui.text("Orange: Razor Sharp Lv2 | +4 lance MV | activated rider 8 MV +20 element")
    imgui.text("Red: Razor Sharp Lv3 | +8 lance MV | activated rider 16 MV +40 element")
    imgui.text("Wyvern Fire activates the Scorcher rider; passive bonuses follow current/locked Heat.")

    local err = release_error_text()
    if err ~= nil then
        imgui.separator()
        imgui.text("Error: " .. err)
    end

    imgui.tree_pop()
end)

log.info("[Heat Blade V6.5 Release] Loaded.")
