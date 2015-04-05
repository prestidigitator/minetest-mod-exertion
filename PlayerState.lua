local exertion = select(1, ...);
local settings = exertion.settings;


local PLAYER_DB_FILE =
   minetest.get_worldpath() .. "/" ..
      exertion.MOD_NAME .. "_playerStatesDb.json";
local SECONDS_PER_DAY =
   (function()
      local ts = tonumber(minetest.setting_get("time_speed"));
      if not ts or ts <= 0 then ts = 72; end;
      return 24 * 60 * 60 / ts;
    end)();
local DF_DT = settings.food_perDay / SECONDS_PER_DAY;
local DW_DT = settings.water_perDay / SECONDS_PER_DAY;
local DP_DT = settings.poison_perDay / SECONDS_PER_DAY;
local DHP_DT = settings.healing_perDay / SECONDS_PER_DAY;


local function clamp(x, min, max)
   if x < min then
      return min;
   elseif x > max then
      return max;
   else
      return x;
   end;
end;

local gameToWallTime;
local wallToGameTime;
do
   local ts = tonumber(minetest.setting_get("time_speed"));
   if not ts or ts <= 0 then ts = 72; end;
   local WALL_MINUS_GAME = os.time() - minetest.get_gametime();

   gameToWallTime = function(tg)
      return tg + WALL_MINUS_GAME;
   end

   wallToGameTime = function(tw)
      return tw - WALL_MINUS_GAME;
   end
end

local function calcMultiplier(mt,
                              exertionStatus,
                              fedStatus,
                              hydratedStatus,
                              poisonedStatus)
   local em = mt.exertion[exertionStatus] or 1.0;
   local fm = mt.fed[fedStatus] or 1.0;
   local hm = mt.hydrated[hydratedStatus] or 1.0;
   local pm = mt.poisoned[poisonedStatus] or 1.0;
   return em * fm * hm * pm;
end;

local function canDrink(player)
   local p = player:getpos();
   local hn = minetest.get_node({ x = p.x, y = p.y + 1, z = p.z });
   if not hn or hn.name ~= "air" then return false; end;
   return minetest.find_node_near(p, settings.drinkDistance, "group_water");
end;


--- Manages player state for the exertion mod.
 --
 -- @author presitidigitator (as reistered at forum.minetest.net).
 -- @copyright 2015, licensed under WTFPL
 --
local PlayerState = { db = {} };
local PlayerState_meta = {};
local PlayerState_ops = {};
local PlayerState_inst_meta = {};

setmetatable(PlayerState, PlayerState_meta);
PlayerState_inst_meta.__index = PlayerState_ops;

--- Constructs a PlayerState, loading from the database if present there, or
 -- initializing to an initial state otherwise.
 --
 -- Call with one of:
 --    PlayerState.new(player)
 --    PlayerState(player)
 --
 -- @return a new PlayerState object
 --
function PlayerState.new(player)
   local playerName = player:get_player_name();
   if not playerName or playerName == "" then
      error("Argument is not a player");
   end;

   local state = PlayerState.db[playerName];
   local newState = false;
   if not state then
      state = {};
      PlayerState.db[playerName] = state;
      newState = true;
   end;

   local self =
      setmetatable({ player = player, state = state; }, PlayerState_inst_meta);
   self:initialize(newState);

   return self;
end;
PlayerState_meta.__call =
   function(class, ...) return PlayerState.new(...); end;

--- Loads the PlayerState DB from the world directory (call only when the mod
 -- is first loaded).
function PlayerState.load()
   local playerDbFile = io.open(PLAYER_DB_FILE, 'r');
   if playerDbFile then
      local ps = minetest.parse_json(playerDbFile:read('*a'));
      if ps then PlayerState.db = ps; end;
      playerDbFile:close();
   end;
end;

