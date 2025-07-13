-- @version: 1.2

--// SCRIPT SETUP & FONT LOADING //--
Renderer.LoadFontFromFile("TahomaDebug23", "Tahoma", 12, true)

local menu_auto_update_enabled = Menu.Checker("Enable Auto-Update", true)

local a = Menu.Checker("--------------------------------------------", false)

--// MENU OPTIONS //--
local blockbot_enable = Menu.Checker("Blockbot Enable", false, false, true)
local blocking_mode_combo = Menu.Combo("Blocking Mode", 0, {"View Angles", "Front Block"})
local autojump_enable = Menu.Checker("Auto Jump", false)

-- Custom color settings for visuals
local circle_color = Menu.Checker("Circle Color", false, true)
local on_head_color = Menu.Checker("On Head Color", false, true)
local mode_indicator_color = Menu.Checker("Mode Indicator Color", false, true)

local a = Menu.Checker("--------------------------------------------", false)

local guiToggle = Menu.Checker("Show Team Damage Tracker", true)
local statsMode = Menu.Combo("Stats Mode", 0, {"Stats persist between rounds", "Stats reset each round"})

local a = Menu.Checker("--------------------------------------------", false)

local rs = Menu.Checker("Roll spin", false)
local rs_speed = Menu.Slider("Roll speed", 5, 1, 20)
local fp = Menu.Checker("Fake pitch", false, false, true)

local a = Menu.Checker("--------------------------------------------", false)

local spam_checkbox = Menu.Checker("Sharkhack spam", false)
local tt = Menu.Checker("Trash talk", false)

local a = Menu.Checker("--------------------------------------------", false)

local SCRIPT_URL = "https://github.com/hypnomacka/grif.lua/blob/main/grif.lua"
local SCRIPT_PATH = "C:\\plaguecheat.cc\\" .. Cheat.GetScriptName()
local UPDATE_INTERVAL = 3600




--// GLOBAL STATE VARIABLES //--
local blockEnemy = nil
local currentTarget = nil

-- Visual smoothing
local lastDrawnTeammatePos = nil
local INTERPOLATION_ALPHA = 0.2 -- Smoothing factor for visual indicators

-- Auto-jump state
local bot_has_active_jump_command = false

-- Acceleration prediction state
local prev_block_enemy_ref_for_accel = nil
local prev_target_pos_for_accel = nil
local prev_target_vel_for_accel = nil
local prev_actual_frame_time_for_accel_calc = 0.015625 -- Default reasonable frametime

-- ADAD (A-D-A-D strafing pattern) Detection State
local prev_lateral_offset_sign_for_adad = 0 -- Stores the sign of the target's lateral movement relative to us (-1 left, 0 center, 1 right)
local adad_active_timer = 0                 -- Timer to keep ADAD countermeasures active for a short duration
local last_lateral_change_time = 0          -- Timestamp of the last lateral direction change
local adad_rhythm_streak = 0                -- Counts consecutive rhythmic ADAD reversals

-- Animated Circle State
local animated_circle_phase = 0 -- Phase for the up/down animation of the circle

--// CONSTANTS //--

-- General
local MAX_PLAYER_SPEED = 250
local MAX_PREDICTION_FRAMETIME = 0.033 -- Cap prediction frametime to avoid issues with extreme lag spikes (approx 30 FPS)
local AUTOJUMP_TARGET_Z_VEL_THRESHOLD = 200 -- Minimum vertical speed of target to trigger autojump (UPDATED FROM 100 TO 200)
local MAX_CORRECTION_DISTANCE = 100 -- Define this constant for correction speed calculation

-- On-Head Blocking Mode
local ON_HEAD_PREDICTION_FRAMES = 10
local ON_HEAD_DEADZONE_HORIZONTAL = 1
local ON_HEAD_HEIGHT_OFFSET = 72         -- How far above the target's head we aim to be
local ON_HEAD_Z_THRESHOLD = 5            -- Minimum Z distance above target to be considered "on head"
local ON_HEAD_XY_TOLERANCE = 15
local ON_HEAD_CORRECTION_TIMESCALE_FRAMES = 0.5 -- How quickly to correct position (in frames)
local ON_HEAD_CORRECTION_GAIN = 15       -- Multiplier for correction speed

-- Front Block Mode (Aggressive blocking in front of the teammate)
local FRONT_BLOCK_DISTANCE = 35          -- How far in front of the teammate to position
local FRONT_BLOCK_HEIGHT_OFFSET = 0      -- Vertical offset for the block position
local FRONT_BLOCK_DEADZONE_HORIZONTAL = 5
local FRONT_BLOCK_PREDICTION_FRAMES = 4
local FRONT_BLOCK_CORRECTION_TIMESCALE_FRAMES = 0.15
local FRONT_BLOCK_CORRECTION_GAIN = 35
local FRONT_BLOCK_VELOCITY_THRESHOLD_FOR_DIRECTION = 50 -- Min speed for target to use their velocity dir for front block

-- View Angles Mode (Side-to-side blocking, with ADAD adaptation)
local VIEW_ANGLES_MAX_STRAFE_POWER_BASE = 1.0
local VIEW_ANGLES_MAX_STRAFE_POWER_ADAD = 1.0

local VIEW_ANGLES_PREDICTION_FRAMES_ACCEL_BASE_MIN = 1
local VIEW_ANGLES_PREDICTION_FRAMES_ACCEL_BASE_MAX = 4
local VIEW_ANGLES_PREDICTION_FRAMES_ACCEL_ADAD = 1

local VIEW_ANGLES_ACCEL_DAMPING_FACTOR = 0.85

local VIEW_ANGLES_LATERAL_OFFSET_DEADZONE_BASE = 0.2
local VIEW_ANGLES_LATERAL_OFFSET_DEADZONE_ADAD = 0.05

local VIEW_ANGLES_MIN_VALID_PREV_FRAME_TIME = 0.001

-- ADAD Detection Specific Constants
local ADAD_DETECTION_MIN_SPEED_XY = 70
local ADAD_COUNTER_DURATION_SECONDS = 0.3
local ADAD_MIN_LATERAL_OFFSET_FOR_SIGN = 0.1
local ADAD_RHYTHM_WINDOW_SECONDS = 0.15
local ADAD_MIN_RHYTHM_COUNT = 2

-- Animated Circle Visuals
local ANIMATED_CIRCLE_RADIUS = 30 -- Radius for the animated circle
local ANIMATED_CIRCLE_SPEED = 2.0 -- How fast the circle moves up and down
local ANIMATED_CIRCLE_HEIGHT_RANGE = 72 -- How much the circle moves up and down (e.g., player height)
local ANIMATED_CIRCLE_BASE_Z_OFFSET = 0 -- Base Z offset (e.g., from feet)

--// HELPER FUNCTIONS //--

local function fmod(a, b)
    return a - math.floor(a / b) * b
end

local function NormalizeYaw(yaw)
    local sign = 1
    if yaw < 0 then sign = -1 end
    return (fmod(math.abs(yaw) + 180, 360) - 180) * sign
end

local function NormalizeVector(vec)
    local magnitude = math.sqrt(vec.x^2 + vec.y^2 + vec.z^2)
    if magnitude > 1e-4 then -- Avoid division by zero or near-zero
        return Vector(vec.x / magnitude, vec.y / magnitude, vec.z / magnitude)
    else
        return Vector(0, 0, 0)
    end
end

local function CheckSameXY(pos1, pos2, tolerance)
    tolerance = tolerance or 32 -- Default tolerance if not provided
    return math.abs(pos1.x - pos2.x) <= tolerance and math.abs(pos1.y - pos2.y) <= tolerance
end

local function GetTeammateViewYaw(teammatePawn)
    if teammatePawn.m_angEyeAngles then
        return teammatePawn.m_angEyeAngles.y
    end
    -- Fallback to velocity direction if eye angles are not available
    local velocity = teammatePawn.m_vecAbsVelocity or Vector(0,0,0)
    if math.sqrt(velocity.x^2 + velocity.y^2) > 10 then -- Only if moving significantly
        return math.atan2(velocity.y, velocity.x) * (180 / math.pi)
    end
    return 0 -- Default yaw
end

local function IsOnScreen(screenPos)
    if not screenPos or (screenPos.x == 0 and screenPos.y == 0) then return false end
    local screenSize = Renderer.GetScreenSize()
    return screenPos.x >= 0 and screenPos.x <= screenSize.x and screenPos.y >= 0 and screenPos.y <= screenSize.y
end

local function IsTeammateValid(teammatePawn)
    if not teammatePawn or not teammatePawn.m_pGameSceneNode then return false end
    
    local health = teammatePawn.m_iHealth or 0
    if health <= 0 then return false end
    
    if teammatePawn.m_lifeState and teammatePawn.m_lifeState ~= 0 then -- LIFE_ALIVE is 0
        return false
    end
    return true
end

local function GetLocalPlayerPawn()
    local highestIndex = Entities.GetHighestEntityIndex() or 0
    for i = 1, highestIndex do
        local entity = Entities.GetEntityFromIndex(i)
        if entity and entity.m_bIsLocalPlayerController then
            return entity.m_hPawn
        end
    end
    return nil
