--[[--
-- One of my more recent productions; an overhaul for an existing UI system.
-- Keep in mind this is out of its context and relevant UI, modules, and services do not exist here.
-- Yes I am aware I desperately need to split this up as seen in my to do list :p

-- Example of a modular inventory system for Roblox
-- Features:
-- - Hotbar/backpack rendering
-- - Drag-and-drop slot swapping
-- - Keybind handling and rebinding
-- - Team-based slot preferences (saved to server)
-- Demonstrates:
-- - State management
-- - UI tweening/interaction
-- - Networking (RemoteEvents/RemoteFunctions)
-- - Input handling

]]

-- @classmod Inventory Controller
-- @author Bluegamerdog
-- @date 28.09.2025

--[[--
TODO:
- Split into
  - Controller -- Logic and state
  - UI -- Rendering
  - Input -- User interactions
  - Utils -- Misc functions
]]

local Inventory = {}

----------------------------------
--		DEPENDENCIES
----------------------------------

local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local StarterGui = game:GetService("StarterGui")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local import = require(ReplicatedStorage.Shared.import)(script)
local UserInterface = import("Controllers/InterfaceController")

local Network = import("Util/Network")
local Maid = import("Util/Maid") ---@module Maid

local Settings = import("Shared/Common/Settings")

----------------------------------
--	SERVICES & PRIMARY OBJECTS
----------------------------------

local LocalPlayer = Players.LocalPlayer

local RF_Inventory: RemoteFunction = Network.GetRemoteFunction("RF_Inventory")
local RE_Inventory: RemoteEvent = Network.GetRemoteEvent("RE_Inventory")

local MainFrame: Frame = UserInterface:GetFrame("Inventory")
local UISlot: Frame = MainFrame.Templates:WaitForChild("Slot")
local SpecialSlot: Frame = MainFrame.Templates:WaitForChild("SpecialSlot")
local EmptySlot: Frame = MainFrame.Templates:WaitForChild("EmptySlot")
local ExtendSlot: Frame = MainFrame.SlotsHolder:WaitForChild("ExtendSlot")

----------------------------------
--		CONFIG VARIABLES
----------------------------------

local DEBUG = true

Inventory.Layout = {
	cols = 10, -- frames per row
	rows = { hotbar = 1, backpack = 2 },
	spacerCols = { 10 }, -- per-row reserved columns (e.g. last col is a spacer)
}
Inventory._layoutCache = nil

Inventory.MAX_HOTBAR_SLOTS = 10 -- One row
Inventory.MAX_BACKPACK_SLOTS = 20 -- Two rows
Inventory.MAX_INVENTORY_SLOTS = Inventory.MAX_HOTBAR_SLOTS + Inventory.MAX_BACKPACK_SLOTS -- Three rows total currently
Inventory.MAX_SPECIAL_SLOTS = 8 -- One row

Inventory.State = {
	EditMode = false, -- Is currently dragging between slots?
	EditItem = nil, -- If there is a current edit item, what is the *current* inventory slot it occupies
	EditSlotFrame = nil, -- Just so we know what UI frame is currently being moved

	EquippedItem = nil, -- The equipped tool instance
	EquippedSlot = nil, -- What is the current equipped slot - if nil, then none.
	Equipped = false, -- State boolean

	Backpack = false, -- Closed by default
	CurrentSlots = {},
}

Inventory.KeyCodes = {
	[Enum.KeyCode.One] = 1,
	[Enum.KeyCode.Two] = 2,
	[Enum.KeyCode.Three] = 3,
	[Enum.KeyCode.Four] = 4,
	[Enum.KeyCode.Five] = 5,
	[Enum.KeyCode.Six] = 6,
	[Enum.KeyCode.Seven] = 7,
	[Enum.KeyCode.Eight] = 8,
	[Enum.KeyCode.Nine] = 9,
	[Enum.KeyCode.Zero] = "Toggle Expansion",
}

----------------------------------
--		MISC VARIABLES
----------------------------------

local Sprite = nil

local HoveringOver = nil
local ChangedPreferences = false
local LastSend = time()
local expansionDebounce = false

local lastRenderEvent = ""
local lastRenderTime = 0

local WeaponUi = LocalPlayer.PlayerGui:WaitForChild("Gun", 5) -- Fetched because it needs to be moved up when the backpack is opened

Inventory._maid = Maid.new()
Inventory._toolConns = setmetatable({}, { __mode = "k" })

Inventory._PreferencesByTeam = {}

Inventory._cachedSortedItems = nil
Inventory._cachedSpecialItems = nil
Inventory._cachedPreferences = nil
Inventory._inventorySlots = {} -- [1-18]
Inventory._specialSlots = {} -- [1-9]

----------------------------------
--		LOCAL FUNCTIONS
----------------------------------