function PlayerState.save()
   local playerDbFile = io.open(PLAYER_DB_FILE, 'w');
   if playerDbFile then
      local json, err = minetest.write_json(PlayerState.db);
      if not json then playerDbFile:close(); error(err); end;
      playerDbFile:write(json);
      playerDbFile:close();
   end;
end;

function PlayerState_ops:initialize(newState)
   local tw = os.time();
   local tg = minetest.get_gametime();
   if newState then
      self.state.fed = settings.fedMaximum;
      self.state.hydrated = settings.hydratedMaximum;
      self.state.poisoned = 0;
      self.state.foodLost = 0;
      self.state.waterLost = 0;
      self.state.poisonLost = 0;
      self.state.hpGained = 0;
      self.state.airLost = 0;
      self.state.updateGameTime = tg;
      self.state.updateWallTime = tw;

      self.activity = 0;
      self.activityPolls = 0;
      self.builds = 0;

      self:updatePhysics();
      self:updateHud();
   else
      local dt;
      if settings.useWallclock and
         self.state.updateWallTime and
         self.state.updateWallTime <= tw
      then
         dt = tw - self.state.updateWallTime;
      elseif self.state.updateGameTime and
             self.state.updateGameTime <= tg
      then
         dt = tg - self.state.updateGameTime;
      else
         dt = 0;
      end;

      self.state.fed = self.state.fed or 0;
      self.state.hydrated = self.state.hydrated or 0;
      self.state.poisoned = self.state.poisoned or 0;
      self.state.foodLost = self.state.foodLost or 0;
      self.state.waterLost = self.state.waterLost or 0;
      self.state.poisonLost = self.state.poisonLost or 0;
      self.state.hpGained = self.state.hpGained or 0;
      self.state.airLost = 0;

      self.activity = 0;
      self.activityPolls = 0;
      self.builds = 0;

      self:update(tw, dt);
   end;
end;

function PlayerState_ops:calcExertionStatus()
   local polls = self.activityPolls;
   local ar = (polls > 0 and self.activity / polls) or 0;
   local b = self.builds;

   local status = nil;
   local priority = nil;
   for s, c in pairs(settings.exertionStatuses) do
      if c then
         local pc = c.priority;
         if not priority or (pc and pc > priority) then
            local arc = c.activityRatio;
            local bc = c.builds;
            if (arc and ar >= arc) or (bc and b >= bc)
            then
               status = s;
               priority = pc;
            end;
         end;
      end;
   end;

   return status or 'none';
end;

function PlayerState_ops:calcFedStatus()
   local fed = self.state.fed;

   local status = nil;
   local threshold = nil;
   for s, t in pairs(settings.fedStatuses) do
      if t > threshold and fed >= t then
         status = s;
         threshold = t;
      end;
   end;

   return status or 'none';
end;

function PlayerState_ops:calcHydratedStatus()
   local hyd = self.state.hydrated;

   local status = nil;
   local threshold = nil;
   for s, t in pairs(settings.hydratedStatuses) do
      if t > threshold and hyd >= t then
         status = s;
         threshold = t;
      end;
   end;

   return status or 'none';
end;

function PlayerState_ops:calcPoisonedStatus()
   local poi = self.state.poisoned;

   local status = nil;
   local threshold = nil;
   for s, t in pairs(settings.poisonedStatuses) do
      if t > threshold and poi >= t then
         status = s;
         threshold = t;
      end;
   end;

   return status or 'none';
end;

function PlayerState_ops:addFood(df)
   local fedChanged = false;

   if df > 0 then
      if df >= 1.0 then
         local dfn, dff = math.modf(df);
         self.state.fed = clamp(self.state.fed + dfn, 0, settings.fedMaximum);
         if self.state.foodLost < 0 then
            self.state.foodLost = self.state.foodLost - dff;
         else
            self.state.foodLost = -dff;
         end;
         fedChanged = true;
      else
         self.state.foodLost = self.state.foodLost - df;
      end;
   elseif df < 0 then
      df = self.state.foodLost - df;  -- now positive
      if df >= 1.0 then
         local dfn, dff = math.modf(df);
         self.state.fed = clamp(self.state.fed - dfn, 0, setttings.fedMaximum);
         self.state.foodLost = dff;
         fedChanged = true;
      else
         self.state.foodLost = df;
      end;
   end;

   return fedChanged;