end

local function GetLocalPlayerPing() 
    local highest_entity_index = Entities.GetHighestEntityIndex() or 0
    for i = 1, highest_entity_index do
        local entity = Entities.GetEntityFromIndex(i)
        if entity and entity.m_bIsLocalPlayerController then
            return entity.m_iPing or 0
        end
    end
    return 0
end

local function FindBlockTeammate()
    local localPlayerControllerPawn = GetLocalPlayerPawn()
    if not localPlayerControllerPawn or not localPlayerControllerPawn.m_pGameSceneNode then
        blockEnemy = nil; currentTarget = nil
        prev_lateral_offset_sign_for_adad = 0; adad_active_timer = 0
        last_lateral_change_time = 0; adad_rhythm_streak = 0
        return
    end

    local localPlayerOrigin = localPlayerControllerPawn.m_pGameSceneNode.m_vecAbsOrigin
    local localPlayerTeam = localPlayerControllerPawn.m_iTeamNum

    -- Target stickiness: if current target is still valid and relatively close, keep them.
    if currentTarget and IsTeammateValid(currentTarget) then
        if currentTarget.m_pGameSceneNode then -- Ensure scene node exists before accessing origin
             if localPlayerOrigin:DistTo(currentTarget.m_pGameSceneNode.m_vecAbsOrigin) < 1000 then
                blockEnemy = currentTarget
                return
             end
        end
    end
    
    -- Reset current target and search for a new one
    currentTarget = nil
    local closestDistance = math.huge
    local bestTeammatePawn = nil
    local highestIndex = Entities.GetHighestEntityIndex() or 0

    for i = 1, highestIndex do
        local entity = Entities.GetEntityFromIndex(i)
        if entity and entity.m_bIsLocalPlayerController ~= nil and not entity.m_bIsLocalPlayerController and entity.m_hPawn then
            local potentialTeammatePawn = entity.m_hPawn
            if potentialTeammatePawn and potentialTeammatePawn.m_iTeamNum == localPlayerTeam and potentialTeammatePawn ~= localPlayerControllerPawn then
                if IsTeammateValid(potentialTeammatePawn) and potentialTeammatePawn.m_pGameSceneNode then
                    local teammateOrigin = potentialTeammatePawn.m_pGameSceneNode.m_vecAbsOrigin
                    local distanceToTeammate = localPlayerOrigin:DistTo(teammateOrigin)
                    
                    -- Consider a teammate if they are close enough and closer than the current best
                    if distanceToTeammate > 1 and distanceToTeammate < 800 and distanceToTeammate < closestDistance then
                        closestDistance = distanceToTeammate
                        bestTeammatePawn = potentialTeammatePawn
                    end
                end
            end
        end
    end

    blockEnemy = bestTeammatePawn
    currentTarget = bestTeammatePawn -- Set for stickiness next frame

    if not blockEnemy then -- If no target found, reset ADAD state
        prev_lateral_offset_sign_for_adad = 0
        adad_active_timer = 0
        last_lateral_change_time = 0; adad_rhythm_streak = 0
    end
end

