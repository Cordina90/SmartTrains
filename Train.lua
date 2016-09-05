Train = {

    new = function(train, id)
      if train.valid then
        local new = {
          train = train,
          ID = id,
          locomotives = {},
          line = false,
          lineVersion = 0,
          settings = {},
          waiting = false,
          refueling = false,
          advancedState = false,
          cargo = {},
          cargoUpdated = 0,
          last_fuel_update = 0,
          direction = 0, -- 0 = front, 1 back (lookup direction for trainstop)
          railtanker = false, -- has a railtanker wagon
          passengers = 0,
        }
        new.settings.autoRefuel = defaultTrainSettings.autoRefuel

        setmetatable(new, {__index = Train})
        new:update(train, id)
        return new
      end
    end,

    getLocomotives = function(self)
      local locomotives = {}
      if self.train.locomotives then
        for _, loco in pairs(self.train.locomotives.front_movers) do
          table.insert(locomotives, loco)
        end
        for _, loco in pairs(self.train.locomotives.back_movers) do
          table.insert(locomotives, loco)
        end
      end
      return locomotives
    end,

    getName = function(self)
      local train = self.train
      if train.locomotives ~= nil and (#train.locomotives.front_movers > 0 or #train.locomotives.back_movers > 0) then
        if self.train.locomotives.front_movers[1] then
          return train.locomotives.front_movers[1].backer_name
        elseif train.locomotives.back_movers[1] then
          return train.locomotives.back_movers[1].backer_name
        end
      end
      return ""
    end,

    getType = function(self)
      local parts = {}
      local found
      for _,c in pairs(self.train.carriages) do
        found = false
        if c.type == "locomotive" then
          for i, fm in pairs(self.train.locomotives.front_movers) do
            if fm == c then
              table.insert(parts,'L')
              found = true
              break
            end
          end
          if not found then
            for i, bm in pairs(self.train.locomotives.back_movers) do
              if bm == c then
                table.insert(parts,'L')
                break
              end
            end
          end
        else
          table.insert(parts, 'C')
        end
      end
      local type = table.concat(parts,'')
      type = type:gsub("LC","L-C"):gsub("CL", "C-L")
      return string.gsub(string.gsub(type, "^-", ""), "-$", "")
    end,

    update = function(self, train, id)
      self.ID = id
      self.train = train
      self.locomotives = self:getLocomotives()
      self.type = self:getType()
      self.name = self:getName()
      self.passengers = 0
      self.railtanker = false
      for _, c in pairs(train.carriages) do
        if c.name == "rail-tanker" then
          self.railtanker = true
        end
        if c.passenger and c.passenger.name ~= "fatcontroller" then
          self.passengers = self.passengers + 1
        end
      end
    end,

    printName = function(self)
      debugDump(self.name, true)
    end,

    get_first_matching_station = function(self, value, current)
      local stations = global.stationMap[self.train.carriages[1].force.name][value]
      if not stations then
        return false
      end
      local schedule = self.train.schedule
      local records = schedule.records
      current = current or schedule.current
      local num_records = #records
      local index
      for i = 0, num_records - 2 do
        index = (current + i) % num_records + 1
        if stations[records[index].station] then
          return index
        end
      end
      return false
    end,

    nextStation = function(self, force, index)
      local train = self.train
      if self.settings.autoRefuel then
        if self:lowestFuel() < (global.settings.refuel.rangeMin) and not inSchedule(self:refuelStation(), train.schedule) then
          train.schedule = addStation(self:refuelStation(), train.schedule, global.settings.refuel.time)
          if global.showFlyingText then
            self:flyingText("Refuel station added", colors.YELLOW)
          end
        end
      end
      if train.manual_mode == false or force then
        local schedule = train.schedule

        local tmp = (schedule.current % #schedule.records) + 1
        if index and index > 0 and index <= #schedule.records then
          tmp = index
        end
        if global.showFlyingText then
          self:flyingText("Going to "..schedule.records[tmp].station, colors.YELLOW, {offset = -1}) --TODO localisation
        end

        --all below is needed to make a train go to another station, don't change!
        train.manual_mode = true
        schedule.current = tmp
        train.schedule = schedule
        train.manual_mode = false
      end
    end,

    isValidScheduleIndex = function(self, index)
      if index and index > 0 and index <= #self.train.schedule.records then
        return index
      end
      return false
    end,

    refuelStation = function(self)
      local station = global.settings.refuel.station
      local lType = self:getType()

      -- First thing first, check for an explicit match for the
      -- train's configuration and specific refueling station.
      local refuelStation = station.." "..lType
      local force = self.train.carriages[1].force.name
      local full_match = global.stationCount[force][refuelStation] and global.stationCount[force][refuelStation] > 0
      if full_match then
         --debugDump("full_match: train="..lType.." @ station="..refuelStation, true)
         return refuelStation
      end

      -- Since there wasn't a specific match, we now need to search
      -- through all of the stations trying to find one that matches
      -- the locomotive configuration.

      -- Loco L-CC cannot refuel at Refuel L-C-L (issue #41).

      lType = string.gsub(lType, "%-", "")
      pattern = "^"..station.."%s+([LC-]+)$"
      for name, c in pairs(global.stationCount[force]) do
         if name == nil then name = "" end

         _, _, sType = string.find(name, pattern)
         if sType then
            -- This station matches the auto-refuel pattern. We'll perform
            -- subset checks on the train/station and station/train to ensure
            -- the proper alignment.
            sType = string.gsub(sType, "%-", "")

            -- Is the train configuration a subset of the refuel station?
            if string.find(sType, "^"..lType) then
               --debugDump("subset 1: train="..self:getType().." @ station="..name, true)
               return name
            end

            -- Is the refuel station a subset of the train?
            if string.find(lType, "^"..sType) then
               --debugDump("subset 2: train="..self:getType().." @ station="..name, true)
               return name
            end
         end
      end

      -- Default to the base station.
      --debugDump("default: train="..self:getType().." @ station="..station, true)
      return station
    end,

    startRefueling = function(self)
      if global.showFlyingText then
        self:flyingText("refueling", colors.YELLOW)
      end
      local tick = game.tick + global.settings.intervals.inactivity
      self.refueling = tick
      insertInTable(global.refueling, tick, self)
    end,

    isRefueling = function(self)
      return self.refueling and self.settings.autoRefuel
    end,

    refuelingDone = function(self, done)
      if done then
        if global.showFlyingText then
          self:flyingText("Refueling done", colors.YELLOW)
        end
        self.refueling = false
        self:nextStation()
      end
    end,

    removeRefuelStation = function(self)
      if inSchedule_reverse(self:refuelStation(), self.train.schedule) and #self.train.schedule.records >= 3 then
        self.train.schedule = removeStation(self:refuelStation(), self.train.schedule)
        if global.showFlyingText then
          self:flyingText("Refuel station removed", colors.YELLOW) --TODO localisation
        end
      end
    end,

    currentStation = function(self)
      if self.train.valid and type(self.train.schedule.records) == "table" and self.train.schedule.records[self.train.schedule.current] then
        return self.train.schedule.records[self.train.schedule.current].station
      else
        return false
      end
    end,

    getStationName = function(self, index)
      index = index or self.train.schedule.current
      if self.train.valid and index and self:isValidScheduleIndex(index) and type(self.train.schedule.records) == "table" then
        return self.train.schedule.records[index].station
      else
        return false
      end
    end,

    get_rules = function(self, current)
      current = current or self.train.schedule.current
      local line = (self.line and global.trainLines[self.line] and global.trainLines[self.line].records) and global.trainLines[self.line] or false
      --log(line.records[current].station)
      --local rules = line and line.records[current].rules or false
      local rules = line and line.rules[current] or false
      -- use copied rules when waiting
      if self.train.state == defines.train_state.wait_station then
        rules = self.rules
      end
      if rules and rules.station == self:getStationName(current) then
        local defaultRule = {jumpToCircuit = true, jumpTo = true}
        for k, _ in pairs(defaultRule) do
          if rules[k] then
            return rules
          end
        end
      end
      return false
    end,

    get_rule = function(self, name, current)
      local rules = self:get_rules(current)
      if rules then
        return rules[name]
      end
      return false
    end,

    getWaitingTime = function(self)
      if self.train.schedule and self.train.schedule.records and #self.train.schedule.records > 0 then
        local conditions = self.train.schedule.records[self.train.schedule.current].wait_conditions or {}
        for _, condition in pairs(conditions) do
          if condition.type == "time" then
            return condition.ticks
          end
        end
      end
      return 2^32-1 --TODO what to return when no waiting time set?
    end,

    -- return true when at a smart train stop
    setWaitingStation = function(self)
      if self.waiting then
        return
      end

      local current_tick = game.tick
      local rules = self:get_rules()

      local station = findTrainStopByTrain(self)
      if station and station.backer_name ~= self:getStationName() then
        log(game.tick .. " station name mismatch")
        return
      end
      if not station then
        log("state is wait_station but no trainstation found")
      end
      self.waitingStation = findSmartTrainStopByTrain(self, self:getStationName())
      if not self.waitingStation and rules and rules.jumpToCircuit then
        --TODO proper error message
        debugDump("No smart trainstop with go to signal# rule. Line: " .. self.line .. " @ station " .. self.train.schedule.records[self.train.schedule.current].station, true) --TODO localisation
        return
      end
      --LOGGERS.main.log(serpent.line(rules, {comment=false}))
      local nextUpdate = current_tick + global.settings.intervals.write
      if self:getWaitingTime() == 10 then
        nextUpdate = current_tick + 2
      end
      self.waiting = true
      self.rules = table.deepcopy(rules)

      -- update cargo (only if smart stop or full/empty/inactivity rule set
      -- write to combinator (only if smart stop)

      if self.waitingStation then
        self:setCircuitSignal()
        insertInTable(global.update_cargo, nextUpdate, self)
        self.update_cargo = nextUpdate
      end
    end,

    resetWaitingStation = function(self, destination)
      self:resetCircuitSignal(destination)
      self.waitingStation = false
      self.waiting = false
      self.rules = false
      self.refueling = false
      self.departAt = false
      self.update_cargo = false
    end,

    getCircuitValue = function(self)
      if self.waitingStation and self.waitingStation.signalProxy and self.waitingStation.signalProxy.valid then
        local behavior = self.waitingStation.signalProxy.get_control_behavior()
        if behavior then
          local condition = behavior.circuit_condition.condition
          local signal = (condition and condition.first_signal and condition.first_signal.name) and condition.first_signal or false
          if signal and signal.name then
            local sum = 0

            local green = behavior.get_circuit_network(defines.wire_type.red, defines.circuit_connector_id.lamp)
            if green then
              sum = green.get_signal(signal) or 0
            end
            local red = behavior.get_circuit_network(defines.wire_type.green, defines.circuit_connector_id.lamp)
            if red then
              sum = sum + (red.get_signal(signal) or 0)
            end
            --TODO add logistics network value?
            -- adds logistics value to signal if connect is set and signal is an actual item
            --            if behavior.connect_to_logistic_network and self.waitingStation.signalProxy.logistic_network then
            --              sum = sum + self.waitingStation.signalProxy.logistic_network.get_item_count(signal.name)
            --            end
            --            log(sum)
            return sum
          end
        end
      end
      return false
    end,

    setCircuitSignal = function(self, destination)
      if self.waitingStation and self.waitingStation.station.valid and self.waitingStation.cargo and self.waitingStation.cargo.valid then
        local cargoProxy = self.waitingStation.cargo
        local parameters={}

        local min_fuel = self:lowestFuel(true)
        local i = 1
        local station_number = global.stationNumbers[cargoProxy.force.name][self.waitingStation.station.backer_name] or false
        if station_number and station_number ~= 0 then
          parameters[i]={signal={type = "virtual", name = "signal-station-number"}, count = station_number, index = i}
          i=i + 1
        end
        parameters[i]={signal={type = "virtual", name = "signal-train-at-station"}, count = 1, index = i}
        i=i + 1
        parameters[i]={signal={type = "virtual", name = "signal-locomotives"}, count = #self.train.locomotives.front_movers + #self.train.locomotives.back_movers, index = i}
        i=i + 1
        parameters[i]={signal={type = "virtual", name = "signal-cargowagons"}, count = #self.train.cargo_wagons, index = i}
        i=i + 1
        parameters[i]={signal={type = "virtual", name = "signal-passenger"}, count = self.passengers, index = i}
        i=i + 1
        parameters[i]={signal={type = "virtual", name = "signal-lowest-fuel"}, count = min_fuel, index = i}
        i=i + 1

        if self.line and global.trainLines[self.line] and global.trainLines[self.line].settings.number ~= 0 then
          parameters[i]={signal={type = "virtual", name = "signal-line"}, count = global.trainLines[self.line].settings.number, index = i}
          i=i + 1
        end

        if destination then
          --log(game.tick .. " Train: "..self.name .. " setting destination signal: " .. self.train.schedule.current)
          parameters[i]={signal={type = "virtual", name = "signal-destination"}, count = self.train.schedule.current, index = i}
          i = i + 1
        end

        local cargoCount = self:cargoCount(true)
        for name, count in pairs(cargoCount) do
          local type = "item"
          if game.fluid_prototypes[name] then
            type = "fluid"
            count = math.floor(count)
          end
          parameters[i]={signal={type = type, name = name}, count=count, index = i}
          i=i+1
          if i>50 then break end
        end
        local behaviour = cargoProxy.get_control_behavior()
        if behaviour then
          behaviour.parameters = {parameters = parameters}
        end
      end
    end,

    resetCircuitSignal = function(self, destination)
      if self.waitingStation and self.waitingStation.cargo and self.waitingStation.cargo.valid then
        if self.train and self.train.valid then
          self:setCircuitSignal(destination)
        end
        global.reset_signals[game.tick+1] = global.reset_signals[game.tick+1] or {}
        table.insert(global.reset_signals[game.tick+1], {cargo = self.waitingStation.cargo, station = self.waitingStation.station})
      end
    end,

    --returns fuelvalue (in MJ)
    lowestFuel = function(self, exact)
      if self.last_fuel_update + 60 <= game.tick or exact then
        self.last_fuel_update = game.tick
        local minfuel
        local c
        local locos = (self.train and self.train.valid) and self.train.locomotives or false
        if locos then
          for _, carriage in pairs(locos.front_movers) do
            c = self:calcFuel(carriage.get_inventory(1).get_contents())
            if minfuel == nil or c < minfuel then
              minfuel = c
            end
          end
          for _, carriage in pairs(locos.back_movers) do
            c = self:calcFuel(carriage.get_inventory(1).get_contents())
            if minfuel == nil or c < minfuel then
              minfuel = c
            end
          end
          self.minFuel = minfuel
        else
          self.minFuel = 0
        end
      end
      return self.minFuel
    end,

    calcFuel = function(self, contents)
      local value = 0
      --/c game.player.print(game.player.character.vehicle.train.locomotives.front_movers[1].energy)
      for i, c in pairs(contents) do
        value = value + c*fuelvalue(i)
      end
      return value
    end,

    cargoCount = function(self, exact)
      local current_tick = game.tick
      if (not exact and self.cargoUpdated > current_tick - 12) or self.cargoUpdated == current_tick then -- update cargo only if older than 12 ticks (default circuit update rate)
        --LOGGERS.main.log("cached cargo "..self.name)
        return self.cargo
      end
      if self.cargoUpdated + global.settings.intervals.write <= current_tick then
        --log("new cargo")
        --LOGGERS.main.log("update cargo "..self.name)
        local sum = {}
        local train = self.train
        if not self.railtanker and not self.proxy_chests then
          sum = train.get_contents()
        else
          for i, wagon in pairs(train.cargo_wagons) do
            if not self.proxy_chests or not self.proxy_chests[i] then
              if wagon.name ~= "rail-tanker" then
                --sum = sum + wagon.getcontents()
                sum = addInventoryContents(sum, wagon.get_inventory(1).get_contents())
              else
                if remote.interfaces.railtanker and remote.interfaces.railtanker.getLiquidByWagon then
                  local d = remote.call("railtanker", "getLiquidByWagon", wagon)
                  if d.type ~= nil then
                    sum[d.type] = sum[d.type] or 0
                    sum[d.type] = sum[d.type] + d.amount
                    --self:flyingText(d.type..": "..d.amount, colors.YELLOW, {offset={x=wagon.position.x,y=wagon.position.y+1}})
                  end
                end
              end
            else
              --wagon is used by logistics railway
              local inventory = self.proxy_chests[i].get_inventory(defines.inventory.chest)
              local contents = inventory.get_contents()
              sum = addInventoryContents(sum, contents)
            end
          end
        end
        self.cargo = sum
        self.cargoUpdated = current_tick
      end
      return self.cargo
    end,

    updateState = function(self)
      --debugDump(util.formattime(game.tick,true).."@ "..getKeyByValue(defines.train_state, self.train.state),true)
      self.previousState = self.state
      self.state = self.train.state
      if self.previousState == defines.train_state.wait_station and
        (self.state == defines.train_state.on_the_path or self.state == defines.train_state.path_lost)
      then
        self.advancedState = train_state.left_station
        --debugDump(game.tick.." left_station",true)
      else
        self.advancedState = false
      end
    end,

    --- Update a trainline
    -- @return #boolean whether the line was updated
    updateLine = function(self)

      local oldmode = self.train.manual_mode
      if not self.line then
        return true
      end
      -- line was deleted
      if (self.line and not global.trainLines[self.line]) then
        if global.showFlyingText then
          self:flyingText("Dettached from line", colors.RED) --TODO localisation
        end
        local schedule = self.train.schedule

        --LOGGERS.main.log("Train detached from line " .. self.line .. "\t\t train: " .. self.name)
        self.line = false
        self.lineVersion = false
        self.rules = nil

        self.train.manual_mode = true
        self.train.schedule = schedule
        self.train.manual_mode = oldmode
        return true
      end

      local trainLine = global.trainLines[self.line]

      -- Already updated
      if trainLine and trainLine.changed <= self.lineVersion then
        --log(self.name .. " Up to date")
        return true
      end

      -- Skip when refueling
      if self.settings.autoRefuel and #self.train.schedule.records == inSchedule_reverse(self:refuelStation(), self.train.schedule) then
        if global.showFlyingText then
          self:flyingText("Skipping line update, refueling", colors.YELLOW)
        end
        log(self.name .. " refueling")
        return false
      end

      --debugDump("updating line "..self.line.." train: "..self.train.carriages[1].backer_name,true)
      if global.showFlyingText and self.lineVersion >= 0 then
        self:flyingText("updating schedule", colors.YELLOW) --TODO localisation
        log(self.name .. " Updating line")
      end

      local waitingAt = self.train.schedule.records and self.train.schedule.records[self.train.schedule.current] or {station=""}
      local schedule = {
        records= util.table.deepcopy(trainLine.records)
      }

      local inLine = inSchedule(waitingAt.station, schedule)
      log(self.name .. " inline " .. serpent.line(inLine, {comment=false}))

      self.settings.autoRefuel = trainLine.settings.autoRefuel
      self.rules = table.deepcopy(trainLine.rules)

      self.lineVersion = trainLine.changed

      if inLine then
        schedule.current = inLine
        self.train.schedule = schedule
        log(self.name .. " Updated line (inline)")

      else
        schedule.current = 1
        self.train.manual_mode = true
        self.train.schedule = schedule
        self.train.manual_mode = oldmode
        log(self.name .. " Updated line (not inline)")
      end


      --LOGGERS.main.log("Train updated schedule for line " .. self.line .. "\t\t train: " .. self.name)
      return true
    end,

    flyingText = function(self, msg, color, tbl)
      local s = global.showFlyingText
      local offset = 0
      if type(tbl) == "table" then
        s = tbl.show or s
        offset = tbl.offset or offset
      end
      local vehicle = (self.direction and self.direction == 0) and self.train.carriages[1] or self.train.carriages[#self.train.carriages]
      local pos = vehicle.position
      if type(offset) == "table" then
        pos = offset
      elseif type(offset) == "number" then
        pos.y = pos.y + offset
      end
      if s then self.train.carriages[1].surface.create_entity({name="flying-text", position=pos, text=msg, color=color}) end
    end
}
Train.__eq = function(trainA, trainB)
  return trainA.train.carriages[1] == trainB.train.carriages[1]
end