end;

function PlayerState_ops:addWater(dw)
   local hydratedChanged = false;

   if dw > 0 then
      if dw >= 1.0 then
         local dwn, dwf = math.modf(dw);
         self.state.hydrated =
            clamp(self.state.hydrated + dwn, 0, settings.hydratedMaximum);
         if self.state.waterLost < 0 then
            self.state.waterLost = self.state.waterLost - dwf;
         else
            self.state.waterLost = -dwf;
         end;
         hydratedChanged = true;
      else
         self.state.waterLost = self.state.waterLost - dw;
      end;
   elseif dw < 0 then
      dw = self.state.waterLost - dw;  -- now positive
      if dw >= 1.0 then
         local dwn, dwf = math.modf(dw);
         self.state.hydrated =
            clamp(self.state.hydrated - dwn, 0, setttings.hydratedMaximum);
         self.state.waterLost = dwf;
         hydratedChanged = true;
      else
         self.state.waterLost = dw;
      end;
   end;

   return hydratedChanged;
end;

function PlayerState_ops:addPoison(dp)
   local poisonedChanged = false;

   if dp > 0 then
      local dpn = math.ceil(dp);
      local dpf = dpn - dp;
      self.state.poisoned =
         clamp(self.state.poisoned + dpn, 0, settings.poisonedMaximum);
      self.state.poisonLost = 0;
      poisonedChanged = true;
   elseif dp < 0 then
      dp = self.state.poisonLost - dp;  -- now positive
      if dp >= 1.0 then
         local dpn, dpf = math.modf(dp);
         self.state.poisoned =
            clamp(self.state.poisoned - dpn, 0, setttings.poisonMaximum);
         self.state.poisonLost = dpf;
         poisonedChanged = true;
      else
         self.state.poisonLost = dp;
      end;
   end;

   return poisonedChanged;
end;

function PlayerState_ops:addHp(dhp)
   local hpChanged = false;

   dhp = self.state.hpGained + dhp;
   if dhp < 0 or dhp >= 1.0 then
      local dhpf = dhp % 1.0;
      local dhpn = dhp - dhpf;
      self.player:set_hp(self.player:get_hp() + dhpn);
      self.state.hpGained = dhpf;
      hpChanged = true;
   else
      self.state.hpGained = dhp;
   end;

   return hpChanged;
end;

function PlayerState_ops:addBreath(db)
   local player = self.player;
   local b0 = player:get_breath();
   local breathChanged = false;

   if b0 < 11 then
      if db > 0 then
         if db > 1.0 then
            local dbn, dbf = math.modf(db);
            player:set_breath(b0 + dbn);
            self.state.airLost = -dbf;
            breathChanged = true;
         else
            self.state.airLost = self.state.airLost - db;
         end;
      elseif db < 0 then
         db = self.state.airLost - db;  -- now positive
         if db > 1.0 then
            local dbn, dbf = math.modf(db);
            player:set_breath(b0 - dbn);
            self.state.airLost = dbf;
            breathChanged = true;
         else
            self.state.airLost = db;
         end;
      end;
   else
      self.state.airLost = 0;
   end;

   return breathChanged;
end;