--// CORE BLOCKBOT LOGIC //--
local function BlockbotLogic(cmd)
    if not cmd then return end

    local localPlayerPawn = GetLocalPlayerPawn()
    local local_ping = GetLocalPlayerPing()

    -- Convert ping to seconds for prediction offset
    local ping_offset_seconds = local_ping / 1000.0

    -- Calculate actual frametime for prediction, with a safe default
    local actualFrameTime = Globals.GetFrameTime() or 0.015625
    if actualFrameTime <= 0 then actualFrameTime = 0.015625 end -- Ensure positive frametime
    local predictionFrameTime = math.min(actualFrameTime, MAX_PREDICTION_FRAMETIME) -- Cap frametime for prediction

    -- Handle local player state (on ground, jump commands)
    local is_on_ground_this_frame = true
    if localPlayerPawn and localPlayerPawn.m_pGameSceneNode then
        if localPlayerPawn.m_fFlags ~= nil then
            is_on_ground_this_frame = bit.band(localPlayerPawn.m_fFlags, 1) ~= 0 -- FL_ONGROUND
        end
        -- If a jump was commanded and we are now on ground, release jump key
        if bot_has_active_jump_command and is_on_ground_this_frame then
            CVar.ExecuteClientCmd("-jump")
            bot_has_active_jump_command = false
        end
    else
        -- Invalid local player, reset jump state and exit
        if bot_has_active_jump_command then CVar.ExecuteClientCmd("-jump"); bot_has_active_jump_command = false end
        blockEnemy = nil; currentTarget = nil
        prev_lateral_offset_sign_for_adad = 0; adad_active_timer = 0
        last_lateral_change_time = 0; adad_rhythm_streak = 0
        return
    end

    -- Check if blockbot is enabled and key is pressed
    if not blockbot_enable:GetBool() or not blockbot_enable:IsDown() then
        if bot_has_active_jump_command then CVar.ExecuteClientCmd("-jump"); bot_has_active_jump_command = false end
        blockEnemy = nil; currentTarget = nil
        prev_lateral_offset_sign_for_adad = 0; adad_active_timer = 0
        last_lateral_change_time = 0; adad_rhythm_streak = 0
        return
    end

    if not Globals.IsConnected() then return end -- Not in a game

    FindBlockTeammate() -- Find or update the teammate to block

    -- Initialize acceleration variables
    local accel_x, accel_y = 0, 0

    -- Validate block target
    if not blockEnemy or not blockEnemy.m_pGameSceneNode or not IsTeammateValid(blockEnemy) then
        if bot_has_active_jump_command then CVar.ExecuteClientCmd("-jump"); bot_has_active_jump_command = false end
        blockEnemy = nil; currentTarget = nil;
        -- Reset acceleration prediction state
        prev_block_enemy_ref_for_accel = nil
        prev_target_pos_for_accel = nil
        prev_target_vel_for_accel = nil
        -- Reset ADAD state
        prev_lateral_offset_sign_for_adad = 0
        adad_active_timer = 0
        last_lateral_change_time = 0; adad_rhythm_streak = 0
        return
    end

    -- Get teammate's ping and convert to seconds for prediction offset
    local teammate_ping = blockEnemy.m_iPing or 0
    local teammate_ping_offset_seconds = teammate_ping / 1000.0

    -- Get positions and velocities
    local localPos = localPlayerPawn.m_pGameSceneNode.m_vecAbsOrigin
    local teammatePos = blockEnemy.m_pGameSceneNode.m_vecAbsOrigin
    local teammateVel = blockEnemy.m_vecAbsVelocity or Vector(0,0,0)
    local teammateSpeedXY = math.sqrt(teammateVel.x^2 + teammateVel.y^2)
    
    -- Calculate target's acceleration
    if prev_block_enemy_ref_for_accel ~= blockEnemy or not prev_target_pos_for_accel or not prev_target_vel_for_accel then
        -- New target or first time, initialize previous state
        prev_target_pos_for_accel = Vector(teammatePos.x, teammatePos.y, teammatePos.z)
        prev_target_vel_for_accel = Vector(teammateVel.x, teammateVel.y, teammateVel.z)
        prev_actual_frame_time_for_accel_calc = actualFrameTime 
        prev_block_enemy_ref_for_accel = blockEnemy
    else
        -- Calculate acceleration based on change in velocity over time
        if prev_actual_frame_time_for_accel_calc > VIEW_ANGLES_MIN_VALID_PREV_FRAME_TIME then
            local delta_vx = teammateVel.x - prev_target_vel_for_accel.x
            local delta_vy = teammateVel.y - prev_target_vel_for_accel.y
            accel_x = delta_vx / prev_actual_frame_time_for_accel_calc
            accel_y = delta_vy / prev_actual_frame_time_for_accel_calc
            
            -- Apply damping to smooth out acceleration values
            accel_x = accel_x * VIEW_ANGLES_ACCEL_DAMPING_FACTOR
            accel_y = accel_y * VIEW_ANGLES_ACCEL_DAMPING_FACTOR
        end
        -- Update previous state for next frame's calculation
        prev_target_pos_for_accel = Vector(teammatePos.x, teammatePos.y, teammatePos.z)
        prev_target_vel_for_accel = Vector(teammateVel.x, teammateVel.y, teammateVel.z)
        prev_actual_frame_time_for_accel_calc = actualFrameTime
    end
    
    -- Check if local player is on the target's head
    local isOnHead = (localPos.z - teammatePos.z) > ON_HEAD_Z_THRESHOLD and 
                     CheckSameXY(localPos, teammatePos, ON_HEAD_XY_TOLERANCE)

    -- Auto-jump logic: if enabled, not on head, target is jumping, and we are on ground
    if autojump_enable:GetBool() and 
       not isOnHead and 
       math.abs(teammateVel.z) > AUTOJUMP_TARGET_Z_VEL_THRESHOLD and 
       is_on_ground_this_frame and 
       not bot_has_active_jump_command then
        CVar.ExecuteClientCmd("+jump")
        bot_has_active_jump_command = true
    end

    -- Decrement ADAD active timer
    if adad_active_timer > 0 then
        adad_active_timer = adad_active_timer - actualFrameTime
        if adad_active_timer < 0 then adad_active_timer = 0 end
    end
    local is_adad_currently_active = adad_active_timer > 0

    --// MOVEMENT LOGIC BRANCH: ON-HEAD OR GROUND //--
    if isOnHead then
        local predFrames = ON_HEAD_PREDICTION_FRAMES
        -- Add both local and teammate ping to prediction time
        local total_pred_time = (predictionFrameTime * predFrames) + ping_offset_seconds + teammate_ping_offset_seconds

        local predictedTeammatePos = Vector(
            teammatePos.x + teammateVel.x * total_pred_time, 
            teammatePos.y + teammateVel.y * total_pred_time, 
            teammatePos.z + teammateVel.z * total_pred_time
        )

        -- Target position: center of the head (X, Y of predicted teammate origin, Z at head height)
        local targetPos = Vector(predictedTeammatePos.x, predictedTeammatePos.y, predictedTeammatePos.z + ON_HEAD_HEIGHT_OFFSET)
        
        -- Calculate needed movement relative to local player (only XY for ground movement)
        local neededMovement = Vector(targetPos.x - localPos.x, targetPos.y - localPos.y, 0)

        local finalForwardMove = 0.0
        local finalLeftMove = 0.0

        local horizontalDistanceToTarget = math.sqrt(neededMovement.x^2 + neededMovement.y^2)

        -- Apply movement only if outside the deadzone
        if horizontalDistanceToTarget > ON_HEAD_DEADZONE_HORIZONTAL then
            -- Normalize the needed movement to get a direction vector using our custom function
            local normalizedNeededMovement = NormalizeVector(neededMovement)

            local ourViewRadians = math.rad(cmd.m_angViewAngles.y)
            local cos_yaw = math.cos(ourViewRadians)
            local sin_yaw = math.sin(ourViewRadians)

            -- Calculate correction speed based on distance error
            local correctionSpeedFactor = math.min(horizontalDistanceToTarget / MAX_CORRECTION_DISTANCE, 1.0)
            local desiredTotalSpeed = teammateSpeedXY + (MAX_PLAYER_SPEED * correctionSpeedFactor)

            -- Clamp desired total speed to MAX_PLAYER_SPEED
            desiredTotalSpeed = math.min(desiredTotalSpeed, MAX_PLAYER_SPEED)

            -- Calculate movement scale based on desired total speed
            local movementScale = 0
            if MAX_PLAYER_SPEED > 1e-5 then
                movementScale = desiredTotalSpeed / MAX_PLAYER_SPEED
            end

            -- Convert normalizedNeededMovement to local player's forward/left axes
            -- And apply scaled speed
            finalForwardMove = (normalizedNeededMovement.x * cos_yaw + normalizedNeededMovement.y * sin_yaw) * movementScale
            finalLeftMove = (-normalizedNeededMovement.x * sin_yaw + normalizedNeededMovement.y * cos_yaw) * movementScale

            -- Clamp to -1.0 to 1.0 (full movement) - this is still important for safety
            finalForwardMove = math.max(-1.0, math.min(1.0, finalForwardMove))
            finalLeftMove = math.max(-1.0, math.min(1.0, finalLeftMove))
        end
        -- If within deadzone, finalForwardMove and finalLeftMove remain 0.0, effectively quick stopping.

        cmd.m_flForwardMove = finalForwardMove
        cmd.m_flLeftMove = finalLeftMove
    else -- GROUND LOGIC (View Angles or Front Block)
        local selectedMode = blocking_mode_combo:GetInt()

        if selectedMode == 0 then -- View Angles Mode
            cmd.m_flLeftMove = 0.0
            
            -- Adaptive Prediction: Adjust prediction frames based on target speed (when not in ADAD mode)
            local speed_factor = math.max(0, math.min(1, teammateSpeedXY / MAX_PLAYER_SPEED)) -- Normalize speed 0-1
            local dynamic_pred_frames_base = VIEW_ANGLES_PREDICTION_FRAMES_ACCEL_BASE_MIN + 
                                             (VIEW_ANGLES_PREDICTION_FRAMES_ACCEL_BASE_MAX - VIEW_ANGLES_PREDICTION_FRAMES_ACCEL_BASE_MIN) * speed_factor
            
            local current_prediction_frames_accel = dynamic_pred_frames_base
            if is_adad_currently_active then
                current_prediction_frames_accel = VIEW_ANGLES_PREDICTION_FRAMES_ACCEL_ADAD -- Override with ADAD specific short prediction
            end
            
            -- Calculate predicted target position using velocity and acceleration
            -- Add both local and teammate ping to prediction time
            local pred_time_seconds = (predictionFrameTime * current_prediction_frames_accel) + ping_offset_seconds + teammate_ping_offset_seconds
            
            local predicted_x = teammatePos.x + (teammateVel.x * pred_time_seconds) + (0.5 * accel_x * pred_time_seconds^2)
            local predicted_y = teammatePos.y + (teammateVel.y * pred_time_seconds) + (0.5 * accel_y * pred_time_seconds^2)
            local targetPosForLateralCalc = Vector(predicted_x, predicted_y, teammatePos.z)
            
            -- Calculate lateral offset: how far left/right the target is relative to our facing direction
            local vectorToTarget = Vector(targetPosForLateralCalc.x - localPos.x, targetPosForLateralCalc.y - localPos.y, 0)
            local currentYawRad = math.rad(cmd.m_angViewAngles.y)
            local localRightVectorX = math.sin(currentYawRad)
            local localRightVectorY = -math.cos(currentYawRad)
            local lateralOffset = vectorToTarget.x * localRightVectorX + vectorToTarget.y * localRightVectorY

            -- ADAD Detection Logic: Check for reversals in lateral movement
            local current_lateral_offset_sign = 0
            if math.abs(lateralOffset) > ADAD_MIN_LATERAL_OFFSET_FOR_SIGN then
                 current_lateral_offset_sign = lateralOffset > 0 and 1 or -1 -- 1 for right, -1 for left
            end

            local current_time = Globals.GetCurrentTime() or 0

            if teammateSpeedXY > ADAD_DETECTION_MIN_SPEED_XY and
               current_lateral_offset_sign ~= 0 and
               prev_lateral_offset_sign_for_adad ~= 0 and
               current_lateral_offset_sign ~= prev_lateral_offset_sign_for_adad then -- Sign must have changed (reversal)
                
                local time_since_last_change = current_time - last_lateral_change_time
                if time_since_last_change > 0 and time_since_last_change <= ADAD_RHYTHM_WINDOW_SECONDS then
                    adad_rhythm_streak = adad_rhythm_streak + 1
                else
                    adad_rhythm_streak = 1 -- Reset streak if rhythm is broken or first reversal
                end
                last_lateral_change_time = current_time -- Update last change time

                if adad_rhythm_streak >= ADAD_MIN_RHYTHM_COUNT then
                    adad_active_timer = ADAD_COUNTER_DURATION_SECONDS -- Activate/Refresh ADAD countermeasures
                    is_adad_currently_active = true                   -- Update for this frame's logic
                end
            else
                -- If no reversal or conditions not met, reset streak
                adad_rhythm_streak = 0
                last_lateral_change_time = current_time -- Keep updating for future checks
            end
            prev_lateral_offset_sign_for_adad = current_lateral_offset_sign -- Store for next frame's comparison

            -- Apply Dynamic Deadzone and Strafe Power based on ADAD state
            local effective_deadzone = VIEW_ANGLES_LATERAL_OFFSET_DEADZONE_BASE
            local effective_strafe_power = VIEW_ANGLES_MAX_STRAFE_POWER_BASE
            if is_adad_currently_active then
                effective_deadzone = VIEW_ANGLES_LATERAL_OFFSET_DEADZONE_ADAD
                effective_strafe_power = VIEW_ANGLES_MAX_STRAFE_POWER_ADAD
            end
            
            -- Apply strafe movement if outside the deadzone
            if math.abs(lateralOffset) > effective_deadzone then
                if lateralOffset > 0 then 
                    cmd.m_flLeftMove = -effective_strafe_power -- Target is to our right, so we move left
                else 
                    cmd.m_flLeftMove = effective_strafe_power  -- Target is to our left, so we move right
                end
            end

        elseif selectedMode == 1 then -- Front Block Mode
            -- Reset ADAD state if switching out of View Angles mode
            prev_lateral_offset_sign_for_adad = 0 
            adad_active_timer = 0
            last_lateral_change_time = 0; adad_rhythm_streak = 0
            is_adad_currently_active = false

            local predFramesFB = FRONT_BLOCK_PREDICTION_FRAMES
            -- Add both local and teammate ping to prediction time
            local total_pred_time_fb = (predictionFrameTime * predFramesFB) + ping_offset_seconds + teammate_ping_offset_seconds

            local predTargetPosFB = Vector(
                teammatePos.x + teammateVel.x * total_pred_time_fb,
                teammatePos.y + teammateVel.y * total_pred_time_fb,
                teammatePos.z
            )
            
            local targetForwardAngleDegreesFB
            if teammateSpeedXY > FRONT_BLOCK_VELOCITY_THRESHOLD_FOR_DIRECTION and (teammateVel.x ~= 0 or teammateVel.y ~= 0) then
                targetForwardAngleDegreesFB = math.atan2(teammateVel.y, teammateVel.x) * (180 / math.pi) -- Use velocity direction
            else
                targetForwardAngleDegreesFB = GetTeammateViewYaw(blockEnemy) -- Use teammate's view yaw
            end
            
            local angleRadiansFB = math.rad(targetForwardAngleDegreesFB)
            local blockPositionFB = Vector(
                predTargetPosFB.x + math.cos(angleRadiansFB) * FRONT_BLOCK_DISTANCE, 
                predTargetPosFB.y + math.sin(angleRadiansFB) * FRONT_BLOCK_DISTANCE, 
                predTargetPosFB.z + FRONT_BLOCK_HEIGHT_OFFSET
            )
            
            local neededMoveFB = Vector(blockPositionFB.x - localPos.x, blockPositionFB.y - localPos.y, 0)
            local distToTargetXY_FB = math.sqrt(neededMoveFB.x^2 + neededMoveFB.y^2)
            
            local fwdMoveFB, leftMoveFB = 0.0, 0.0
            if distToTargetXY_FB > FRONT_BLOCK_DEADZONE_HORIZONTAL then
                local corrTimeFB = predictionFrameTime * math.max(0.001, FRONT_BLOCK_CORRECTION_TIMESCALE_FRAMES)
                if corrTimeFB <= 1e-5 then corrTimeFB = 1e-5 end
                
                local speedGapCloseFB = (distToTargetXY_FB / corrTimeFB) * FRONT_BLOCK_CORRECTION_GAIN
                local desiredSpeedFB = math.min(teammateSpeedXY + speedGapCloseFB, MAX_PLAYER_SPEED)
                
                local normMoveFB = NormalizeVector(neededMoveFB)
                local viewRadFB = math.rad(cmd.m_angViewAngles.y)
                local cosY_fb, sinY_fb = math.cos(viewRadFB), math.sin(viewRadFB)
                
                local moveScaleFB = 0
                if MAX_PLAYER_SPEED > 0.001 then moveScaleFB = desiredSpeedFB / MAX_PLAYER_SPEED end
                
                fwdMoveFB = (normMoveFB.x * cosY_fb + normMoveFB.y * sinY_fb) * moveScaleFB
                leftMoveFB = (-normMoveFB.x * sinY_fb + normMoveFB.y * cosY_fb) * moveScaleFB
            end
            cmd.m_flForwardMove = math.max(-1, math.min(1, fwdMoveFB))
            cmd.m_flLeftMove = math.max(-1, math.min(1, leftMoveFB))
        end
    end