local function dprint(...)
	if DEBUG then
		print(...)
	end
end

local function dwarn(...)
	if DEBUG then
		warn(...)
	end
end

local function _equip(slot, item: Tool, humanoid: Humanoid)
	if not item or not item.Parent then
		return
	end
	Inventory.State.Equipped = true
	Inventory.State.EquippedSlot = slot
	Inventory.State.EquippedItem = item
	if humanoid then
		pcall(function()
			humanoid:EquipTool(item)
		end)
	end
end

local function _unequip(humanoid: Humanoid)
	Inventory.State.Equipped = false
	Inventory.State.EquippedSlot = nil
	Inventory.State.EquippedItem = nil
	if humanoid then
		humanoid:UnequipTools()
	end
end

local function getKeyCodeString(keycode: Enum.KeyCode)
	local keyCodeString = UserInputService:GetStringForKeyCode(keycode)
	if keyCodeString == "" or keyCodeString == " " then
		keyCodeString = keycode.Name
	end
	return keyCodeString or "?"
end

local function updateSlotList(slotArray, dataArray)
	for i, slot in ipairs(slotArray) do
		local item = dataArray[i]
		Inventory:SetSlotItem(slot, item or nil)
	end
end

local function expandedInventoryVisual(isBackpackOpen: boolean)
	local uiGrid = MainFrame.SlotsHolder.UIGridLayout

	local tarPosSlotHolder
	local tarPosSpecialHolder
	local tarPosKillFeedback

	if isBackpackOpen then -- Close
		tarPosSpecialHolder = UDim2.new(0, 0, -0.4, 0)
		tarPosSlotHolder = UDim2.new(0, 0, 0, 0)
		tarPosKillFeedback = UDim2.new(0.279, 0, 0.8, 0)
	else -- Open
		tarPosSpecialHolder = UDim2.new(0, 0, -0.4, -(uiGrid.AbsoluteContentSize.Y - uiGrid.AbsoluteCellSize.Y))
		tarPosSlotHolder = UDim2.new(0, 0, 0, -(uiGrid.AbsoluteContentSize.Y - uiGrid.AbsoluteCellSize.Y))
		tarPosKillFeedback = UDim2.new(0.279, 0, 0.8, -(uiGrid.AbsoluteContentSize.Y - uiGrid.AbsoluteCellSize.Y))
	end

	MainFrame.SpecialHolder:TweenPosition(tarPosSpecialHolder, "Out", "Back", 0.2)
	MainFrame.SlotsHolder:TweenPosition(tarPosSlotHolder, "Out", "Back", 0.3)

	if WeaponUi and WeaponUi:FindFirstChild("KillFeedback") then -- Extra check because external UI
		WeaponUi.KillFeedback:TweenPosition(tarPosKillFeedback, "Out", "Back", 0.2)
	end
end

local function toggleExpandedInventory()
	if expansionDebounce or not Inventory.BackpackUsed then
		return
	end
	expansionDebounce = true

	local isBackpackOpen = Inventory.State.Backpack

	expandedInventoryVisual(isBackpackOpen)

	task.wait(0.3)

	-- Flip the state
	Inventory.State.Backpack = not isBackpackOpen
	expansionDebounce = false
end

local function getTeamKey(): string
	return LocalPlayer.Team and LocalPlayer.Team.Name or "Pending"
end

local function destroySprite()
	if Sprite then
		Sprite:Destroy()
		Sprite = nil
	end
end

----------------------------------
--		PRIVATE FUNCTIONS
----------------------------------