function PlayerState_ops:update(tw, dt)
   local player = self.player;
   if tw == nil then tw = os.time(); end;
   if dt == nil then dt = tw - self.state.updateWallTime; end;
   if dt < 0 then return; end;

   local hudChanged = false;
   local es = self:calcExertionStatus();
   local fs = self:calcFedStatus();
   local hs = self:calcHydratedStatus();
   local ps = self:calcPoisonedStatus();

   local retchProb = poisonedRetchProbabilities_perPeriod[ps];
   local retching = retchProb and math.random() <= retchProb;

   if self.state.fed > 0 then
      local fm = calcMultiplier(settings.foodMultipliers, es, fs, hs, ps);
      local df = -DF_DT * fm * dt;
      if retching then df = df - settings.retchingFoodLoss; end;
      hudChanged = self:addFood(df) or hudChanged;
   end;

   if canDrink(player) then
      hudChanged = self:addWater(setting.drinkAmount_perPeriod) or hudChanged;
   elseif self.state.hydrated > 0 then
      local wm = calcMultiplier(settings.waterMultipliers, es, fs, hs, ps);
      local dw = -DW_DT * wm * dt;
      if retching then dw = dw - settings.retchingWaterLoss; end;
      hudChanged = self:addWater(dw) or hudChanged;
   end;

   if self.state.poisoned > 0 then
      local dp = -DP_DT * dt;
      hudChanged = self:addPoison(dp) or hudChanged;
   end;

   local hpm = calcMultiplier(settings.healingMultipliers, es, fs, hs, ps);
   local dhp = DHP_DT * hpm * dt;
   if retching then dhp = dhp - settings.retchingDamage; end;
   self:addHp(dhp);

   self:addBreath((retching and -settings.retchingAirLoss) or 0);

   if retching then
      player:set_physics_override({ speed = 0, jump = 0 });
      minetest.after(settings.retchDuration_seconds,
                     self.updatePhysics, self, es, fs, hs, ps);
   else
      self:updatePhysics(es, fs, hs, ps);
   end;

   if hudChanged then self:updateHud(); end;

   self.activity = 0;
   self.activityPolls = 0;
   self.builds = 0;
   self.state.updateGameTime = wallToGameTime(tg);
   self.state.updateWallTime = tw;
end;

function PlayerState_ops:updatePhysics(es, fs, hs, ps)
   if not es then es = self:calcExertionStatus(); end;
   if not fs then fs = self:calcFedStatus(); end;
   if not hs then hs = self:calcHydratedStatus(); end;
   if not ps then ps = self:calcPoisonedStatus(); end;

   local sm = calcMultiplier(settings.speedMultipliers, es, fs, hs, ps);
   local jm = calcMultiplier(settings.jumpMultipliers, es, fs, hs, ps);

   self.player:set_physics_override({ speed = sm, jump = jm });
end;

function PlayerState_ops:updateHud()
   local player = self.player;

   local fh = self.fedHudId;
   if not fh then
      fh = player:hud_add(settings.fedHud);
      self.fedHudId = fh;
   end;
   player:hud_change(fh, 'number', self.state.fed);

   local hh = self.hydratedHudId;
   if not fh then
      hh = player:hud_add(settings.hydratedHud);
      self.hydratedHudId = hh;
   end;
   player:hud_change(hh, 'number', self.state.hydrated);

   local ph = self.poisonedHudId;
   if not fh then
      ph = player:hud_add(settings.poisonedHud);
      self.poisonedHudId = ph;
   end;
   player:hud_change(ph, 'number', self.state.poisoned);
end;

function PlayerState_ops:pollForActivity()
   local player = self.player;

   self.activityPolls = self.activityPolls + 1;

   local activeControls = player:get_player_control();
   local testControls = settings.exertionControls;
   for _, ctrl in ipairs(testControls) do
      if activeControls[ctrl] then
         self.activity = self.activity + 1;
         return;
      end;
   end;

   if player:get_breath() <= settings.exertionHoldingBreathMax then
      self.activity = self.activity + 1;
      return;
   end;
end;

function PlayerState_ops:markBuildAction(node)
   local nodeName = node.name;
   if not (minetest.get_node_group(nodeName, "oddly_breakable_by_hand") > 0 or
           minetest.get_node_group(nodeName, "dig_immediate") > 0)
   then
      self.builds = self.builds + 1;
   end;
end;


return PlayerState;