end

--// VISUAL INDICATORS //--
local function DrawPlayerIndicators()
    if not blockbot_enable:GetBool() or not blockbot_enable:IsDown() then return end
    if not blockEnemy or not blockEnemy.m_pGameSceneNode then return end

    local teammatePosRaw = blockEnemy.m_pGameSceneNode.m_vecAbsOrigin
    local teammateVel = blockEnemy.m_vecAbsVelocity or Vector(0,0,0)

    local actualFrameTime = Globals.GetFrameTime() or 0.015625
    if actualFrameTime <= 0 then actualFrameTime = 0.015625 end
    local predFrameTimeForVisuals = math.min(actualFrameTime, MAX_PREDICTION_FRAMETIME)
    
    local visualPredictionFrames = 4 -- How many frames ahead to predict for the visual indicator
    local predictedTeammateVisualPos = Vector(
        teammatePosRaw.x + teammateVel.x * predFrameTimeForVisuals * visualPredictionFrames, 
        teammatePosRaw.y + teammateVel.y * predFrameTimeForVisuals * visualPredictionFrames, 
        teammatePosRaw.z + teammateVel.z * predFrameTimeForVisuals * visualPredictionFrames
    )

    -- Interpolate visual position for smoothness
    local interpolatedPos
    if lastDrawnTeammatePos then
        interpolatedPos = Vector(
            lastDrawnTeammatePos.x + (predictedTeammateVisualPos.x - lastDrawnTeammatePos.x) * INTERPOLATION_ALPHA,
            lastDrawnTeammatePos.y + (predictedTeammateVisualPos.y - lastDrawnTeammatePos.y) * INTERPOLATION_ALPHA,
            lastDrawnTeammatePos.z + (predictedTeammateVisualPos.z - lastDrawnTeammatePos.z) * INTERPOLATION_ALPHA
        )
    else
        interpolatedPos = predictedTeammateVisualPos
    end
    lastDrawnTeammatePos = interpolatedPos -- Store for next frame's interpolation

    -- Get screen positions for drawing
    local screenPosTargetFeet = Renderer.WorldToScreen(interpolatedPos)

    if not IsOnScreen(screenPosTargetFeet) then return end

    -- Define colors based on menu settings or defaults
    local baseCircleColor = circle_color:GetBool() and circle_color:GetColor() or Color(0, 255, 255, 255) -- Cyan
    local onHeadCircleColor = on_head_color:GetBool() and on_head_color:GetColor() or Color(255, 255, 0, 255) -- Yellow
    
    local localPlayerPawnForDraw = GetLocalPlayerPawn()
    if not localPlayerPawnForDraw or not localPlayerPawnForDraw.m_pGameSceneNode then return end
    
    local localPlayerPosForDraw = localPlayerPawnForDraw.m_pGameSceneNode.m_vecAbsOrigin
    local currentTargetPosForDraw = blockEnemy.m_pGameSceneNode.m_vecAbsOrigin
    
    local isPlayerOnHeadForDraw = (localPlayerPosForDraw.z - currentTargetPosForDraw.z) > ON_HEAD_Z_THRESHOLD and 
                                  CheckSameXY(localPlayerPosForDraw, currentTargetPosForDraw, ON_HEAD_XY_TOLERANCE)

    -- Draw main circle around target
    if IsOnScreen(screenPosTargetFeet) then
        if isPlayerOnHeadForDraw then
            Renderer.DrawCircleGradient3D(interpolatedPos, onHeadCircleColor, Color(onHeadCircleColor.r, onHeadCircleColor.g, onHeadCircleColor.b, 100), 25)
            Renderer.DrawCircle3D(interpolatedPos, onHeadCircleColor, 35)
        else
            Renderer.DrawCircleGradient3D(interpolatedPos, baseCircleColor, Color(baseCircleColor.r, baseCircleColor.g, baseCircleColor.b, 50), 20)
            
            -- Update animated circle phase
            animated_circle_phase = animated_circle_phase + (Globals.GetFrameTime() * ANIMATED_CIRCLE_SPEED)
            if animated_circle_phase > math.pi * 2 then
                animated_circle_phase = animated_circle_phase - (math.pi * 2)
            end

            -- Calculate Z offset for the animated circle (moves from feet to head)
            local z_offset_animated_circle = ANIMATED_CIRCLE_BASE_Z_OFFSET + 
                                             (math.sin(animated_circle_phase) * 0.5 + 0.5) * ANIMATED_CIRCLE_HEIGHT_RANGE

            local animatedCirclePos = Vector(interpolatedPos.x, interpolatedPos.y, interpolatedPos.z + z_offset_animated_circle)

            -- Draw animated circle
            Renderer.DrawCircle3D(animatedCirclePos, baseCircleColor, ANIMATED_CIRCLE_RADIUS)
        end
    end

    -- Draw line from local player to target (if not on head)
    if not isPlayerOnHeadForDraw then
        local localPlayerScreenPos = Renderer.WorldToScreen(localPlayerPosForDraw)
        if IsOnScreen(localPlayerScreenPos) and IsOnScreen(screenPosTargetFeet) then
            Renderer.DrawLine(localPlayerScreenPos, screenPosTargetFeet, Color(baseCircleColor.r, baseCircleColor.g, baseCircleColor.b, 100), 2)
        end
    end
end

local teamDamageData = {}
local teamDamageNames = {}
local teamKillData = {}
local teamKillNames = {}
local teamDamageCount = 0
local teamKillCount = 0
local resetOnRoundStart = false

-- Toast notification system 
local toastQueue = {}
local currentToast = nil
local toastStartTime = 0
local toastDuration = 4.0
local warnedPlayers = {} -- Track who we've already warned about

-- Ban overlay system
local banOverlay = nil
local banOverlayStartTime = 0
local banOverlayDuration = 3.0
local bannedPlayers = {} -- Track who we've already shown ban overlay for

local windowPos = {x = 100, y = 100}
local windowSize = {width = 320, height = 200}
local isDragging = false
local dragOffset = {x = 0, y = 0}