-- To avoid doing math every time, just do it once on :Init() and cache it.
function Inventory:_buildLayoutCache()
	local L = self.Layout -- sorry being lazy here
	local cols = L.cols or 10
	local hotbarRows = (L.rows and L.rows.hotbar) or 1
	local backpackRows = (L.rows and L.rows.backpack) or 0
	local totalRows = hotbarRows + backpackRows

	local spacerCols = L.spacerCols or {} -- e.g. {10}
	local spacersPerRow = #spacerCols
	local usablePerRow = cols - spacersPerRow

	local totalFrames = totalRows * cols
	local totalUsable = totalRows * usablePerRow

	-- reserved indices as a set: [10]=true, [20]=true, ...
	local reservedSet = {}
	for r = 0, totalRows - 1 do
		local base = r * cols
		for i = 1, spacersPerRow do
			reservedSet[base + spacerCols[i]] = true
		end
	end

	-- hotbar usable indices (row 1, skip spacers)
	local hotbarUsable = {}
	for c = 1, cols do
		if not reservedSet[c] then
			hotbarUsable[#hotbarUsable + 1] = c
		end
	end

	-- backpack row descriptors (start/filler) (assumes one spacer col; extend if needed)
	local backpackRowsDesc = {}
	local spacerCol1 = spacerCols[1]
	if backpackRows > 0 and spacerCol1 then
		for r = hotbarRows + 1, totalRows do
			local base = (r - 1) * cols
			backpackRowsDesc[#backpackRowsDesc + 1] = {
				start = base + 1,
				filler = base + spacerCol1,
			}
		end
	end

	self._layoutCache = {
		cols = cols,
		totalRows = totalRows,
		spacersPerRow = spacersPerRow,
		usablePerRow = usablePerRow,
		totalFrames = totalFrames,
		totalUsable = totalUsable,
		reservedSet = reservedSet,
		hotbarUsable = hotbarUsable,
		backpackRows = backpackRowsDesc,
	}
end

function Inventory:_ensureLayout()
	if not self._layoutCache then
		self:_buildLayoutCache()
	end
	return self._layoutCache
end

-- optional, in case you *ever* tweak Layout at runtime
function Inventory:_invalidateLayout()
	self._layoutCache = nil
end

function Inventory:_totalRows()
	return self:_ensureLayout().totalRows
end

function Inventory:_spacersPerRow()
	return self:_ensureLayout().spacersPerRow
end

function Inventory:GetTotalSlotFrames()
	return self:_ensureLayout().totalFrames
end

function Inventory:GetUsableCapacity()
	return self:_ensureLayout().totalUsable
end

function Inventory:_getReservedIndexSet()
	return self:_ensureLayout().reservedSet
end

function Inventory:_getBackpackRowDescriptors()
	return self:_ensureLayout().backpackRows
end

function Inventory:_getHotbarUsableIndices()
	return self:_ensureLayout().hotbarUsable
end

function Inventory:_handleInputObject(inputObject: InputObject)
	local key = self.KeyCodes[inputObject.KeyCode]
	if not key then
		return
	end

	if self.State.EditMode or not MainFrame.Visible then
		return
	end

	local char = LocalPlayer.Character
	if not char then
		return
	end

	local function hasBlockedState()
		return CollectionService:HasTag(LocalPlayer, "PlayerDetained")
			or CollectionService:HasTag(LocalPlayer, "PushingCart")
			or CollectionService:HasTag(LocalPlayer, "PushingPmover")
			or CollectionService:HasTag(char, "RidingCar")
			or CollectionService:HasTag(char, "DrivingCar")
			or CollectionService:HasTag(char, "CarryingObject")
			or char:GetAttribute("Stunned") == true
			or char:GetAttribute("LayingInStretcher") == true
	end

	if hasBlockedState() then
		return
	end

	if key == "Toggle Expansion" then -- Not ideal but lowkey idk how/where else to add this lol
		toggleExpandedInventory()
		return
	end

	local item = self.State.CurrentSlots[key]
	if not item then
		return
	end

	local humanoid = char:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end

	-- If currently equipped
	if self.State.Equipped then
		if self.State.EquippedSlot == key then
			-- Unequip current item
			_unequip(humanoid)
			return
		else -- Unequip other item to be able to equip new item
			_unequip(humanoid)
		end
	end

	if not (item and item.Parent) then
		return
	end

	-- Equip new tool
	_equip(key, item, humanoid)
end

function Inventory:_fetchAllTools()
	local tools = {
		all = {},
		slot = {},
		special = {},
	}

	local function collectTools(container)
		for _, item in ipairs(container:GetChildren()) do
			if item:IsA("Tool") then
				table.insert(tools.all, item)
				if item:GetAttribute("SlotSpecial") then
					table.insert(tools.special, item)
				else
					table.insert(tools.slot, item)
				end
			end
		end
	end

	local char = LocalPlayer.Character
	if char then
		collectTools(char)
	end

	local Backpack = LocalPlayer:WaitForChild("Backpack")
	collectTools(Backpack)

	return tools
end

function Inventory:_handleButtonUX(Button)
	local ButtonFadeIn = TweenService:Create(
		Button,
		TweenInfo.new(0.1, Enum.EasingStyle.Cubic, Enum.EasingDirection.In),
		{ BackgroundColor3 = Color3.fromRGB(3, 3, 3) }
	)
	local TextFadeIn = TweenService:Create(
		Button.Num,
		TweenInfo.new(0.1, Enum.EasingStyle.Cubic, Enum.EasingDirection.In),
		{ TextTransparency = 0 }
	)
	local ButtonFadeOut = TweenService:Create(
		Button,
		TweenInfo.new(0.1, Enum.EasingStyle.Cubic, Enum.EasingDirection.Out),
		{ BackgroundColor3 = Color3.fromRGB(27, 27, 27) }
	)
	local TextFadeOut = TweenService:Create(
		Button.Num,
		TweenInfo.new(0.1, Enum.EasingStyle.Cubic, Enum.EasingDirection.In),
		{ TextTransparency = 0.3 }
	)

	Button.Button.MouseButton1Down:Connect(function()
		ButtonFadeIn:Play()
		TextFadeIn:Play()
	end)

	Button.Button.MouseButton1Up:Connect(function()
		ButtonFadeIn:Play()
		TextFadeIn:Play()
	end)

	Button.Button.MouseEnter:Connect(function()
		ButtonFadeIn:Play()
		TextFadeIn:Play()
		HoveringOver = Button.LayoutOrder
	end)

	Button.Button.MouseLeave:Connect(function()
		ButtonFadeOut:Play()
		TextFadeOut:Play()
		if HoveringOver == Button.LayoutOrder then
			HoveringOver = nil
		end
	end)
end

function Inventory:_trackTool(tool: Instance)
	if not tool or not tool:IsA("Tool") then
		return
	end
	if self._toolConns[tool] then
		self._toolConns[tool]:Disconnect()
		self._toolConns[tool] = nil
	end
	local conn = tool.Destroying:Once(function()
		if self.State.EquippedItem == tool then
			local hum = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
			_unequip(hum)
		end
		self:FetchItems(true)
		self:RenderHotbar("ToolDestroyed")
		self._toolConns[tool] = nil
	end)
	self._toolConns[tool] = conn
	self._maid:GiveTask(conn)
end

function Inventory:_shouldReject(tool: Tool): boolean
	local isSpeicalTool = tool:GetAttribute("SlotSpecial")
	return (isSpeicalTool and self:IsSpecialFull()) or self:IsInventoryFull()
end

----------------------------------
--		PUBLIC FUNCTIONS
----------------------------------

-- VISUAL MANAGEMENT
function Inventory:RemoveSlotHighlights()
	for _, Item in pairs(MainFrame.SlotsHolder:GetChildren()) do
		if Item:IsA("Frame") and Item.Name ~= ExtendSlot.Name and Item.Name ~= EmptySlot.Name then
			Item.Num.TextColor3 = Color3.new(1, 1, 1)
			Item.Num.TextTransparency = 0.3

			Item.Label.TextColor3 = Color3.new(1, 1, 1)
			Item.UIStroke.Thickness = 0
		end
	end
	for _, Item in pairs(MainFrame.SpecialHolder:GetChildren()) do
		if Item:IsA("Frame") and Item.Name ~= ExtendSlot.Name and Item.Name ~= EmptySlot.Name then
			Item.Label.TextColor3 = Color3.new(1, 1, 1)
			Item.UIStroke.Thickness = 0
		end
	end
end

local tween
function Inventory:ApplySlotHighlight(slotFrame, isActive)
	if tween then
		tween:Cancel()
	end

	local stroke = slotFrame:FindFirstChild("UIStroke")
	local label = slotFrame:FindFirstChild("Label")
	local numLabel = slotFrame:FindFirstChild("Num")

	if stroke then
		local tweenGoal = { Thickness = isActive and 2 or 0 }
		tween =
			TweenService:Create(stroke, TweenInfo.new(0.1, Enum.EasingStyle.Cubic, Enum.EasingDirection.In), tweenGoal)
		tween:Play()
	end

	if label then
		label.TextColor3 = isActive and Color3.fromRGB(194, 194, 194) or Color3.new(1, 1, 1)
	end

	if numLabel then
		numLabel.TextColor3 = isActive and Color3.fromRGB(194, 194, 194) or Color3.new(1, 1, 1)
		numLabel.TextTransparency = isActive and 0 or 0.3
	end
end

function Inventory:HighlightEquippedSlot(slot)
	self:RemoveSlotHighlights()
	if slot then
		self:ApplySlotHighlight(slot, true)
	end
end

-- FETCHING

function Inventory:IsInventoryFull()
	local slotTools = select(1, self:FetchItems())
	return #slotTools >= self:GetUsableCapacity()
end

function Inventory:IsHotbarFull()
	local slotTools = select(1, self:FetchItems())
	-- hotbar usable = cols - spacersPerRow (one row)
	local usableHotbar = self:_ensureLayout().cols - self:_ensureLayout().spacersPerRow
	return #slotTools >= usableHotbar
end

function Inventory:IsBackpackFull()
	local slotTools = select(1, self:FetchItems())
	local layout = self:_ensureLayout()
	local usableBackpack = layout.usablePerRow * (self.Layout.rows.backpack or 0)
	return (#slotTools - math.min(#slotTools, layout.usablePerRow)) >= usableBackpack
end

function Inventory:IsSpecialFull()
	local _, special = self:FetchItems()
	return #special >= self.MAX_SPECIAL_SLOTS
end

function Inventory:FetchItems(force)
	if self._cachedSortedItems and not force then
		return self._cachedSortedItems, self._cachedSpecialItems
	end

	local tools = self:_fetchAllTools()

	self._cachedSortedItems, self._cachedSpecialItems = tools.slot, tools.special
	return self._cachedSortedItems, self._cachedSpecialItems
end

-- Essentially; load and cache every time you switch teams so you dont cache unnessary data
-- // Update server's cache from client when changes are made
-- // Then the server only saves everything to datastore once when the player leaves.
function Inventory:GetSlotPreferences()
	-- Load all teams at once if not cached
	if not self._AllPreferencesLoaded then
		local data = RF_Inventory:InvokeServer("GetSlotPreferences") or {}
		for tKey, prefs in pairs(data) do
			self._PreferencesByTeam[tKey] = prefs
		end
		self._AllPreferencesLoaded = true
	end

	local teamKey = getTeamKey()
	if not teamKey then
		return {}
	end

	-- Return preferences for current team
	return self._PreferencesByTeam[teamKey] or {}
end

-- Get sorted and slotted inventory
function Inventory:GetInventoryItemsSlotted()
	local allItems, specialSlots = self:FetchItems()
	local preferences = self:GetSlotPreferences()
	local RESERVED = self:_getReservedIndexSet()

	-- Build a set of live instances
	local live = {}
	for _, it in ipairs(allItems) do
		live[it] = true
	end

	-- Start from a cleaned copy of previous slots
	local slots = {}
	for idx, it in pairs(self.State.CurrentSlots or {}) do
		if it and it.Parent and live[it] then
			slots[idx] = it
		end
	end

	-- 1) place by preference
	for _, item in ipairs(allItems) do
		local preferredSlot = preferences[item.Name]
		if preferredSlot and not RESERVED[preferredSlot] then
			slots[preferredSlot] = item
		end
	end

	-- 2) fill remaining
	local placed = {}
	for _, v in pairs(slots) do
		placed[v] = true
	end
	local counter = 1
	for _, item in ipairs(allItems) do
		if not placed[item] then
			while slots[counter] or RESERVED[counter] do
				counter += 1
			end
			slots[counter] = item
			placed[item] = true
		end
	end

	self.State.CurrentSlots = slots
	return slots, specialSlots
