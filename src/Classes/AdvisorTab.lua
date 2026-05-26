-- Classes/AdvisorTab.lua
-- Advisor tab: ranks reachable passive nodes by actual DPS delta and suggests support gems.

local m_floor = math.floor
local m_min   = math.min
local m_max   = math.max
local t_insert = table.insert
local t_sort   = table.sort
local s_format = string.format

local AdvisorTabClass = newClass("AdvisorTab", function(self, build)
	self.build          = build
	self.outputRevision = -1   -- force first rebuild
	self.nodeList       = {}   -- scored reachable nodes
	self.mainSkillInfo  = nil  -- {name, dps, group}
	self.gemSuggestions = {}   -- ranked support gem names
	self.scrollY        = 0
	self.totalContentH  = 0
end)

function AdvisorTabClass:RebuildCache()
	local build = self.build
	if build.outputRevision == self.outputRevision then return end
	self.outputRevision = build.outputRevision
	self:_rebuildNodes()
	self:_rebuildSkills()
end

-- Enumerate reachable unallocated nodes and score each by actual DPS delta.
-- Uses CalcsTab's fast node calculator, which already accounts for the current
-- skill setup, equipped items, and all other build state.
function AdvisorTabClass:_rebuildNodes()
	local build = self.build
	local nodeCalc, baseOutput = build.calcsTab:GetNodeCalculator()
	if not nodeCalc or not baseOutput then
		self.nodeList = {}
		build.advisorNodeIds = {}
		return
	end

	local baseDPS  = baseOutput.TotalDPS or baseOutput.CombinedDPS or 0
	local baseLife = baseOutput.Life or 0

	local scored = {}
	for nodeId, node in pairs(build.spec.nodes) do
		if not node.alloc
		   and not node.ascendancyName
		   and node.type ~= "ClassStart"
		   and node.type ~= "AscendClassStart"
		   and node.type ~= "Socket"
		   and node.type ~= "Mastery"
		   and not node.isBlighted then
			-- 1-hop reachability check
			local reachable = false
			for _, linkedId in ipairs(node.linked or {}) do
				if build.spec.allocNodes[linkedId] then
					reachable = true
					break
				end
			end
			if reachable then
				local ok, output = pcall(nodeCalc, {node})
				if ok and output then
					local dpsDelta  = (output.TotalDPS or output.CombinedDPS or 0) - baseDPS
					local lifeDelta = (output.Life or 0) - baseLife
					-- DPS is primary; life adds a small tiebreaker so pure-survivability
					-- nodes still rank above zero-impact nodes.
					local score = dpsDelta + lifeDelta * 0.001
					t_insert(scored, {
						nodeId    = nodeId,
						node      = node,
						score     = score,
						dpsDelta  = dpsDelta,
						lifeDelta = lifeDelta,
					})
				end
			end
		end
	end

	t_sort(scored, function(a, b) return a.score > b.score end)

	self.nodeList = {}
	for i = 1, m_min(10, #scored) do
		self.nodeList[i] = scored[i]
	end

	-- Expose ranked node IDs to PassiveTreeView for light-blue highlight rings.
	build.advisorNodeIds = {}
	for i, entry in ipairs(self.nodeList) do
		build.advisorNodeIds[entry.nodeId] = i
	end
end

-- Inspect the main skill's damage-type flags and score unequipped support gems
-- from game data by keyword relevance to those flags.
function AdvisorTabClass:_rebuildSkills()
	local build = self.build
	self.mainSkillInfo  = nil
	self.gemSuggestions = {}

	local mainEnv = build.calcsTab and build.calcsTab.mainEnv
	if not mainEnv then return end

	-- Damage-type flags from the main skill's stat set
	local flags = {}
	local mainSkill = mainEnv.player and mainEnv.player.mainSkill
	if mainSkill and mainSkill.activeEffect and mainSkill.activeEffect.statSet then
		flags = mainSkill.activeEffect.statSet.skillFlags or {}
	end

	local mainGroup = build.skillsTab.socketGroupList[build.mainSocketGroup]
	if not mainGroup then return end

	local mainGemIdx = mainGroup.mainActiveSkill or 1
	local mainGem    = mainGroup.gemList and mainGroup.gemList[mainGemIdx]
	local mainDPS    = build.calcsTab.mainOutput and build.calcsTab.mainOutput.TotalDPS or 0

	self.mainSkillInfo = {
		name  = mainGem and mainGem.nameSpec or "Unknown",
		dps   = mainDPS,
		group = mainGroup,
	}

	-- Index already-equipped support gems so we don't suggest them again.
	local usedSupports = {}
	if mainGroup.gemList then
		for _, gem in ipairs(mainGroup.gemList) do
			local isSupport = gem.gemData and gem.gemData.tags and gem.gemData.tags.support
			if isSupport then
				usedSupports[(gem.nameSpec or ""):lower()] = true
			end
		end
	end

	-- Build keyword → weight table from the detected damage type.
	local weights = {
		["damage"]       = 1,
		["penetration"]  = 2,
		["critical"]     = 1,
		["faster"]       = 1,
	}
	if flags["isFire"]       then weights["fire"]        = 3 end
	if flags["isCold"]       then weights["cold"]        = 3 end
	if flags["isLightning"]  then weights["lightning"]   = 3 end
	if flags["isChaos"]      then weights["chaos"]       = 3 end
	if flags["isPhysical"]   then weights["physical"]    = 3 end
	if flags["isSpell"]      then weights["spell"]       = 2 end
	if flags["isAttack"]     then weights["attack"]      = 2 end
	if flags["isProjectile"] then weights["projectile"]  = 2 end

	-- Score every support gem in the game data against the keyword weights.
	local suggestions = {}
	if build.data and build.data.gems then
		for _, gemData in pairs(build.data.gems) do
			if gemData.tags and gemData.tags.support then
				local gemName = (gemData.name or ""):lower()
				if not usedSupports[gemName] then
					local haystack = gemName .. " " .. (gemData.tagString or ""):lower()
					local score = 0
					for kw, wt in pairs(weights) do
						if haystack:find(kw, 1, true) then
							score = score + wt
						end
					end
					if score > 0 then
						t_insert(suggestions, {name = gemData.name, score = score})
					end
				end
			end
		end
	end

	t_sort(suggestions, function(a, b) return a.score > b.score end)
	for i = 1, m_min(6, #suggestions) do
		self.gemSuggestions[i] = suggestions[i]
	end
end

function AdvisorTabClass:Draw(viewPort, inputEvents)
	local vx, vy, vw, vh = viewPort.x, viewPort.y, viewPort.width, viewPort.height

	-- Scroll
	for _, event in ipairs(inputEvents) do
		if event.type == "KeyDown" then
			if event.key == "WHEELUP" then
				self.scrollY = m_max(0, self.scrollY - 30)
			elseif event.key == "WHEELDOWN" then
				local maxScroll = m_max(0, self.totalContentH - vh + 20)
				self.scrollY = m_min(maxScroll, self.scrollY + 30)
			end
		end
	end

	-- Background
	SetDrawLayer(nil, 1)
	SetDrawColor(0.08, 0.08, 0.08)
	DrawImage(nil, vx, vy, vw, vh)

	local PAD  = 12
	local GAP  = 16
	local colW = m_floor((vw - PAD * 2 - GAP) / 2)
	local lx   = vx + PAD
	local rx   = vx + PAD + colW + GAP
	local scroll = self.scrollY

	SetDrawLayer(nil, 5)

	-- ── Left column: Passive Node Suggestions ────────────────────────────────

	local lY = vy + PAD - scroll

	SetDrawColor(0.4, 0.75, 1.0)
	DrawString(lx, lY, "LEFT", 18, "VAR BOLD", "Passive Node Suggestions")
	lY = lY + 24

	SetDrawColor(0.4, 0.75, 1.0, 0.5)
	DrawImage(nil, lx, lY, colW, 1)
	lY = lY + 8

	if #self.nodeList == 0 then
		SetDrawColor(0.5, 0.5, 0.5)
		DrawString(lx, lY, "LEFT", 14, "VAR", "Allocate some passives to see suggestions.")
		lY = lY + 22
	else
		for i, entry in ipairs(self.nodeList) do
			local node = entry.node
			local rowY = lY

			-- Alternating row tint
			if i % 2 == 0 then
				SetDrawColor(0.11, 0.11, 0.13)
				DrawImage(nil, lx, rowY - 2, colW, 40)
			end

			-- Rank badge
			if i == 1 then
				SetDrawColor(0.3, 0.8, 1.0)
			else
				SetDrawColor(0.5, 0.5, 0.6)
			end
			DrawString(lx, rowY + 4, "LEFT", 13, "VAR BOLD", "#"..i)

			-- Node name (colour by type)
			if node.isKeystone then
				SetDrawColor(1.0, 0.85, 0.3)
			elseif node.isNotable then
				SetDrawColor(0.8, 0.9, 1.0)
			else
				SetDrawColor(1, 1, 1)
			end
			DrawString(lx + 28, rowY, "LEFT", 15, "VAR BOLD", node.name or "Unknown")

			-- Type label + first stat description
			local badge = node.isKeystone and "Keystone" or node.isNotable and "Notable" or "Node"
			SetDrawColor(0.45, 0.45, 0.5)
			DrawString(lx + 28, rowY + 17, "LEFT", 11, "VAR", badge)

			if node.sd and node.sd[1] then
				local sdText = node.sd[1]
				if #sdText > 40 then sdText = sdText:sub(1, 37).."..." end
				SetDrawColor(0.65, 0.65, 0.65)
				DrawString(lx + 84, rowY + 17, "LEFT", 11, "VAR", sdText)
			end

			-- DPS delta (right-aligned)
			if entry.dpsDelta >= 0.05 then
				SetDrawColor(0.3, 1.0, 0.4)
				DrawString(lx + colW - 4, rowY, "RIGHT", 13, "VAR", s_format("+%.1f DPS", entry.dpsDelta))
			elseif entry.dpsDelta <= -0.05 then
				SetDrawColor(1.0, 0.4, 0.3)
				DrawString(lx + colW - 4, rowY, "RIGHT", 13, "VAR", s_format("%.1f DPS", entry.dpsDelta))
			else
				SetDrawColor(0.5, 0.5, 0.5)
				DrawString(lx + colW - 4, rowY, "RIGHT", 13, "VAR", "+0 DPS")
			end

			-- Life delta
			if math.abs(entry.lifeDelta) >= 1 then
				SetDrawColor(0.85, 0.4, 0.4)
				DrawString(lx + colW - 4, rowY + 17, "RIGHT", 11, "VAR", s_format("%+.0f Life", entry.lifeDelta))
			end

			lY = lY + 42
		end
	end

	-- ── Right column: Skills & Gem Suggestions ───────────────────────────────

	local rY = vy + PAD - scroll

	SetDrawColor(0.4, 1.0, 0.55)
	DrawString(rx, rY, "LEFT", 18, "VAR BOLD", "Skills & Gem Suggestions")
	rY = rY + 24

	SetDrawColor(0.4, 1.0, 0.55, 0.5)
	DrawImage(nil, rx, rY, colW, 1)
	rY = rY + 8

	-- Main skill block
	if self.mainSkillInfo then
		local info = self.mainSkillInfo

		SetDrawColor(0.85, 0.85, 0.85)
		DrawString(rx, rY, "LEFT", 14, "VAR BOLD", "Main Skill")
		rY = rY + 18

		SetDrawColor(1, 1, 1)
		DrawString(rx + 8, rY, "LEFT", 13, "VAR", info.name)
		rY = rY + 16

		if info.dps > 0 then
			SetDrawColor(0.7, 0.7, 0.7)
			DrawString(rx + 8, rY, "LEFT", 12, "VAR", "DPS: "..s_format("%.1f", info.dps))
			rY = rY + 16
		end

		-- Current support gems in the main group
		local group = info.group
		local hasSupports = false
		if group and group.gemList then
			for _, gem in ipairs(group.gemList) do
				local isSupport = gem.gemData and gem.gemData.tags and gem.gemData.tags.support
				if isSupport and gem.enabled ~= false then
					if not hasSupports then
						SetDrawColor(0.7, 0.7, 0.7)
						DrawString(rx + 8, rY, "LEFT", 12, "VAR", "Active supports:")
						rY = rY + 15
						hasSupports = true
					end
					SetDrawColor(0.55, 0.65, 0.95)
					DrawString(rx + 16, rY, "LEFT", 12, "VAR", "- "..(gem.nameSpec or "Unknown"))
					rY = rY + 15
				end
			end
		end
		if not hasSupports then
			SetDrawColor(0.5, 0.5, 0.5)
			DrawString(rx + 8, rY, "LEFT", 12, "VAR", "No support gems in main group.")
			rY = rY + 16
		end

		rY = rY + 10
	else
		SetDrawColor(0.5, 0.5, 0.5)
		DrawString(rx, rY, "LEFT", 13, "VAR", "Set a main skill to see suggestions.")
		rY = rY + 20
	end

	-- Suggested supports
	SetDrawColor(0.85, 0.85, 0.85)
	DrawString(rx, rY, "LEFT", 14, "VAR BOLD", "Suggested Supports")
	rY = rY + 18

	SetDrawColor(0.4, 1.0, 0.55, 0.4)
	DrawImage(nil, rx, rY, colW, 1)
	rY = rY + 6

	if #self.gemSuggestions == 0 then
		SetDrawColor(0.5, 0.5, 0.5)
		DrawString(rx, rY, "LEFT", 13, "VAR", "No suggestions — set a main skill first.")
		rY = rY + 20
	else
		for i, sug in ipairs(self.gemSuggestions) do
			if i % 2 == 0 then
				SetDrawColor(0.11, 0.11, 0.13)
				DrawImage(nil, rx, rY - 2, colW, 20)
			end
			SetDrawColor(0.35, 0.9, 0.45)
			DrawString(rx, rY, "LEFT", 13, "VAR", "+ "..(sug.name or ""))
			rY = rY + 19
		end
	end

	rY = rY + 16
	SetDrawColor(0.3, 0.3, 0.35)
	DrawString(rx, rY, "LEFT", 11, "VAR", "Active skill analysis — coming in a future update.")
	rY = rY + 20

	-- Update scroll bounds
	self.totalContentH = m_max(lY, rY) - vy + scroll
end