Renderer.LoadFontFromFile("CompactFont", "Segoe UI", 10, true)
Renderer.LoadFontFromFile("TitleFont", "Segoe UI", 11, true)
Renderer.LoadFontFromFile("ToastFont", "Segoe UI", 11, true)
Renderer.LoadFontFromFile("BanFont", "Arial", 24, true)
Renderer.LoadFontFromFile("BanSubFont", "Arial", 16, true)

-- Colors + Toast colors + Ban overlay colors
local colors = {
    bg = Color(8, 8, 12, 250),
    border = Color(35, 35, 40, 255),
    text = Color(220, 220, 225, 255),
    subtext = Color(140, 140, 150, 255),
    barBg = Color(25, 25, 30, 255),
    barFill = Color(85, 85, 95, 255),
    accent = Color(60, 60, 70, 255),
    -- Toast colors
    toastBg = Color(20, 20, 25, 240),
    toastBorder = Color(200, 100, 100, 255),
    toastText = Color(255, 255, 255, 255),
    toastWarning = Color(255, 150, 150, 255),
    -- Ban overlay colors
    banOverlayBg = Color(180, 0, 0, 200),
    banOverlayBorder = Color(255, 50, 50, 255),
    banText = Color(255, 255, 255, 255),
    banSubText = Color(255, 200, 200, 255)
}

local function UpdateMenuSettings()
    resetOnRoundStart = (statsMode:GetInt() == 1)
end

local function ResetStats()
    teamDamageData = {}
    teamDamageNames = {}
    teamKillData = {}
    teamKillNames = {}
    teamDamageCount = 0
    teamKillCount = 0
    warnedPlayers = {}
    bannedPlayers = {}
end

local function AddToast(message)
    table.insert(toastQueue, message)
end

local function ShowBanOverlay(playerName, reason)
    banOverlay = {
        player = playerName,
        reason = reason
    }
    banOverlayStartTime = Globals.GetCurrentTime()
    print("[BAN OVERLAY] " .. playerName .. " - " .. reason)
end

local function UpdateToasts()
    local currentTime = Globals.GetCurrentTime()
    
    -- Check if current toast expired
    if currentToast and (currentTime - toastStartTime) > toastDuration then
        currentToast = nil
    end
    
    -- Show next toast if available and no current toast
    if not currentToast and #toastQueue > 0 then
        currentToast = toastQueue[1]
        table.remove(toastQueue, 1)
        toastStartTime = currentTime
    end
end

local function UpdateBanOverlay()
    local currentTime = Globals.GetCurrentTime()
    
    -- Check if ban overlay expired
    if banOverlay and (currentTime - banOverlayStartTime) > banOverlayDuration then
        banOverlay = nil
    end
end

local function DrawBanOverlay()
    if not banOverlay then return end
    
    local screenSize = Renderer.GetScreenSize()
    local overlayWidth = 300
    local overlayHeight = 150
    local overlayX = (screenSize.x - overlayWidth) / 2
    local overlayY = (screenSize.y - overlayHeight) / 2
    
    local currentTime = Globals.GetCurrentTime()
    local timeElapsed = currentTime - banOverlayStartTime
    local alpha = 1.0
    
    -- Fade out in last 0.5 seconds
    if timeElapsed > (banOverlayDuration - 0.5) then
        alpha = (banOverlayDuration - timeElapsed) / 0.5
    end
    
    -- Pulsing effect for first 2 seconds
    local pulseAlpha = alpha
    if timeElapsed < 2.0 then
        pulseAlpha = alpha * (0.8 + 0.2 * math.sin(timeElapsed * 8))
    end
    
    -- Main overlay background
    local bgColor = Color(colors.banOverlayBg.r, colors.banOverlayBg.g, colors.banOverlayBg.b, colors.banOverlayBg.a * pulseAlpha)
    Renderer.DrawRectFilled(
        Vector2D(overlayX, overlayY),
        Vector2D(overlayX + overlayWidth, overlayY + overlayHeight),
        bgColor,
        10
    )
    
    -- Glowing border effect
    local borderColor = Color(colors.banOverlayBorder.r, colors.banOverlayBorder.g, colors.banOverlayBorder.b, colors.banOverlayBorder.a * pulseAlpha)
    for i = 1, 3 do
        Renderer.DrawRect(
            Vector2D(overlayX - i, overlayY - i),
            Vector2D(overlayX + overlayWidth + i, overlayY + overlayHeight + i),
            Color(borderColor.r, borderColor.g, borderColor.b, borderColor.a / (i * 2)),
            10
        )
    end
    
    -- "BANNED" text
    local banTextColor = Color(colors.banText.r, colors.banText.g, colors.banText.b, colors.banText.a * alpha)
	Renderer.DrawText("BanFont", "Successfully Banned",
                 Vector2D(overlayX + overlayWidth/2, overlayY + 30), 
                 true, true, banTextColor)
    
    -- Player name
    local playerText = banOverlay.player
    if string.len(playerText) > 20 then
        playerText = string.sub(playerText, 1, 20) .. "..."
    end
    Renderer.DrawText("BanSubFont", playerText, 
                     Vector2D(overlayX + overlayWidth/2, overlayY + 70), 
                     true, true, banTextColor)
    
    -- Reason
    local subTextColor = Color(colors.banSubText.r, colors.banSubText.g, colors.banSubText.b, colors.banSubText.a * alpha)
    Renderer.DrawText("CompactFont", banOverlay.reason, 
                     Vector2D(overlayX + overlayWidth/2, overlayY + 100), 
                     true, false, subTextColor)
    
end

local function DrawToast()
    if not currentToast then return end
    
    local screenSize = Renderer.GetScreenSize()
    local toastWidth = 280
    local toastHeight = 50
    local toastX = screenSize.x - toastWidth - 20
    local toastY = screenSize.y - toastHeight - 80
    
    local currentTime = Globals.GetCurrentTime()
    local timeLeft = toastDuration - (currentTime - toastStartTime)
    local alpha = math.min(1.0, timeLeft / 0.5)
    
    -- Toast background
    local bgColor = Color(colors.toastBg.r, colors.toastBg.g, colors.toastBg.b, colors.toastBg.a * alpha)
    Renderer.DrawRectFilled(
        Vector2D(toastX, toastY),
        Vector2D(toastX + toastWidth, toastY + toastHeight),
        bgColor,
        6
    )
    
    -- Warning border
    local borderColor = Color(colors.toastBorder.r, colors.toastBorder.g, colors.toastBorder.b, colors.toastBorder.a * alpha)
    Renderer.DrawRect(
        Vector2D(toastX, toastY),
        Vector2D(toastX + toastWidth, toastY + toastHeight),
        borderColor,
        6
    )
    
    -- Warning icon/text
    local warningColor = Color(colors.toastWarning.r, colors.toastWarning.g, colors.toastWarning.b, colors.toastWarning.a * alpha)
    Renderer.DrawText("ToastFont", "BAN WARNING", 
                     Vector2D(toastX + 15, toastY + 8), 
                     false, true, warningColor)
    
    -- Main message
    local textColor = Color(colors.toastText.r, colors.toastText.g, colors.toastText.b, colors.toastText.a * alpha)
    Renderer.DrawText("ToastFont", currentToast, 
                     Vector2D(toastX + 15, toastY + 25), 
                     false, false, textColor)
end

local function CheckBanWarnings()
    for i = 1, teamDamageCount do
        local playerName = teamDamageNames[i]
        local damage = teamDamageData[i]
        
        -- Check for ban (300+ damage)
        if damage >= 300 and not bannedPlayers[playerName] then
            ShowBanOverlay(playerName, "Team Damage: " .. damage .. "/300")
            bannedPlayers[playerName] = true
        end
        
        -- Check if player hit 200+ damage and we haven't warned about them yet
        if damage >= 200 and damage < 300 and not warnedPlayers[playerName] then
            local message = playerName .. " is close to getting banned! (" .. damage .. "/300)"
            AddToast(message)
            warnedPlayers[playerName] = true
        end
        
        -- Reset warning if they somehow get below 200
        if damage < 200 and warnedPlayers[playerName] then
            warnedPlayers[playerName] = nil
        end
    end
    
    -- Check team kills for bans
    for i = 1, teamKillCount do
        local playerName = teamKillNames[i]
        local kills = teamKillData[i]
        
        -- Check for ban (3+ kills)
        if kills >= 3 and not bannedPlayers[playerName] then
            ShowBanOverlay(playerName, "Team Kills: " .. kills .. "/3")
            bannedPlayers[playerName] = true
        end
    end
end

local function AddTeamDamage(attackerName, damage)
    local playerFound = false
    for i = 1, teamDamageCount do
        if teamDamageNames[i] == attackerName then
            teamDamageData[i] = teamDamageData[i] + damage
            playerFound = true
            break
        end
    end
    
    if not playerFound then
        teamDamageCount = teamDamageCount + 1
        teamDamageNames[teamDamageCount] = attackerName
        teamDamageData[teamDamageCount] = damage
    end
    
    -- Check for ban warnings after adding damage
    CheckBanWarnings()
end

