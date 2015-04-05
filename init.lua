local MOD_NAME = minetest.get_current_modname() or "exertion";
local MOD_PATH = minetest.get_modpath();

local exertion = { MOD_NAME = MOD_NAME, MOD_PATH = MOD_PATH };
_G[MOD_NAME] = exertion;


local function callFile(fileName, ...)
   local chunk, err = loadfile(MOD_PATH .. "/" .. fileName);
   if not chunk then error(err); end;
   return chunk(...);
end;


local settings = callFile("loadSettings.lua", exertion);
exertion.settings = settings;

local PlayerState = callFile("PlayerState.lua", exertion);
exertion.PlayerState = PlayerState;


PlayerState.load();
local playerStates = {};

minetest.register_on_joinplayer(
   function(player)
      minetest.after(
         0, function() playerStates[player] = PlayerState(player); end);
   end);

minetest.register_on_leaveplayer(
   function(player)
      playerStates[player] = nil;
   end);

minetest.register_on_shutdown(PlayerState.save);

minetest.register_on_dignode(
   function(pos, oldNode, digger)
      local ps = playerStates[digger];
      if ps then ps:markBuildAction(oldNode); end;
   end);

minetest.register_on_placenode(
   function(pos, newNode, placer, oldNode, itemStack, pointedThing)
      local ps = playerStates[placer];
      if ps then ps:markBuildAction(newNode); end;
   end);

local controlPeriod = settings.controlTestPeriod_seconds;
local updatePeriod = settings.accountingPeriod_seconds;
local savePeriod = settings.savePeriod_seconds;
local controlTime = 0.0;
local updateTime = 0.0;
local saveTime = 0.0;
minetest.register_globalstep(
   function(dt)
      controlTime = controlTime + dt;
      if controlTime >= controlPeriod then
         for _, ps in pairs(playerStates) do
            ps:pollForActivity();
         end;
         controlTime = 0;
      end;

      updateTime = updateTime + dt;
      if updateTime >= updatePeriod then
         controlPeriod = settings.controlTestPeriod_seconds;
         updatePeriod = settings.accountingPeriod_seconds;
         local tw = os.time();
         for _, ps in pairs(playerStates) do
            ps:update(tw, updateTime);
         end;
         updateTime = 0;
      end;

      saveTime = saveTime + dt;
      if saveTime >= savePeriod then
         savePeriod = settings.savePeriod_seconds;
         PlayerState.save();
         saveTime = 0;
      end;
   end);

minetest.register_on_item_eat(
   function(hpChange, replacementItem, itemStack, player, pointedThing)
      if itemStack:take_item() ~= nil then
         local ps = playerStates[player];
         if ps then
            if hpChange > 0 then
               ps:addFood(hpChange);
            elseif hpChange < 0 then
               ps:addPoison(-hpChange);
            end;
         end;
         itemStack:add_item(replacementItem);
      end;
      return itemStack;
   end);
