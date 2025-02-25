-- Path of Building
--
-- Module: Trade Query Generator
-- Generates weighted trade queries for item upgrades
--

local dkjson = require "dkjson"
local curl = require("lcurl.safe")
local m_max = math.max

-- TODO generate these from data files
local itemCategoryTags = {
    ["Ring"] = { ["ring"] = true },
    ["Amulet"] = { ["amulet"] = true },
    ["Belt"] = { ["belt"] = true },
    ["Chest"] = { ["body_armour"] = true, ["str_armour"] = true, ["dex_armour"] = true, ["int_armour"] = true, ["str_int_armour"] = true, ["str_dex_armour"] = true, ["str_dex_int_armour"] = true },
    ["Helmet"] = { ["helmet"] = true, ["str_armour"] = true, ["dex_armour"] = true, ["int_armour"] = true, ["str_int_armour"] = true, ["str_dex_armour"] = true, ["str_dex_int_armour"] = true },
    ["Gloves"] = { ["gloves"] = true, ["str_armour"] = true, ["dex_armour"] = true, ["int_armour"] = true, ["str_int_armour"] = true, ["str_dex_armour"] = true, ["str_dex_int_armour"] = true },
    ["Boots"] = { ["boots"] = true, ["str_armour"] = true, ["dex_armour"] = true, ["int_armour"] = true, ["str_int_armour"] = true, ["str_dex_armour"] = true, ["str_dex_int_armour"] = true },
    ["Quiver"] = { ["quiver"] = true },
    ["Shield"] = { ["shield"] = true, ["focus"] = true, ["energy_shield"] = true, ["dex_shield"] = true, ["str_shield"] = true, ["str_int_shield"] = true, ["dex_int_shield"] = true, ["str_dex_shield"] = true },
    ["1HWeapon"] = { ["weapon"] = true, ["one_hand_weapon"] = true, ["onehand"] = true, ["axe"] = true, ["sword"] = true, ["rapier"] = true, ["mace"] = true, ["sceptre"] = true, ["dagger"] = true, ["rune_dagger"] = true, ["wand"] = true, ["claw"] = true },
    ["2HWeapon"] = { ["weapon"] = true, ["two_hand_weapon"] = true, ["twohand"] = true, ["staff"] = true, ["attack_staff"] = true, ["warstaff"] = true, ["bow"] = true,  ["axe"] = true, ["sword"] = true, ["mace"] = true, ["2h_sword"] = true, ["2h_axe"] = true, ["2h_mace"] = true },
    ["AbyssJewel"] = { ["default"] = true, ["abyss_jewel"] = true, ["abyss_jewel_melee"] = true, ["abyss_jewel_ranged"] = true, ["abyss_jewel_summoner"] = true, ["abyss_jewel_caster"] = true },
    ["BaseJewel"] = { ["default"] = true, ["not_int"] = true, ["not_str"] = true, ["not_dex"] = true },
    ["AnyJewel"] = { ["default"] = true, ["not_int"] = true, ["not_str"] = true, ["not_dex"] = true, ["abyss_jewel"] = true, ["abyss_jewel_melee"] = true, ["abyss_jewel_ranged"] = true, ["abyss_jewel_summoner"] = true, ["abyss_jewel_caster"] = true }
}

local tradeStatCategoryIndices = {
    ["Explicit"] = 2,
    ["Implicit"] = 3,
    ["Corrupted"] = 3,
    ["Scourge"] = 6
}

local influenceSuffixes = { "_shaper", "_elder", "_adjudicator", "_basilisk", "_crusader", "_eyrie"}
local influenceDropdownNames = { "None" }
local hasInfluenceModIds = { }
for i, curInfluenceInfo in ipairs(itemLib.influenceInfo) do
    influenceDropdownNames[i + 1] = curInfluenceInfo.display
    hasInfluenceModIds[i] = "pseudo.pseudo_has_" .. string.lower(curInfluenceInfo.display) .. "_influence"
end