local function AddTeamKill(attackerName)
    local playerFound = false
    for i = 1, teamKillCount do
        if teamKillNames[i] == attackerName then
            teamKillData[i] = teamKillData[i] + 1
            playerFound = true
            break
        end
    end
    
    if not playerFound then
        teamKillCount = teamKillCount + 1
        teamKillNames[teamKillCount] = attackerName
        teamKillData[teamKillCount] = 1
    end
    
    -- Check for ban warnings after adding kill
    CheckBanWarnings()
end

local function OnFireGameEvent(event)
    if event:GetName() == "player_hurt" then
        local playerControllerAttacker = event:GetPlayerController("attacker")
        local playerControllerVictim = event:GetPlayerController("userid")
        local playerPawnAttacker = event:GetPlayerPawn("attacker")
        local playerPawnVictim = event:GetPlayerPawn("userid")

        if playerControllerAttacker == nil or playerControllerVictim == nil or 
           playerPawnAttacker == nil or playerPawnVictim == nil then
            return
        end

        local damageAmount = event:GetInt("dmg_health")
        if playerPawnAttacker.m_iTeamNum == playerPawnVictim.m_iTeamNum then
            local attackerName = playerControllerAttacker.m_sSanitizedPlayerName
            AddTeamDamage(attackerName, damageAmount)
        end
        
    elseif event:GetName() == "player_death" then
        local playerControllerAttacker = event:GetPlayerController("attacker")
        local playerControllerVictim = event:GetPlayerController("userid")
        local playerPawnAttacker = event:GetPlayerPawn("attacker")
        local playerPawnVictim = event:GetPlayerPawn("userid")

        if playerControllerAttacker == nil or playerControllerVictim == nil or 
           playerPawnAttacker == nil or playerPawnVictim == nil then
            return
        end

        if playerPawnAttacker.m_iTeamNum == playerPawnVictim.m_iTeamNum and 
           playerControllerAttacker ~= playerControllerVictim then
            local attackerName = playerControllerAttacker.m_sSanitizedPlayerName
            AddTeamKill(attackerName)
        end
        
    elseif event:GetName() == "round_start" then
        if resetOnRoundStart then
            ResetStats()
        end
    elseif event:GetName() == "cs_win_panel_match" then
        ResetStats()
    end
end

local function HandleDragging()
    local cursorPos = Input.GetCursorPos()
    local isLeftMouseDown = Input.GetKeyDown(0x01)
    
    local overWindow = cursorPos.x >= windowPos.x and 
                      cursorPos.x <= windowPos.x + windowSize.width and
                      cursorPos.y >= windowPos.y and 
                      cursorPos.y <= windowPos.y + 25

    if overWindow and isLeftMouseDown and not isDragging then
        isDragging = true
        dragOffset.x = cursorPos.x - windowPos.x
        dragOffset.y = cursorPos.y - windowPos.y
    elseif isDragging and isLeftMouseDown then
        windowPos.x = cursorPos.x - dragOffset.x
        windowPos.y = cursorPos.y - dragOffset.y
    elseif not isLeftMouseDown then
        isDragging = false
    end
end

local function DrawCompactBar(x, y, width, height, current, max)
    Renderer.DrawRectFilled(
        Vector2D(x, y),
        Vector2D(x + width, y + height),
        colors.barBg,
        2
    )
    
    local fillWidth = math.min((current / max) * width, width)
    if fillWidth > 1 then
        -- Color-coded progress bar based on damage
        local barColor = colors.barFill
        if current >= 300 then
            barColor = Color(255, 0, 0, 255) -- Bright red for banned
        elseif current >= 250 then
            barColor = Color(200, 80, 80, 255) -- Red for danger zone
        elseif current >= 200 then
            barColor = Color(200, 150, 80, 255) -- Orange for warning
        end
        
        Renderer.DrawRectFilled(
            Vector2D(x, y),
            Vector2D(x + fillWidth, y + height),
            barColor,
            2
        )
    end
end

local function GetPlayerKills(playerName)
    for i = 1, teamKillCount do
        if teamKillNames[i] == playerName then
            return teamKillData[i]
        end
    end
    return 0
end

local function GetPlayerDamage(playerName)
    for i = 1, teamDamageCount do
        if teamDamageNames[i] == playerName then
            return teamDamageData[i]
        end
    end
    return 0
end

local function DrawContent()
    -- Dynamic window height based on player count (FIXED for 10+ players)
    local baseHeight = 80
    local rowHeight = 18
    local maxPlayers = 0
    
    -- Collect all unique players
    local allPlayers = {}
    local playerSet = {}
    
    -- Add damage players
    for i = 1, teamDamageCount do
        if not playerSet[teamDamageNames[i]] then
            table.insert(allPlayers, teamDamageNames[i])
            playerSet[teamDamageNames[i]] = true
        end
    end
    
    -- Add kill players
    for i = 1, teamKillCount do
        if not playerSet[teamKillNames[i]] then
            table.insert(allPlayers, teamKillNames[i])
            playerSet[teamKillNames[i]] = true
        end
    end
    
    maxPlayers = #allPlayers
    -- MAIN FIX: Better height calculation for 10+ players
    windowSize.height = math.max(baseHeight + (maxPlayers * rowHeight) + 40, 120)
    
    -- Main window
    Renderer.DrawRectFilled(
        Vector2D(windowPos.x, windowPos.y),
        Vector2D(windowPos.x + windowSize.width, windowPos.y + windowSize.height),
        colors.bg,
        4
    )
    
    Renderer.DrawRect(
        Vector2D(windowPos.x, windowPos.y),
        Vector2D(windowPos.x + windowSize.width, windowPos.y + windowSize.height),
        colors.border,
        4
    )
    
    -- Compact title
    Renderer.DrawText("TitleFont", "Team Damage Tracker", 
                     Vector2D(windowPos.x + 10, windowPos.y + 8), 
                     false, false, colors.text)
    
    -- Thin separator
    Renderer.DrawRectFilled(
        Vector2D(windowPos.x + 10, windowPos.y + 25),
        Vector2D(windowPos.x + windowSize.width - 10, windowPos.y + 26),
        colors.accent,
        0
    )
    
    local startY = windowPos.y + 35
    
    if maxPlayers > 0 then
        -- Compact headers
        Renderer.DrawText("CompactFont", "PLAYER", 
                         Vector2D(windowPos.x + 12, startY), 
                         false, false, colors.subtext)
        
        Renderer.DrawText("CompactFont", "DMG", 
                         Vector2D(windowPos.x + 130, startY), 
                         false, false, colors.subtext)
        
        Renderer.DrawText("CompactFont", "KILLS", 
                         Vector2D(windowPos.x + 230, startY), 
                         false, false, colors.subtext)
        
        startY = startY + 18
        
        -- Draw all player rows
        for i = 1, maxPlayers do
            local playerName = allPlayers[i]
            local damage = GetPlayerDamage(playerName)
            local kills = GetPlayerKills(playerName)
            local y = startY + (i - 1) * rowHeight
            
            -- Color-coded name based on damage/kills
            local nameColor = colors.text
            if damage >= 300 or kills >= 3 then
                nameColor = Color(255, 100, 100, 255) -- Bright red for banned
            elseif damage >= 250 then
                nameColor = Color(255, 150, 150, 255) -- Light red for danger
            elseif damage >= 200 then
                nameColor = Color(255, 200, 150, 255) -- Light orange for warning
            end
            
            -- Shorter name
            local displayName = string.len(playerName) > 10 and string.sub(playerName, 1, 10) .. ".." or playerName
            Renderer.DrawText("CompactFont", displayName, 
                             Vector2D(windowPos.x + 12, y), 
                             false, false, nameColor)
            
            -- Compact damage bar (now color-coded)
            DrawCompactBar(windowPos.x + 130, y + 2, 50, 8, damage, 300)
            Renderer.DrawText("CompactFont", damage .. "/300", 
                             Vector2D(windowPos.x + 185, y), 
                             false, false, colors.text)
            
            -- Compact kills bar (color-coded for kills too)
            local killBarColor = colors.barFill
            if kills >= 3 then
                killBarColor = Color(255, 0, 0, 255)
            elseif kills >= 2 then
                killBarColor = Color(200, 80, 80, 255)
            end
            
            Renderer.DrawRectFilled(
                Vector2D(windowPos.x + 230, y + 2),
                Vector2D(windowPos.x + 230 + 35, y + 10),
                colors.barBg,
                2
            )
            
            local killFillWidth = math.min((kills / 3) * 35, 35)
            if killFillWidth > 1 then
                Renderer.DrawRectFilled(
                    Vector2D(windowPos.x + 230, y + 2),
                    Vector2D(windowPos.x + 230 + killFillWidth, y + 10),
                    killBarColor,
                    2
                )
            end
            
            Renderer.DrawText("CompactFont", kills .. "/3", 
                             Vector2D(windowPos.x + 270, y), 
                             false, false, colors.text)
        end
        
        -- Bottom status
        local statusText = resetOnRoundStart and "Reset/round" or "Persistent"
        Renderer.DrawText("CompactFont", statusText, 
                         Vector2D(windowPos.x + 12, windowPos.y + windowSize.height - 18), 
                         false, false, colors.subtext)
    else
        Renderer.DrawText("CompactFont", "No team incidents", 
                         Vector2D(windowPos.x + 12, startY + 15), 
                         false, false, colors.subtext)
    end
