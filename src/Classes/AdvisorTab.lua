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

-- Returns true if a node's unlock constraints are all satisfied.
local function constraintsMet(node, specNodes)
	if not node.unlockConstraint then return true end
	for _, reqId in ipairs(node.unlockConstraint.nodes) do
		local req = specNodes[reqId]
		if req and not req.alloc then return false end
	end
	return true
end

-- Returns true if a node is a "stepping stone" — a jewel socket or attribute node
-- that has no meaningful DPS mods itself but sits between allocated nodes and
-- potentially strong targets.
local function isSteppingStone(node)
	return node.type == "Socket" or node.isAttribute == true
end

-- Score reachable nodes using getMiscCalculator + CalculateCombinedOffDefStat,
-- identical to PoB's own heat map. Also looks one hop further when a 1-hop
-- reachable node is a jewel socket or attribute node, evaluating the combined
-- gain of (stepping stone + target) as a single 2-point investment.
function AdvisorTabClass:_rebuildNodes()
	local build  = self.build
	local spec   = build.spec
	local calcFunc, calcBase = build.calcsTab:GetMiscCalculator()
	if not calcFunc or not calcBase then
		self.nodeList        = {}
		build.advisorNodeIds = {}
		build.advisorViaIds  = {}
		return
	end

	local scored   = {}
	local seen     = {}   -- nodeId → true once scored, avoids duplicates
	local stones   = {}   -- stepping-stone node objects reachable in 1 hop

	-- ── Pass 1: score all meaningful 1-hop reachable nodes ───────────────────
	for nodeId, node in pairs(spec.nodes) do
		if not node.alloc
		   and not node.ascendancyName
		   and node.type ~= "ClassStart"
		   and node.type ~= "AscendClassStart"
		   and node.type ~= "Mastery"
		   and not node.isBlighted then

			local reachable = false
			for _, ln in ipairs(node.linked or {}) do
				if ln.alloc then reachable = true; break end
			end

			if reachable and not constraintsMet(node, spec.nodes) then
				reachable = false
			end

			if reachable then
				if isSteppingStone(node) then
					-- Collect for Pass 2 regardless of modKey
					stones[nodeId] = node
				end

				-- Score if this node has actual mods (attribute nodes do, sockets don't)
				if (node.modKey or "") ~= "" and not isSteppingStone(node) then
					local ok, output = pcall(calcFunc, { addNodes = { [node] = true } })
					if ok and output then
						local off, def = build.calcsTab:CalculateCombinedOffDefStat(output, calcBase)
						off = off or 0; def = def or 0
						t_insert(scored, {
							nodeId  = nodeId, node = node,
							score   = off + def * 0.3,
							offence = off, defence = def,
							via     = nil,
						})
						seen[nodeId] = true
					end
				end
			end
		end
	end

	-- ── Pass 2: 2-hop targets behind jewel sockets / attribute nodes ─────────
	for _, stone in pairs(stones) do
		for _, target in ipairs(stone.linked or {}) do
			local tid = target.id
			if tid and not target.alloc and not seen[tid]
			   and not target.ascendancyName
			   and target.type ~= "ClassStart"
			   and target.type ~= "AscendClassStart"
			   and target.type ~= "Socket"   -- don't chain through two sockets
			   and target.type ~= "Mastery"
			   and not target.isBlighted
			   and (target.modKey or "") ~= ""
			   and constraintsMet(target, spec.nodes) then

				-- Evaluate combined gain of allocating stone + target together
				local ok, output = pcall(calcFunc, { addNodes = { [stone] = true, [target] = true } })
				if ok and output then
					local off, def = build.calcsTab:CalculateCombinedOffDefStat(output, calcBase)
					off = off or 0; def = def or 0
					t_insert(scored, {
						nodeId  = tid, node = target,
						score   = off + def * 0.3,
						offence = off, defence = def,
						via     = stone,
					})
					seen[tid] = true
				end
			end
		end
	end

	t_sort(scored, function(a, b) return a.score > b.score end)

	self.nodeList = {}
	for i = 1, m_min(10, #scored) do
		self.nodeList[i] = scored[i]
	end

	-- Expose node IDs to PassiveTreeView.
	-- advisorNodeIds: rank 1–10 for the actual target nodes.
	-- advisorViaIds:  stepping-stone nodes that must be taken first.
	build.advisorNodeIds = {}
	build.advisorViaIds  = {}
	for i, entry in ipairs(self.nodeList) do
		build.advisorNodeIds[entry.nodeId] = i
		if entry.via and not build.advisorNodeIds[entry.via.id] then
			build.advisorViaIds[entry.via.id] = true
		end
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
			DrawString(lx + 28, rowY, "LEFT", 15, "VAR BOLD", node.dn or node.name or "Unknown")

			-- Type label + via label for 2-hop entries
			local badge = node.isKeystone and "Keystone" or node.isNotable and "Notable" or "Node"
			if entry.via then
				local viaLabel = entry.via.type == "Socket" and "via Socket" or "via Attr"
				badge = badge .. "  [" .. viaLabel .. "]"
			end
			SetDrawColor(0.45, 0.45, 0.5)
			DrawString(lx + 28, rowY + 17, "LEFT", 11, "VAR", badge)

			if node.sd and node.sd[1] then
				local sdText = node.sd[1]
				if #sdText > 40 then sdText = sdText:sub(1, 37).."..." end
				SetDrawColor(0.65, 0.65, 0.65)
				DrawString(lx + 84, rowY + 17, "LEFT", 11, "VAR", sdText)
			end

			-- Offence score (right-aligned) — relative CombinedDPS gain
			local offPct = entry.offence * 100
			if offPct >= 0.05 then
				SetDrawColor(0.3, 1.0, 0.4)
				DrawString(lx + colW - 4, rowY, "RIGHT", 13, "VAR", s_format("+%.2f%% DPS", offPct))
			elseif offPct <= -0.05 then
				SetDrawColor(1.0, 0.4, 0.3)
				DrawString(lx + colW - 4, rowY, "RIGHT", 13, "VAR", s_format("%.2f%% DPS", offPct))
			else
				SetDrawColor(0.5, 0.5, 0.5)
				DrawString(lx + colW - 4, rowY, "RIGHT", 13, "VAR", "~0% DPS")
			end

			-- Defence score
			local defPct = entry.defence * 100
			if defPct >= 0.01 then
				SetDrawColor(0.4, 0.7, 1.0)
				DrawString(lx + colW - 4, rowY + 17, "RIGHT", 11, "VAR", s_format("+%.2f%% Def", defPct))
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