-- This is not a complete list as most mods get caught with the find "Local" check, or don't overlap with non-local mods so we don't care. Some groups
-- are also shared between local and non-local mods, so a group only approach is not viable.
local localOnlyModGroups = {
    ["BaseLocalDefences"] = true,
    ["BaseLocalDefencesAndLife"] = true,
    ["LocalIncreasedPhysicalDamagePercentAndAccuracyRating"] = true,
    ["LocalPhysicalDamagePercent"] = true,
    ["DefencesPercent"] = true,
    ["DefencesPercentAndStunRecovery"] = true,
    ["LocalAttributeRequirements"] = true,
    ["DefencesPercentSuffix"] = true
}

local MAX_FILTERS = 36

local function logToFile(...)
    ConPrintf(...)
end

local TradeQueryGeneratorClass = newClass("TradeQueryGenerator", function(self, queryTab)
    self:InitMods()
    self.queryTab = queryTab
    self.itemsTab = queryTab.itemsTab
    self.calcContext = { }

    table.insert(main.onFrameFuncs, function()
        self:OnFrame()
    end)
end)

local function fetchStats()
    local tradeStats = ""
	local easy = common.curl.easy()
	easy:setopt_url("https://www.pathofexile.com/api/trade/data/stats")
    easy:setopt_useragent("Path of Building/" .. launch.versionNumber)
	easy:setopt_writefunction(function(data)
		tradeStats = tradeStats..data
		return true
	end)
	easy:perform()
	easy:close()
    return tradeStats
end

local function stripInfluenceSuffix(key)
    local influenceSuffixPos = nil
    for _, suffix in ipairs(influenceSuffixes) do
        influenceSuffixPos = key:find(suffix)
        if influenceSuffixPos ~= nil then
            return key:sub(1, influenceSuffixPos - 1)
        end
    end
    return key
end

local function canModSpawnForItemCategory(mod, tags)
    for i, key in ipairs(mod.weightKey) do
        local influenceStrippedKey = stripInfluenceSuffix(key)
        if key ~= "default" and mod.affix:find("Elevated") ~= nil and tags[influenceStrippedKey] == true then
            return true
        elseif key ~= "default" and mod.type == "Corrupted" and tags[influenceStrippedKey] == true then
            return true
        elseif mod.weightVal[i] > 0 and tags[influenceStrippedKey] == true then
            return true
        end
    end
    return false
end