end

local function OnRenderer()
    if not Globals.IsConnected() then return end
    UpdateMenuSettings()
    UpdateToasts()
    UpdateBanOverlay()
    
    if guiToggle:GetBool() then
        HandleDragging()
        DrawContent()
    end
    
    -- Always draw toast and ban overlay (even if main GUI is hidden)
    DrawToast()
    DrawBanOverlay()
end

local roll = 0 -- Start at 179

local function handle_roll_spin()
    if not rs:GetBool() then
        roll = 0
        return
    end
    
    local speed = rs_speed:GetInt()
    
    -- Smoothly decrease roll value
    roll = roll - speed
    
    -- When roll goes below -180, wrap it back to just under 180
    if roll <= -180 then
        roll = 179 - ((-180 - roll) % 359)
    end
end

local function OnPostCreateMove(cmd)
    -- Handle roll spin
    handle_roll_spin()
    
    -- Apply roll spin if enabled
    if rs:GetBool() then
        cmd.m_angViewAngles = Vector(cmd.m_angViewAngles.x, cmd.m_angViewAngles.y, roll)
    end

    if fp:GetBool() and fp:IsDown() then
        cmd.m_angViewAngles = Vector(-3402823346297399750336966557696, cmd.m_angViewAngles.y, cmd.m_angViewAngles.z)
    end

end

local messages = {
    "You just sucked a ShitHack cheat",
    "I'm fucking you with ShitHack cheat xD",
    "Download ShitHack cheat right now",
    "ShitHack is the best cheat in the world!",
    "Download ShitHack and bend everyone over with me",
    "ShitHack is the best FREE cheat!"
}

local spam_interval = 0.1
local last_spam_time = 0
local spam_enabled = false