end

function Inventory:GetHotbarItems() -- Gets the sorted and slotted inventory for the hotbar
	local totalSlots, specialSlots = self:GetInventoryItemsSlotted()
	local slots = {}
	for i = 1, 9 do
		table.insert(slots, i, totalSlots[i])
	end
	return slots, specialSlots
end

function Inventory:GetBackpackItems()
	local totalSlots, _ = self:GetInventoryItemsSlotted()
	local slots = {}
	for n, item in ipairs(totalSlots) do
		if n > 9 then
			slots[#slots + 1] = item
		end
	end
	table.sort(slots, function(a, b)
		return a.Name:lower() < b.Name:lower()
	end)
	return slots
end

--

function Inventory:GetKeyCodeFromNum(Num: number)
	for KeyCode, Value in pairs(self.KeyCodes) do
		if Value == Num then
			return KeyCode
		end
	end
end

function Inventory:SetSlotItem(slot, item)
	if item then -- Enable
		slot.Label.Text = item.Name

		slot.Visible = true
		slot.ObjectInstance.Value = item

		-- Highlight here
		if self.State.EquippedItem == item then
			self:HighlightEquippedSlot(slot)
		end
	else -- Disable
		slot.Visible = false
		slot.ObjectInstance.Value = nil
	end
end

function Inventory:_renderBackpackRows(backpackItems)
	local rows = self:_getBackpackRowDescriptors()
	local reserved = self:_getReservedIndexSet()
	local cols = self:_ensureLayout().cols
	local idx = 1

	for _, row in ipairs(rows) do
		local hasItemInRow = false
		for c = 0, cols - 1 do
			local slotIndex = row.start + c
			if not reserved[slotIndex] then
				local item = backpackItems[idx]
				self:SetSlotItem(self._inventorySlots[slotIndex], item)
				if item then
					hasItemInRow = true
				end
				idx += 1
			end
		end
		-- show the filler only if the row contains at least one item
		if self._inventorySlots[row.filler] then
			self._inventorySlots[row.filler].Visible = hasItemInRow
		end
	end
end

function Inventory:RenderHotbar(source: string)
	if not MainFrame.Visible then
		dprint(`Returning MAINFRAME NOT VISIBLE {source}`)
		return
	end

	if source then
		local now = time()
		if source == lastRenderEvent and now - lastRenderTime < 0.05 then
			dprint("Returning double event", source, lastRenderEvent)
			return
		end

		lastRenderEvent = source
		lastRenderTime = now
	end

	self._pendingRender = true
	self._queuedRenderTick = time() -- mark most recent change

	if self._isRendering then
		return
	end

	dwarn("RENDER:", source)

	self._isRendering = true

	task.spawn(function()
		while self._pendingRender do
			self._pendingRender = false
			local renderTick = self._queuedRenderTick

			local HotbarItems, SpecialSlotItems = self:GetHotbarItems()
			local BackpackItems = self:GetBackpackItems()

			if ChangedPreferences and time() - LastSend >= 15 then
				LastSend = time()
				ChangedPreferences = false
				task.spawn(function()
					RF_Inventory:InvokeServer("UpdateLoadout", self._PreferencesByTeam)
				end)
			end

			-- ===== Fill the HOTBAR row using layout (skip spacer columns) =====
			local RESERVED = self:_getReservedIndexSet()
			local cols = self.Layout.cols
			local hotbarItemIdx = 1
			for c = 1, cols do
				local slotIndex = c -- hotbar is row 1 → base is 0
				if not RESERVED[slotIndex] then
					self:SetSlotItem(self._inventorySlots[slotIndex], HotbarItems[hotbarItemIdx])
					hotbarItemIdx += 1
				else
					-- Keep spacer invisible; don't touch it otherwise
					if self._inventorySlots[slotIndex] then
						self._inventorySlots[slotIndex].Visible = false
					end
				end
			end

			-- ===== Fill BACKPACK rows =====
			self:_renderBackpackRows(BackpackItems)

			-- ===== Special slots =====
			updateSlotList(self._specialSlots, SpecialSlotItems)

			-- ===== Highlight state =====
			if not self.State.EquippedItem then
				self:HighlightEquippedSlot()
			end

			-- ===== Extend button & expansion visual =====
			self.BackpackUsed = #BackpackItems > 0
			dprint("BACKPACK USED: ", self.BackpackUsed, #BackpackItems, (#BackpackItems > 0))
			ExtendSlot.Visible = self.BackpackUsed
			if self.BackpackUsed and self.State.Backpack then
				expandedInventoryVisual(false) -- Update the visual should the number of backpack items cause another item row to start
			end

			-- if another render was queued while we ran, repeat
			if self._queuedRenderTick ~= renderTick then
				self._pendingRender = true
			end
		end

		self._isRendering = false
	end)
end

function Inventory:HandleItemDrop(tool: Tool)
	RF_Inventory:InvokeServer("DropItem", tool)
end

function Inventory:ResetCache()
	self._cachedSortedItems = nil
	self._cachedSpecialItems = nil
	self.State.CurrentSlots = {}
end

function Inventory:Show()
	self._maid:DoCleaning()
	destroySprite()

	local function handleInventoryChange(tool, added: boolean, backpack: boolean)
		if not tool:IsA("Tool") then
			return
		end

		local action = added and "Equipped" or "Unequipped"
		-- local source = backpack and "Backpack" or "Character"

		-- Force inventory refresh
		self:FetchItems(true)

		if self:_shouldReject(tool) then
			self:HandleItemDrop(tool)
			return
		end

		self:RenderHotbar(`{action}_{tool.Name}`) -- fires before _equip
	end

	-- Track new/removed tools
	self._maid:GiveTask(LocalPlayer.Backpack.ChildAdded:Connect(function(item)
		self:_trackTool(item)
		handleInventoryChange(item, false, true) -- Unequipped
	end))

	self._maid:GiveTask(LocalPlayer.Backpack.ChildRemoved:Connect(function(item)
		handleInventoryChange(item, true, true) -- Equipped
	end))

	-- Initial scan for tools
	for _, tool in ipairs(LocalPlayer.Backpack:GetChildren()) do
		self:_trackTool(tool)
		handleInventoryChange(tool, false, true)
	end

	local function handleCharacter()
		local character = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()

		self:ResetCache()

		-- Track new/removed tools
		local addedConn = character.ChildAdded:Connect(function(child)
			self:_trackTool(child)
			handleInventoryChange(child, true, false)
		end)
		local removedConn = character.ChildRemoved:Connect(function(child)
			handleInventoryChange(child, false, false)
		end)

		-- Initial scan for tools
		for _, tool in ipairs(character:GetChildren()) do
			self:_trackTool(tool)
			handleInventoryChange(tool, true, false)
		end

		self._maid:GiveTask(addedConn)
		self._maid:GiveTask(removedConn)

		-- Clean up when character is destroyed
		self._maid:GiveTask(character.Destroying:Once(function()
			dprint("DESTOYING, CLEANIN UP")
			if self.State.Equipped then
				task.spawn(_unequip) -- When you die, the removing connection is deleting for detecting unequipping so we'll do it manually
			end
			self._maid[addedConn] = nil
			self._maid[removedConn] = nil
		end))
	end

	-- Character changes
	self._maid:GiveTask(LocalPlayer.CharacterAdded:Connect(handleCharacter))

	self._maid:GiveTask(LocalPlayer:GetPropertyChangedSignal("Team"):Connect(function()
		self:ResetCache()
		self:FetchItems(true)
		self:RenderHotbar("TeamChanged")
	end))

	if LocalPlayer.Character then
		handleCharacter()
	end

	MainFrame.Visible = true

	self:FetchItems(true)
	self:RenderHotbar("Show")
end

function Inventory:Hide()
	MainFrame.Visible = false
	destroySprite()
	self._maid:DoCleaning()
end

function Inventory:RenderEmptySlotFrame(slotNumber)
	local slotFrame = EmptySlot:Clone()
	slotFrame.Name = `EmptySlot` -- {slotNumber}
	slotFrame.Visible = false
	slotFrame.LayoutOrder = slotNumber

	slotFrame.Active = false
	slotFrame.Interactable = false

	slotFrame.Parent = MainFrame.SlotsHolder
	return slotFrame
end

function Inventory:RenderInventorySlotFrame(slotNumber)
	-- Create
	local slotFrame = UISlot:Clone()
	slotFrame.Name = `Slot {slotNumber}`
	slotFrame.Visible = false
	slotFrame.LayoutOrder = slotNumber

	-- Configure
	local slotNumberTextLabel = slotFrame:FindFirstChild("Num")
	local keycode = self:GetKeyCodeFromNum(slotNumber)
	slotNumberTextLabel.Text = keycode and getKeyCodeString(keycode) or ""
	slotNumberTextLabel.TextColor3 = Color3.new(1, 1, 1)
	slotNumberTextLabel.TextTransparency = 0.3
	slotFrame.UIStroke.Thickness = 0
	slotFrame.Label.Text = ""

	-- Extras
	local objectValue = Instance.new("ObjectValue")
	objectValue.Name = "ObjectInstance"
	objectValue.Parent = slotFrame

	self:_handleButtonUX(slotFrame)

	-- Add Interation Handlers

	local InstanceNonce = time()
	slotFrame.Button.MouseButton1Down:Connect(function()
		local nonce = time()
		InstanceNonce = nonce
		task.wait(0.35)
		if InstanceNonce == nonce then
			self.State.EditMode = true
			self.State.EditItem = slotNumber
			self.State.EditSlotFrame = slotFrame

			if Sprite then
				Sprite:Destroy()
			end
			Sprite = slotFrame:Clone()
			Sprite.Name = "Sprite"
			Sprite.Size = UDim2.new(0, slotFrame.AbsoluteSize.X, 0, slotFrame.AbsoluteSize.Y)

			local MousePosition = UserInputService:GetMouseLocation()
			local Offset = MousePosition - slotFrame.AbsolutePosition
			local Scale = Offset / slotFrame.AbsoluteSize

			Sprite.AnchorPoint = Scale
			Sprite.Position = UDim2.new(0, MousePosition.X, 0, MousePosition.Y)
			slotFrame.BackgroundTransparency = 0.6

			Sprite.Parent = MainFrame.Parent
		end
	end)

	slotFrame.Button.MouseButton1Up:Connect(function()
		if
			CollectionService:HasTag(LocalPlayer, "PlayerDetained")
			or CollectionService:HasTag(LocalPlayer.Character, "RidingCar")
			or CollectionService:HasTag(LocalPlayer.Character, "DrivingCar")
			or CollectionService:HasTag(LocalPlayer.Character, "CarryingObject")
			or LocalPlayer.Character:GetAttribute("Stunned") == true
			or LocalPlayer.Character:GetAttribute("LayingInStretcher") == true
		then
			return
		end
		InstanceNonce = nil
		if not self.State.EditMode then
			if not MainFrame.Visible then
				return
			end
			if self.State.Equipped then
				if self.State.EquippedSlot == slotNumber then
					_unequip(LocalPlayer.Character.Humanoid)
					return
				else
					_unequip(LocalPlayer.Character.Humanoid)
				end
			end
			if objectValue.Value then
				_equip(slotNumber, objectValue.Value, LocalPlayer.Character.Humanoid)
			end
		end
	end)

	-- Lastly, parent it
	slotFrame.Parent = MainFrame.SlotsHolder

	return slotFrame
end

function Inventory:RenderSpecialSlotFrame(slotNumber)
	local slotFrame = SpecialSlot:Clone()
	slotFrame.Name = `SpecialSlot_{slotNumber}`
	slotFrame.Visible = false
	slotFrame.LayoutOrder = slotNumber

	slotFrame.Label.Text = ""
	slotFrame.UIStroke.Thickness = 0

	-- Extras
	local objectValue = Instance.new("ObjectValue")
	objectValue.Name = "ObjectInstance"
	objectValue.Parent = slotFrame

	slotFrame.Button.MouseButton1Up:Connect(function()
		if not MainFrame.Visible or (objectValue.Value and not objectValue.Value:GetAttribute("UseableSlot")) then
			return
		end
		if self.State.Equipped then
			if self.State.EquippedSlot == slotNumber then
				_unequip(LocalPlayer.Character.Humanoid)
				return
			else
				_unequip(LocalPlayer.Character.Humanoid)
			end
		end

		if objectValue.Value then
			_equip(slotNumber, objectValue.Value, LocalPlayer.Character.Humanoid)
		end
	end)

	-- Lastly, parent it
	slotFrame.Parent = MainFrame.SpecialHolder

	return slotFrame
end

function Inventory:Start() end

function Inventory:Init()
	-- Disable Roblox's Inventory UI
	StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)

	-- Set up the UI
	MainFrame.SlotsHolder.UIGridLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center

	UISlot.Visible = false
	SpecialSlot.Visible = false

	ExtendSlot.Button.MouseButton1Click:Connect(function()
		toggleExpandedInventory()
	end)

	-- Clear any frames left over from testing/UI devs
	for _, child in MainFrame.SlotsHolder:GetChildren() do
		if child:IsA("Frame") and child.Name ~= ExtendSlot.Name then
			child:Destroy()
		end
	end

	for _, child in MainFrame.SpecialHolder:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end

	self:_ensureLayout()

	-- Precreate inventory slots
	do
		local RESERVED = self:_getReservedIndexSet()
		for i = 1, self:GetTotalSlotFrames() do
			if RESERVED[i] then
				table.insert(self._inventorySlots, self:RenderEmptySlotFrame(i))
			else
				table.insert(self._inventorySlots, self:RenderInventorySlotFrame(i))
			end
		end
	end

	-- Precreate special slots
	for i = 1, self.MAX_SPECIAL_SLOTS do
		table.insert(self._specialSlots, self:RenderSpecialSlotFrame(i))
	end

	-- SET UP INTERACTION HANDLING
	self:_handleButtonUX(ExtendSlot)
	expandedInventoryVisual(true)

	-- Handle Inputs
	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessedEvent: boolean)
		if gameProcessedEvent then
			return
		end
		if input.UserInputType == Enum.UserInputType.Keyboard and self.KeyCodes[input.KeyCode] then
			self:_handleInputObject(input)
		end
	end)

	UserInputService.InputChanged:Connect(function(input: InputObject, gameProcessedEvent: boolean)
		if input.UserInputType == Enum.UserInputType.MouseMovement and MainFrame.Visible then
			if Sprite then
				Sprite.Position = UDim2.new(0, input.Position.X, 0, input.Position.Y)
			end
		end
	end)

	UserInputService.InputEnded:Connect(function(input: InputObject, gameProcessedEvent: boolean)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			if self.State.EditMode then -- Handle edit mode
				self.State.EditMode = false -- Exit edit mode
				if Sprite then
					Sprite:Destroy()
				end

				local fromSlot = self.State.EditItem
				local toSlot = HoveringOver

				if fromSlot and self.State.CurrentSlots[fromSlot] and toSlot then
					local itemFrom = self.State.CurrentSlots[fromSlot]
					local itemTo = self.State.CurrentSlots[toSlot]

					local preferences = self:GetSlotPreferences()

					-- Swap in preferences
					preferences[itemFrom.Name] = toSlot
					if itemTo then
						preferences[itemTo.Name] = fromSlot
					end
					self._PreferencesByTeam[getTeamKey()] = preferences
					ChangedPreferences = true

					self.State.CurrentSlots[toSlot] = itemFrom
					self.State.CurrentSlots[fromSlot] = itemTo

					-- Update UI instantly
					self:SetSlotItem(self._inventorySlots[toSlot], itemFrom)
					self:SetSlotItem(self._inventorySlots[fromSlot], itemTo)
				end

				if self.State.EditSlotFrame then
					self.State.EditSlotFrame.BackgroundTransparency = 0.2
					self.State.EditSlotFrame = nil
				end
			end
		end
	end)

	RE_Inventory.OnClientEvent:Connect(function(...)
		local Args = { ... }
		if Args[1] == "UpdateInventory" then
			self:RenderHotbar("ServerRequest")
		elseif Args[1] == "HideInventory" then
			self:Hide()
		elseif Args[1] == "ShowInventory" then
			self:Show()
		end
	end)

	task.spawn(function()
		local function bindSetting(name, target)
			Settings:GetAndBind(name, LocalPlayer, function(newKey)
				for key, value in pairs(self.KeyCodes) do
					if value == target then
						self.KeyCodes[key] = nil
					end
				end
				self.KeyCodes[newKey] = target
			end)
		end

		for i = 1, 9 do
			bindSetting(`Slot {i}`, i)
		end

		bindSetting("Toggle Expansion", "Toggle Expansion")
	end)
end

----------------------------------
--		MAIN CODE
----------------------------------

return Inventory