function TradeQueryGeneratorClass:GenerateModData(mods, tradeQueryStatsParsed)
    for modId, mod in pairs(mods) do
        if localOnlyModGroups[mod.group] == true or (modId:find("Local") ~= nil and modId:find("Socketed") == nil) then -- skip all local mods other than socket level mods
            --logToFile("Skipping local mod: %s", modId)
            goto continue
        elseif modId:find("HellscapeDownside") ~= nil then -- skip scourge downsides, they often don't follow standard parsing rules, and should basically never be beneficial anyways
            goto continue
        end

        for index, modLine in ipairs(mod) do
            if modLine:find("Grants Level") then -- skip mods that grant skills, as they will often be overwhelmingly powerful but don't actually fit into the build
                goto nextModLine
            end

            local statOrder = modLine:find("Nearby Enemies have %-") ~= nil and mod.statOrder[index + 1] or mod.statOrder[index] -- hack to get minus res mods associated with the correct statOrder
            local modType = (mod.type == "Prefix" or mod.type == "Suffix") and "Explicit" or mod.type

            -- Special cases
            local specialCaseData = { }
            if statOrder == 1802 then
                specialCaseData.overrideModLine = "+#% Chance to Block"
                modLine = modLine .. " (Shields)"
            elseif statOrder == 1725 then
                specialCaseData.overrideModLineSingular = "You can apply an additional Curse"
                if modLine == specialCaseData.overrideModLineSingular then
                    modLine = "You can apply 1 additional Curses"
                end
            elseif statOrder == 1366 then
                specialCaseData.overrideModLineSingular = "Bow Attacks fire an additional Arrow"
                if modLine == specialCaseData.overrideModLineSingular then
                    modLine = "Bow Attacks fire 1 additional Arrows"
                end
            end

            -- If this is the first tier for this mod, find matching trade mod and init the entry
            if self.modData[modType][statOrder] == nil then
                local tradeMod = nil
                local matchStr = modLine:gsub("[#()0-9%-%+%.]","")
                for _, entry in ipairs(tradeQueryStatsParsed.result[tradeStatCategoryIndices[modType]].entries) do
                    if entry.text:gsub("[#()0-9%-%+%.]","") == matchStr then
                        tradeMod = entry
                        break
                    end
                end

                if tradeMod == nil then
                    logToFile("Unable to match %s mod: %s", modType, modLine)
                    goto nextModLine
                end

                self.modData[modType][statOrder] = { tradeMod = tradeMod, specialCaseData = specialCaseData }
            end

            -- tokenize the numerical variables for this mod and store the sign if there is one
            local tokens = { }
            local poundPos, tokenizeOffset = 0, 0
            while true do
                poundPos = self.modData[modType][statOrder].tradeMod.text:find("#", poundPos + 1)
                if poundPos == nil then
                    break
                end
                startPos, endPos, sign, min, max = modLine:find("([%+%-]?)%(?(%d+%.?%d*)%-?(%d*%.?%d*)%)?", poundPos + tokenizeOffset)

                if endPos == nil then
                    logToFile("Error extracting tokens from '%s' for tradeMod '%s'", modLine, self.modData[modType][statOrder].tradeMod.text)
                    goto nextModLine
                end

                tokenizeOffset = tokenizeOffset + (endPos - startPos)
                table.insert(tokens, min)
                table.insert(tokens, #max > 0 and tonumber(max) or tonumber(min))
                if sign ~= nil then
                    self.modData[modType][statOrder].sign = sign
                end
            end

            if #tokens ~= 0 and #tokens ~= 2 and #tokens ~= 4 then
                logToFile("Unexpected # of tokens found for mod: %s", mod[i])
                goto nextModLine
            end

            -- Update the min and max values available for each item category
            for category, tags in pairs(itemCategoryTags) do
                if canModSpawnForItemCategory(mod, tags) then
                    if self.modData[modType][statOrder][category] == nil then
                        self.modData[modType][statOrder][category] = { min = 999999, max = -999999 }
                    end

                    local modRange = self.modData[modType][statOrder][category]
                    if #tokens == 0 then
                        modRange.min = 1
                        modRange.max = 1
                    elseif #tokens == 2 then
                        modRange.min = math.min(modRange.min, tokens[1])
                        modRange.max = math.max(modRange.max, tokens[2])
                    elseif #tokens == 4 then
                        modRange.min = math.min(modRange.min, (tokens[1] + tokens[3]) / 2)
                        modRange.max = math.max(modRange.max, (tokens[2] + tokens[4]) / 2)
                    end
                end
            end
            ::nextModLine::
        end
        ::continue::
    end
end

function TradeQueryGeneratorClass:InitMods()
    local queryModFilePath = "Data/QueryMods.lua"

    local file = io.open(queryModFilePath,"r")
    if file then
        file:close()
        self.modData = LoadModule(queryModFilePath)
        return
    end

    self.modData = {
        ["Explicit"] = { },
        ["Implicit"] = { },
        ["Corrupted"] = { },
        ["Scourge"] = { },
    }

    -- originates from: https://www.pathofexile.com/api/trade/data/stats
    local tradeStats = fetchStats()
    tradeStats:gsub("\n", " ")
    local tradeQueryStatsParsed = dkjson.decode(tradeStats)

    -- explicit, corrupted, scourge, and jewel mods
    self:GenerateModData(data.itemMods.Item, tradeQueryStatsParsed)
    self:GenerateModData(data.veiledMods, tradeQueryStatsParsed)
    self:GenerateModData(data.itemMods.Jewel, tradeQueryStatsParsed)
    self:GenerateModData(data.itemMods.JewelAbyss, tradeQueryStatsParsed)

    -- Base item implicit mods. A lot of this code is duplicated from generateModData(), but with important small logical flow changes to handle the format differences
    for baseName, entry in pairs(data.itemBases) do
        if entry.implicit ~= nil then
            local stats = { }
            for modLine in string.gmatch(entry.implicit, "([^".."\n".."]+)") do
                if modLine:find("Grants Level") then -- skip mods that grant skills, as they will often be overwhelmingly powerful but don't actually fit into the build
                    goto continue
                end

                local modType = "Implicit"

                local tradeMod = nil
                local matchStr = modLine:gsub("[#()0-9%-%+%.]","")
                for _, entry in ipairs(tradeQueryStatsParsed.result[tradeStatCategoryIndices[modType]].entries) do
                    if entry.text:gsub("[#()0-9%-%+%.]","") == matchStr then
                        tradeMod = entry
                        break
                    end
                end

                if tradeMod == nil then
                    goto continue
                    logToFile("Unable to match %s mod: %s", modType, modLine)
                end
                -- base item implicits don't have stat orders, so use the trade mod id instead
                local statOrder = tradeMod.id

                -- If this is the first tier for this mod, init the entry
                if self.modData[modType][statOrder] == nil then
                    self.modData[modType][statOrder] = { tradeMod = tradeMod, specialCaseData = { } }
                end

                -- tokenize the numerical variables for this mod and store the sign if there is one
                local tokens = { }
                local poundPos, tokenizeOffset = 0, 0
                while true do
                    poundPos = self.modData[modType][statOrder].tradeMod.text:find("#", poundPos + 1)
                    if poundPos == nil then
                        break
                    end
                    startPos, endPos, sign, min, max = modLine:find("([%+%-]?)%(?(%d+%.?%d*)%-?(%d*%.?%d*)%)?", poundPos + tokenizeOffset)

                    if endPos == nil then
                        logToFile("Error extracting tokens from '%s' for tradeMod '%s'", modLine, self.modData[modType][statOrder].tradeMod.text)
                        goto continue
                    end

                    tokenizeOffset = tokenizeOffset + (endPos - startPos)
                    table.insert(tokens, min)
                    table.insert(tokens, #max > 0 and tonumber(max) or tonumber(min))
                    if sign ~= nil then
                        self.modData[modType][statOrder].sign = sign
                    end
                end

                if #tokens ~= 0 and #tokens ~= 2 and #tokens ~= 4 then
                    logToFile("Unexpected # of tokens found for mod: %s", modLine)
                    goto continue
                end

                -- Update the min and max values available for each item category
                for category, categoryTags in pairs(itemCategoryTags) do
                    local tagMatch = false
                    for tag, value in pairs(entry.tags) do
                        if tag ~= "default" and categoryTags[tag] == true then
                            tagMatch = true
                            break
                        end
                    end

                    if tagMatch then
                        if self.modData[modType][statOrder][category] == nil then
                            self.modData[modType][statOrder][category] = { min = 999999, max = -999999, subType = entry.subType }
                        end

                        local modRange = self.modData[modType][statOrder][category]
                        if #tokens == 0 then
                            modRange.min = 1
                            modRange.max = 1
                        elseif #tokens == 2 then
                            modRange.min = math.min(modRange.min, tokens[1])
                            modRange.max = math.max(modRange.max, tokens[2])
                        elseif #tokens == 4 then
                            modRange.min = math.min(modRange.min, (tokens[1] + tokens[3]) / 2)
                            modRange.max = math.max(modRange.max, (tokens[2] + tokens[4]) / 2)
                        end
                    end
                end
                ::continue::
            end
        end
    end

    local queryModsFile = io.open(queryModFilePath, 'w')
    queryModsFile:write("-- This file is automatically generated, do not edit!\n-- Stat data (c) Grinding Gear Games\n\n")
    queryModsFile:write("return " .. stringify(self.modData))
    queryModsFile:close()
end

function TradeQueryGeneratorClass:GenerateModWeights(modsToTest)
    local start = GetTime()
    for _, entry in pairs(modsToTest) do
        if entry[self.calcContext.itemCategory] ~= nil then
            if self.alreadyWeightedMods[entry.tradeMod.id] ~= nil then -- Don't calculate the same thing twice (can happen with corrupted vs implicit)
                goto continue
            elseif self.calcContext.options.includeTalisman == false and entry[self.calcContext.itemCategory].subType == "Talisman" then -- Talisman implicits take up a lot of query slots, so we have an option to skip them
                goto continue
            end

            -- Test with a value halfway between the min and max available for this mod in this slot. Note that this can generate slightly different values for the same mod as implicit vs explicit.
            local modValue = math.ceil((entry[self.calcContext.itemCategory].max - entry[self.calcContext.itemCategory].min) / 2 + entry[self.calcContext.itemCategory].min)
            local modValueStr = (entry.sign and entry.sign or "") .. tostring(modValue)

            -- Apply override text for special cases
            local modLine
            if modValue == 1 and entry.specialCaseData.overrideModLineSingular ~= nil then
                modLine = entry.specialCaseData.overrideModLineSingular
            elseif entry.specialCaseData.overrideModLine ~= nil then
                modLine = entry.specialCaseData.overrideModLine
            else
                modLine = entry.tradeMod.text
            end
            modLine = modLine:gsub("#",modValueStr)

            self.calcContext.testItem.explicitModLines[1] = { line = modLine, custom = true }
            self.calcContext.testItem:BuildAndParseRaw()

            if (self.calcContext.testItem.modList ~= nil and #self.calcContext.testItem.modList == 0) or (self.calcContext.testItem.slotModList ~= nil and #self.calcContext.testItem.slotModList[1] == 0 and #self.calcContext.testItem.slotModList[2] == 0) then
                logToFile("Failed to test %s mod: %s", self.calcContext.itemCategory, modLine)
            end

            local output = self.calcContext.calcFunc({ repSlotName = self.calcContext.slot.slotName, repItem = self.calcContext.testItem }, {})
            local meanDPSDiff = (GlobalCache.useFullDPS and output.FullDPS or m_max(output.TotalDPS, m_max(output.TotalDot,output.CombinedAvg)) or 0) - (self.calcContext.baseDPS or 0)
            if meanDPSDiff > 0.01 then
                table.insert(self.modWeights, { tradeModId = entry.tradeMod.id, weight = meanDPSDiff / modValue, meanDPSDiff = meanDPSDiff, invert = entry.sign == "-" and true or false })
                self.alreadyWeightedMods[entry.tradeMod.id] = true
            end

            local now = GetTime()
			if now - start > 50 then
                -- Would be nice to update x/y progress on the popup here, but getting y ahead of time has a cost, and the visual seems to update on a significant delay anyways so it's not very useful
				coroutine.yield()
				start = now
			end
        end
        ::continue::
    end
end

function TradeQueryGeneratorClass:OnFrame()
    if self.calcContext.co == nil then
        return
    end

    local res, errMsg = coroutine.resume(self.calcContext.co, self)
    if launch.devMode and not res then
        error(errMsg)
    end
    if coroutine.status(self.calcContext.co) == "dead" then
        self.calcContext.co = nil
        self:FinishQuery()
    end
end

function TradeQueryGeneratorClass:StartQuery(slot, options)
    -- Figure out what type of item we're searching for
    local existingItem = self.itemsTab.items[slot.selItemId]
    local testItemType = existingItem and existingItem.baseName or "Unset Amulet"
    local itemCategoryQueryStr
    local itemCategory
    if slot.slotName == "Weapon 2" or slot.slotName == "Weapon 1" then
        if existingItem then
            if existingItem.type == "Shield" then
                itemCategoryQueryStr = "armour.shield"
                itemCategory = "Shield"
            elseif existingItem.type == "Quiver" then
                itemCategoryQueryStr = "armour.quiver"
                itemCategory = "Quiver"
            elseif existingItem.type == "Bow" then
                itemCategoryQueryStr = "weapon.bow"
                itemCategory = "2HWeapon"
            elseif existingItem.type == "Staff" or existingItem.type:find("Two Handed") ~= nil then
                itemCategoryQueryStr = "weapon.twomelee"
                itemCategory = "2HWeapon"
            elseif existingItem.type == "Wand" or existingItem.type == "Dagger" or existingItem.type == "Sceptre" or existingItem.type == "Claw" or existingItem.type:find("One Handed") ~= nil then
                itemCategoryQueryStr = "weapon.one"
                itemCategory = "1HWeapon"
            else
                logToFile("'%s' is not supported for weighted trade query generation", existingItem.type)
                return
            end
        else
            -- Item does not exist in this slot so assume 1H weapon
            itemCategoryQueryStr = "weapon.one"
            itemCategory = "1HWeapon"
        end
    elseif slot.slotName == "Body Armour" then
        itemCategoryQueryStr = "armour.chest"
        itemCategory = "Chest"
    elseif slot.slotName == "Helmet" then
        itemCategoryQueryStr = "armour.helmet"
        itemCategory = "Helmet"
    elseif slot.slotName == "Gloves" then
        itemCategoryQueryStr = "armour.gloves"
        itemCategory = "Gloves"
    elseif slot.slotName == "Boots" then
        itemCategoryQueryStr = "armour.boots"
        itemCategory = "Boots"
    elseif slot.slotName == "Amulet" then
        itemCategoryQueryStr = "accessory.amulet"
        itemCategory = "Amulet"
    elseif slot.slotName == "Ring 1" or slot.slotName == "Ring 2" then
        itemCategoryQueryStr = "accessory.ring"
        itemCategory = "Ring"
    elseif slot.slotName == "Belt" then
        itemCategoryQueryStr = "accessory.belt"
        itemCategory = "Belt"
    elseif slot.slotName:find("Abyssal") ~= nil then
        itemCategoryQueryStr = "jewel.abyss"
        itemCategory = "AbyssJewel"
    elseif slot.slotName:find("Jewel") ~= nil then
        itemCategoryQueryStr = "jewel"
        itemCategory = options.jewelType .. "Jewel"
    else
        logToFile("'%s' is not supported for weighted trade query generation", existingItem and existingItem.type or "n/a")
        return
    end

	-- Create a temp item for the slot with no mods
	local itemRawStr = "Rarity: RARE\nStat Tester\n" .. testItemType
	local testItem = new("Item", itemRawStr)

    -- Apply any requests influences
    if options.influence1 > 1 then
        testItem[itemLib.influenceInfo[options.influence1 - 1].key] = true
    end
    if options.influence2 > 1 then
        testItem[itemLib.influenceInfo[options.influence2 - 1].key] = true
    end

    -- Set global cache full DPS
    local storedGlobalCacheDPSView = GlobalCache.useFullDPS
    GlobalCache.useFullDPS = GlobalCache.numActiveSkillInFullDPS > 0

    -- Calculate base output with a blank item
    local calcFunc, _ = self.itemsTab.build.calcsTab:GetMiscCalculator()
    local baseOutput = calcFunc({ repSlotName = slot.slotName, repItem = testItem }, {})
    local compDPS = GlobalCache.useFullDPS and baseOutput.FullDPS or m_max(baseOutput.TotalDPS, m_max(baseOutput.TotalDot, baseOutput.CombinedAvg))

	-- Test each mod one at a time and cache the normalized DPS diff to use as weight
    self.modWeights = { }
    self.alreadyWeightedMods = { }

    self.calcContext = {
        itemCategoryQueryStr = itemCategoryQueryStr,
        itemCategory = itemCategory,
        testItem = testItem,
        baseDPS = compDPS,
        calcFunc = calcFunc,
        options = options,
        slot = slot,
        globalCacheUseFullDPS = storedGlobalCacheDPSView
    }

    -- OnFrame will pick this up and begin the work
    self.calcContext.co = coroutine.create(self.ExecuteQuery)

    -- Open progress tracking blocker popup
    local controls = { }
    controls.progressText = new("LabelControl", {"TOP",nil,"TOP"}, 0, 30, 0, 16, string.format("Calculating Mod Weights..."))
	self.calcContext.popup = main:OpenPopup(280, 65, "Please Wait", controls)
end

function TradeQueryGeneratorClass:ExecuteQuery()
    self:GenerateModWeights(self.modData["Explicit"])
    self:GenerateModWeights(self.modData["Implicit"])
    if self.calcContext.options.includeCorrupted then
        self:GenerateModWeights(self.modData["Corrupted"])
    end
    if self.calcContext.options.includeScourge then
        self:GenerateModWeights(self.modData["Scourge"])
    end
end

function TradeQueryGeneratorClass:FinishQuery()
    -- Calc original item DPS without anoint or enchant, and use that diff as a basis for default min sum.
    local originalItem = self.itemsTab.items[self.calcContext.slot.selItemId]
    self.calcContext.testItem.explicitModLines = { }
    if originalItem then
        for _, modLine in ipairs(originalItem.explicitModLines) do
            table.insert(self.calcContext.testItem.explicitModLines, modLine)
        end
        for _, modLine in ipairs(originalItem.scourgeModLines) do
            table.insert(self.calcContext.testItem.explicitModLines, modLine)
        end
        for _, modLine in ipairs(originalItem.implicitModLines) do
            table.insert(self.calcContext.testItem.explicitModLines, modLine)
        end
    end
    self.calcContext.testItem:BuildAndParseRaw()

    local originalOutput = self.calcContext.calcFunc({ repSlotName = self.calcContext.slot.slotName, repItem = self.calcContext.testItem }, {})
    local currentDPSDiff =  (GlobalCache.useFullDPS and originalOutput.FullDPS or originalOutput.TotalDPS or 0) - (self.calcContext.baseDPS or 0)

    -- Restore global cache full DPS
    GlobalCache.useFullDPS = self.calcContext.globalCacheUseFullDPS

    -- This DPS diff value will generally be higher than the weighted sum of the same item, because the stats are all applied at once and can thus multiply off each other.
    -- So apply a modifier to get a reasonable min and hopefully approximate that the query will start out with small upgrades.
    local minWeight = currentDPSDiff * 0.7

    -- Sort by mean DPS diff rather than weight to more accurately prioritize stats that can contribute more
    table.sort(self.modWeights, function(a, b)
        return a.meanDPSDiff > b.meanDPSDiff
    end)

	-- Generate trade query str and open in browser
    local filters = 0
    local queryTable = {
        query = {
            filters = {
                type_filters = {
                    filters = {
                        category = { option = self.calcContext.itemCategoryQueryStr },
                        rarity = {  option = "nonunique" }
                    }
                }
            },
            status = { option = "online" },
            stats = {
                {
                    type = "weight",
                    value = { min = minWeight },
                    filters = { }
                }
            }
        },
        sort = { ["statgroup.0"] = "desc" },
        engine = "new"
    }

    local andFilters = { type = "and", filters = { } }

    local options = self.calcContext.options
    if options.influence1 > 1 then
        table.insert(andFilters.filters, { id = hasInfluenceModIds[options.influence1 - 1] })
        filters = filters + 1
    end
    if options.influence2 > 1 then
        table.insert(andFilters.filters, { id = hasInfluenceModIds[options.influence2 - 1] })
        filters = filters + 1
    end

    if #andFilters.filters > 0 then
        table.insert(queryTable.query.stats, andFilters)
    end

    for _, entry in pairs(self.modWeights) do
        table.insert(queryTable.query.stats[1].filters, { id = entry.tradeModId, value = { weight = (entry.invert == true and entry.weight * -1 or entry.weight) } })
        filters = filters + 1
        if filters == MAX_FILTERS then
            break
        end
    end

    local queryJson = dkjson.encode(queryTable)
    self.requesterCallback(self.requesterContext, queryJson)

    -- Close blocker popup
    main:ClosePopup()
end

function TradeQueryGeneratorClass:RequestQuery(slot, context, callback)
    self.requesterCallback = callback
    self.requesterContext = context

    local controls = { }
    local options = { }
    local popupHeight = 95

    local isJewelSlot = slot.slotName:find("Jewel") ~= nil
    local isAbyssalJewelSlot = slot.slotName:find("Abyssal") ~= nil
    local isAmuletSlot = slot.slotName == "Amulet"

    controls.includeCorrupted = new("CheckBoxControl", {"TOP",nil,"TOP"}, 0, 30, 18, "Corrupted Mods:", function(state) end)
    controls.includeCorrupted.state = (self.lastIncludeCorrupted == nil or self.lastIncludeCorrupted == true)

    local includeScourge = self.queryTab.pbLeagueRealName == "Standard" or self.queryTab.pbLeagueRealName == "Hardcore"
    if not isJewelSlot and not isAbyssalJewelSlot and includeScourge then
        controls.includeScourge = new("CheckBoxControl", {"TOPRIGHT",controls.includeCorrupted,"BOTTOMRIGHT"}, 0, 5, 18, "Scourge Mods:", function(state) end)
        controls.includeScourge.state = (self.lastIncludeScourge == nil or self.lastIncludeScourge == true)

        popupHeight = popupHeight + 23
    end

    if isAmuletSlot then
        controls.includeTalisman = new("CheckBoxControl", {"TOPRIGHT",includeScourge and controls.includeScourge or controls.includeCorrupted,"BOTTOMRIGHT"}, 0, 5, 18, "Talisman Mods:", function(state) end)
        controls.includeTalisman.state = (self.lastIncludeTalisman == nil or self.lastIncludeTalisman == true)

        popupHeight = popupHeight + 23
    end

    if isJewelSlot then
        controls.jewelType = new("DropDownControl", {"TOPLEFT",controls.includeCorrupted,"BOTTOMLEFT"}, 0, 5, 100, 18, { "Any", "Base", "Abyss" }, function(index, value) end)
        controls.jewelType.selIndex = self.lastJewelType or 1
        controls.jewelTypeLabel = new("LabelControl", {"RIGHT",controls.jewelType,"LEFT"}, -5, 0, 0, 16, "Jewel Type:")

        popupHeight = popupHeight + 23
    elseif not isAbyssalJewelSlot then
        controls.influence1 = new("DropDownControl", {"TOPLEFT",controls.includeTalisman and controls.includeTalisman or (includeScourge and controls.includeScourge) or controls.includeCorrupted,"BOTTOMLEFT"}, 0, 5, 100, 18, influenceDropdownNames, function(index, value) end)
        controls.influence1.selIndex = self.lastInfluence1 or 1
        controls.influence1Label = new("LabelControl", {"RIGHT",controls.influence1,"LEFT"}, -5, 0, 0, 16, "Influence 1:")

        controls.influence2 = new("DropDownControl", {"TOPLEFT",controls.influence1,"BOTTOMLEFT"}, 0, 5, 100, 18, influenceDropdownNames, function(index, value) end)
        controls.influence2.selIndex = self.lastInfluence2 or 1
        controls.influence2Label = new("LabelControl", {"RIGHT",controls.influence2,"LEFT"}, -5, 0, 0, 16, "Influence 2:")

        popupHeight = popupHeight + 46
    end

	controls.generateQuery = new("ButtonControl", { "BOTTOM", nil, "BOTTOM" }, -45, -10, 80, 20, "Execute", function()
		main:ClosePopup()

        if controls.includeCorrupted then
            self.lastIncludeCorrupted, options.includeCorrupted = controls.includeCorrupted.state, controls.includeCorrupted.state
        end
        if controls.includeScourge then
            self.lastIncludeScourge, options.includeScourge = controls.includeScourge.state, controls.includeScourge.state
        end
        if controls.includeTalisman then
            self.lastIncludeTalisman, options.includeTalisman = controls.includeTalisman.state, controls.includeTalisman.state
        end
        if controls.influence1 then
            self.lastInfluence1, options.influence1 = controls.influence1.selIndex, controls.influence1.selIndex
        else
            options.influence1 = 1
        end
        if controls.influence2 then
            self.lastInfluence2, options.influence2 = controls.influence2.selIndex, controls.influence2.selIndex
        else
            options.influence2 = 1
        end
        if controls.jewelType then
            self.lastJewelType = controls.jewelType.selIndex
            options.jewelType = controls.jewelType.list[controls.jewelType.selIndex]
        end

        self:StartQuery(slot, options)
    end)
	controls.cancel = new("ButtonControl", { "BOTTOM", nil, "BOTTOM" }, 45, -10, 80, 20, "Cancel", function()
		main:ClosePopup()
	end)
	main:OpenPopup(280, popupHeight, "Query Options", controls)
end