local function spam_chat()
    local current_time = Globals.GetCurrentTime()
    if spam_checkbox:GetBool() and current_time - last_spam_time >= spam_interval then
        local random_message = messages[math.random(1, #messages)]
        CVar.ExecuteClientCmd("say " .. random_message)
        last_spam_time = current_time
    end
end

local gara = {
"I'd tell you to shoot yourself, but I bet you'd miss",
    "Are you always this slow? I thought it was just server lag!",
    "You should let your chair play, at least it knows how to support.",
    "Don't worry, just a few thousand more hours, and you’ll be almost like me.",
    "Guys, it’s not my fault your screens can’t react as fast as mine!",
    "The only thing lower than your k/d ratio is your I.Q.",
    "Looks like you’ve got a chance! Take a screenshot for the memories.",
    "Trying to play carefully so I don’t make you feel too bad ",
    "Did you know sharks only kill 5 people each year? Looks like you got some competition",
    "My knife is well-worn, just like your mother.",
    "Options -> How To Play ",
    "My dead dad has better aim than you, it only took him one bullet",
    "Some babies were dropped on their heads but you were clearly thrown at a wall",
    "Internet Explorer is faster than your reactions.",
    "Oops, sorry, I think I accidentally turned on ‘God mode’!",
    "I'm surprised you've got the brain power to keep your heart beating",
    "You're about as useful as pedals on a wheelchair. ",
    "You define autism",
    "The only thing you carry is an extra chromosome.",
    "Are you doing alright there, or should I slow down?",
    "You don't deserve to play this game. Go back to playing with crayons and shitting yourself",
    "Yo mama so fat when she plays Overpass, you can shoot her on Mirage.",
    "You’ve got a long way to go before you catch up to me.",
    "Sorry if I’m too fast for you it’s just my reflexes!",
    "Why you miss im not you're girlfriend",
    "The only thing you can throw are rounds.",
    "Why you miss im not your girlfriend",
    "Are you guys penguins? Moving so slow!",
    "Try to guess where I’ll pop up... or just don’t bother.",
    "I'm not trash talking, I'm talking to trash.",
    "If you were a CSGO match, your mother would have a 7day cooldown all the time, because she kept abandoning you.",
    "Someone here isn’t on my level... and it’s not me.",
    "Seems like you’re on pause the whole time, or is it just me?",
    "You do know this is a match and not just a chat lobby, right?",
    "I could beat you even without chat. Want to test that?",
    "When are you guys going to start trying? I’m waiting!",
    "Even with my eyes closed, I’d still be faster.",
    "Guess I’ll have to lower my difficulty to give you a chance.",
    "You can surrender now I won’t mind!",
    "If CS2 is too hard for you maybe consider a game that requires less skill, like idk.... solitaire?",
    "Oops, I must have chosen easy bots by accident...",
    "Don't be a loser, buy a rope and hang yourself.",
    "If I were to commit suicide, I would jump from your ego to your elo.",
    "Do you feel special? Please try suicide again... Hopefully you will be successful this time.",
    "Idk if u know but it's mouse1 to shoot.",
    "You are the reason why people say the CS2 community sucks.",
    "Sell your computer and buy a Wii.",
    "error: ur resolver is trash",
    "Studies show that aiming gives you better chances of hitting your target.",
    "There are about 37 trillion cells working together in your body right now, and you are disappointing every single one of them."
}

local function OnKill( event )
    if tt:GetBool() then
        if event:GetName() == "player_death" then
                local playerControllerAttacker = event:GetPlayerController( "attacker" );
                local playerControllerVictim = event:GetPlayerController("userid")
                if playerControllerAttacker ~= nil then
                    if playerControllerAttacker.m_bIsLocalPlayerController then
                        CVar.ExecuteClientCmd("say " .. gara[math.random(1, #gara)])
                end
            end
        end
    end
    
end

local ffi = require("ffi")
ffi.cdef[[
    typedef unsigned long DWORD; typedef void* HINTERNET; typedef void* LPVOID; typedef const char* LPCSTR; typedef void* HANDLE;
    static const int INTERNET_FLAG_RELOAD = 0x80000000; static const int INTERNET_FLAG_NO_CACHE_WRITE = 0x04000000;
    HINTERNET InternetOpenA(LPCSTR, DWORD, LPCSTR, LPCSTR, DWORD);
    HINTERNET InternetOpenUrlA(HINTERNET, LPCSTR, LPCSTR, DWORD, DWORD, DWORD);
    bool InternetReadFile(HINTERNET, LPVOID, DWORD, DWORD*);
    bool InternetCloseHandle(HINTERNET);
    static const DWORD GENERIC_READ = 0x80000000; static const DWORD GENERIC_WRITE = 0x40000000;
    static const DWORD OPEN_EXISTING = 3; static const DWORD CREATE_ALWAYS = 2; static const int FILE_ATTRIBUTE_NORMAL = 0x80;
    HANDLE CreateFileA(LPCSTR, DWORD, DWORD, LPVOID, DWORD, DWORD, HANDLE);
    bool ReadFile(HANDLE, LPVOID, DWORD, DWORD*, LPVOID);
    bool WriteFile(HANDLE, LPCSTR, DWORD, DWORD*, LPVOID);
    bool CloseHandle(HANDLE);
    DWORD GetFileSize(HANDLE, DWORD*);
]]

local wininet = ffi.load("wininet")
local kernel32 = ffi.load("kernel32")

local function read_file(path)
    local hFile = kernel32.CreateFileA(path, ffi.C.GENERIC_READ, 1, nil, ffi.C.OPEN_EXISTING, ffi.C.FILE_ATTRIBUTE_NORMAL, nil)
    if hFile == nil or hFile == ffi.cast("HANDLE", -1) then
        print("Error: Could not open file for reading at " .. path)
        return nil
    end
    local file_size = kernel32.GetFileSize(hFile, nil)
    if file_size == 0 then
        kernel32.CloseHandle(hFile)
        return ""
    end
    local buffer = ffi.new("char[?]", file_size)
    local bytes_read = ffi.new("DWORD[1]")
    kernel32.ReadFile(hFile, buffer, file_size, bytes_read, nil)
    kernel32.CloseHandle(hFile)
    return ffi.string(buffer, bytes_read[0])
end

local function write_file(path, content)
    local hFile = kernel32.CreateFileA(path, ffi.C.GENERIC_WRITE, 0, nil, ffi.C.CREATE_ALWAYS, ffi.C.FILE_ATTRIBUTE_NORMAL, nil)
    if hFile == nil or hFile == ffi.cast("HANDLE", -1) then return false end
    local bytes_written = ffi.new("DWORD[1]")
    kernel32.WriteFile(hFile, content, #content, bytes_written, nil)
    kernel32.CloseHandle(hFile)
    return bytes_written[0] == #content
end

local function http_get(url)
    local hInternet = wininet.InternetOpenA("LuaScriptUpdater/1.0", 1, nil, nil, 0)
    if hInternet == nil then return nil end
    local headers = "Cache-Control: no-cache, no-store, must-revalidate\r\nPragma: no-cache\r\nExpires: 0\r\n"
    local hUrl = wininet.InternetOpenUrlA(hInternet, url, headers, #headers, ffi.C.INTERNET_FLAG_RELOAD + ffi.C.INTERNET_FLAG_NO_CACHE_WRITE, 0)
    if hUrl == nil then wininet.InternetCloseHandle(hInternet); return nil end
    local response_body = ""
    local buffer = ffi.new("char[4096]")
    local bytesRead = ffi.new("DWORD[1]")
    while wininet.InternetReadFile(hUrl, buffer, 4096, bytesRead) and bytesRead[0] > 0 do
        response_body = response_body .. ffi.string(buffer, bytesRead[0])
    end
    wininet.InternetCloseHandle(hUrl)
    wininet.InternetCloseHandle(hInternet)
    return response_body
end

local function get_self_version()
    local content = read_file(SCRIPT_PATH)
    if not content then return "0.0" end
    local version = content:match("%-%-%s*@version%s*:%s*([%d%.]+)")
    return version or "0.0"
end

Renderer.LoadFontFromFile("UpdaterFont", "Arial", 16, true)
local NOTIFICATION_FONT = "UpdaterFont"
local NOTIFICATION_FONT_HEIGHT = 16

local character_width_map = { [' '] = 5, ['!'] = 5, ['"'] = 6, ['#'] = 10, ['%'] = 15, ['&'] = 10, ['\''] = 4, ['('] = 6, [')'] = 6, ['*'] = 8, ['+'] = 10, [','] = 5, ['-'] = 6, ['.'] = 5, ['/'] = 6, ['0'] = 8, ['1'] = 8, ['2'] = 8, ['3'] = 8, ['4'] = 8, ['5'] = 8, ['6'] = 8, ['7'] = 8, ['8'] = 8, ['9'] = 8, [':'] = 6, [';'] = 6, ['<'] = 10, ['='] = 10, ['>'] = 10, ['?'] = 7, ['@'] = 14, ['A'] = 9, ['B'] = 9, ['C'] = 9, ['D'] = 10, ['E'] = 8, ['F'] = 8, ['G'] = 10, ['H'] = 10, ['I'] = 6, ['J'] = 6, ['K'] = 9, ['L'] = 7, ['M'] = 12, ['N'] = 10, ['O'] = 10, ['P'] = 8, ['Q'] = 10, ['R'] = 9, ['S'] = 8, ['T'] = 9, ['U'] = 10, ['V'] = 9, ['W'] = 13, ['X'] = 9, ['Y'] = 8, ['Z'] = 8, ['['] = 6, ['\\'] = 6, [']'] = 6, ['^'] = 10, ['_'] = 8, ['`'] = 8, ['a'] = 8, ['b'] = 8, ['c'] = 7, ['d'] = 8, ['e'] = 8, ['f'] = 5, ['g'] = 8, ['h'] = 8, ['i'] = 4, ['j'] = 5, ['k'] = 7, ['l'] = 4, ['m'] = 12, ['n'] = 8, ['o'] = 8, ['p'] = 8, ['q'] = 8, ['r'] = 6, ['s'] = 7, ['t'] = 5, ['u'] = 8, ['v'] = 7, ['w'] = 11, ['x'] = 7, ['y'] = 7, ['z'] = 7, ['{'] = 7, ['|'] = 6, ['}'] = 7, ['~'] = 10 }
local default_char_width = 8

function ApproxTextWidth(text)
    local total_width = 0
    text = tostring(text or "")
    for i = 1, #text do
        local char = text:sub(i, i)
        total_width = total_width + (character_width_map[char] or default_char_width)
    end
    return total_width
end

local active_notifications = {}
local NOTIFICATION_DURATION = 8.0
local FADE_OUT_TIME = 1.5

local COLOR_BG = Color(30, 30, 30, 220)
local COLOR_BORDER = Color(10, 10, 10, 255)
local COLOR_TEXT = Color(255, 255, 255, 255)
local COLOR_ACCENT = Color(137, 154, 224, 255)

function AddNotification(text, type)
    table.insert(active_notifications, {
        text = text,
        start_time = Globals.GetCurrentTime(),
        accent_color = COLOR_ACCENT
    })
end

function DrawNotifications()
    if #active_notifications == 0 then return end

    local screen = Renderer.GetScreenSize()
    local notifications_to_keep = {}
    local y_offset = 20

    for i, msg in ipairs(active_notifications) do
        local time_elapsed = Globals.GetCurrentTime() - msg.start_time
        
        if time_elapsed < NOTIFICATION_DURATION then
            local alpha_multiplier = 1.0
            if time_elapsed > (NOTIFICATION_DURATION - FADE_OUT_TIME) then
                alpha_multiplier = (NOTIFICATION_DURATION - time_elapsed) / FADE_OUT_TIME
            end

            local text_width = ApproxTextWidth(msg.text)
            local box_width = text_width + 30
            local box_height = NOTIFICATION_FONT_HEIGHT + 12
            local x_pos = screen.x - box_width - 20
            
            local border_color = Color(COLOR_BORDER.r, COLOR_BORDER.g, COLOR_BORDER.b, COLOR_BORDER.a * alpha_multiplier)
            Renderer.DrawRectFilled(Vector2D(x_pos - 1, y_offset - 1), Vector2D(x_pos + box_width + 1, y_offset + box_height + 1), border_color, 0)
            
            local bg_color = Color(COLOR_BG.r, COLOR_BG.g, COLOR_BG.b, COLOR_BG.a * alpha_multiplier)
            Renderer.DrawRectFilled(Vector2D(x_pos, y_offset), Vector2D(x_pos + box_width, y_offset + box_height), bg_color, 0)
            
            local accent_color = Color(msg.accent_color.r, msg.accent_color.g, msg.accent_color.b, msg.accent_color.a * alpha_multiplier)
            Renderer.DrawRectFilled(Vector2D(x_pos, y_offset), Vector2D(x_pos + box_width, y_offset + 2), accent_color, 0)
            
            local text_color = Color(COLOR_TEXT.r, COLOR_TEXT.g, COLOR_TEXT.b, COLOR_TEXT.a * alpha_multiplier)
            Renderer.DrawText(NOTIFICATION_FONT, msg.text, Vector2D(x_pos + 15, y_offset + 6), false, true, text_color)
            
            y_offset = y_offset + box_height + 10
            table.insert(notifications_to_keep, msg)
        end
    end
    active_notifications = notifications_to_keep
end

local CURRENT_VERSION = get_self_version()
local last_update_check = 0
local notified_about_availability = false
local notified_about_completion = false
local previous_auto_update_state = false

local function checkForUpdate()
    if notified_about_completion then return end
    print("Checking for script updates...")
    
    local cache_buster = "?cb=" .. Globals.GetTickCount()
    local remote_script_content = http_get(SCRIPT_URL .. cache_buster)
    
    if not remote_script_content or #remote_script_content == 0 then
        print("Update check failed: Could not fetch remote script file.")
        return
    end
    
    local latest_version = remote_script_content:match("%-%-%s*@version%s*:%s*([%d%.]+)") or "0.0"
    print("Current: v" .. CURRENT_VERSION .. ", Latest: v" .. latest_version)

    if latest_version ~= "0.0" and latest_version ~= CURRENT_VERSION then
        if not notified_about_availability then
            AddNotification("New version available: v" .. latest_version, "available")
            notified_about_availability = true
        end
        
        if menu_auto_update_enabled:GetBool() then
            print("Auto-update enabled. Overwriting script...")
            if write_file(SCRIPT_PATH, remote_script_content) then
                print("Update successful! File overwritten. Please reload scripts.")
                if not notified_about_completion then
                    AddNotification("Update successful! Please reload scripts.", "complete")
                    notified_about_completion = true
                end
            else
                print("Update failed: Could not write to script file.")
            end
        end
    else
        print("Your script is up to date.")
    end
    last_update_check = Globals.GetCurrentTime()
end

local function onRender()
    local current_time = Globals.GetCurrentTime()
    local current_auto_update_state = menu_auto_update_enabled:GetBool()

    if Globals.IsConnected() and (current_time - last_update_check > UPDATE_INTERVAL) then
        checkForUpdate()
    end

    if notified_about_availability and not notified_about_completion and current_auto_update_state and not previous_auto_update_state then
        print("Checkbox enabled, starting update process immediately.")
        checkForUpdate()
    end

    previous_auto_update_state = current_auto_update_state
    
    DrawNotifications()
end


--// REGISTER CALLBACKS //--
Cheat.RegisterCallback("OnPreCreateMove", function(cmd)
     BlockbotLogic(cmd)
     OnPostCreateMove(cmd)
end)
Cheat.RegisterCallback("OnRenderer", function() 
    DrawPlayerIndicators() 
    OnRenderer()
    onRender()
    spam_chat()
end)
Cheat.RegisterCallback("OnFireGameEvent", function(event)
    OnFireGameEvent(event)
    OnKill(event)
end)
Cheat.RegisterCallback("OnRenderer", OnRenderer)

local initial_check_thread = coroutine.create(checkForUpdate)
coroutine.resume(initial_check_thread)

print("Script Auto-Updater Loaded. Current version: " .. CURRENT_VERSION)
