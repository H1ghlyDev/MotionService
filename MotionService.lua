--!strict
-- Connected Discord-GitHub
-- Discord: h1ghly_dev
-- Roblox: ralle1108
-- MotionService Framework
-- Advanced animation framework featuring:
-- Custom easing solver, bezier motion, animation state handling,
-- conflict resolution, property tracking, batching, delay scheduler,
-- interpolation system, and real-time interactive showcase support.
-- Written entirely in Luau by Highly_Dev.

local RunService = game:GetService("RunService")

type EasingDirection = "In" | "Out" | "InOut"
type EasingStyle =
	"Linear"
| "Quad"
| "Cubic"
| "Quart"
| "Quint"
| "Sine"
| "Expo"
| "Back"
| "Bounce"
| "Elastic"

type Tweenable = number | Vector2 | Vector3 | UDim2 | Color3 | CFrame

type TweenOptions = {
	EasingStyle: EasingStyle?,
	EasingDirection: EasingDirection?,
	Delay: number?,
	AutoDestroy: boolean?,
	OnUpdate: ((alpha: number, easedAlpha: number, value: Tweenable) -> ())?,
	OnComplete: (() -> ())?,
}

type MotionConfig = {
	DefaultDuration: number?,
	DefaultEasingStyle: EasingStyle?,
	DefaultEasingDirection: EasingDirection?,
	UpdateSignal: "Heartbeat" | "RenderStepped" | "Stepped"?,
}

type AnimationKind = "Tween" | "Bezier" | "Delay"

type AnimationHandle = {
	Id: number,
	Kind: AnimationKind,

	Playing: boolean,
	Paused: boolean,
	Completed: boolean,

	Elapsed: number,
	Duration: number,
	DelayRemaining: number,

	Object: Instance?,
	Property: string?,

	From: Tweenable?,
	To: Tweenable?,

	Points: { Vector3 }?,
	BezierDegree: number?,

	EasingStyle: EasingStyle,
	EasingDirection: EasingDirection,

	AutoDestroy: boolean,
	OnUpdate: ((alpha: number, easedAlpha: number, value: Tweenable) -> ())?,
	OnComplete: (() -> ())?,

	Callback: (() -> ())?,
}

type MotionServiceType = {
	Config: MotionConfig,
	Queue: { [number]: AnimationHandle },
	NextId: number,
	Running: boolean,

	_connection: RBXScriptConnection?,
	_propertyMap: { [Instance]: { [string]: number } },
	_deadIds: { number },

	Init: (self: MotionServiceType, config: MotionConfig?) -> (),
	Destroy: (self: MotionServiceType) -> (),
	Step: (self: MotionServiceType, dt: number) -> (),
	PlayAll: (self: MotionServiceType) -> (),

	Ease: (self: MotionServiceType, t: number, style: EasingStyle, direction: EasingDirection) -> number,
	Lerp: (self: MotionServiceType, a: Tweenable, b: Tweenable, t: number) -> Tweenable,
	Bezier: (self: MotionServiceType, t: number, p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3) -> Vector3,
	QuadraticBezier: (self: MotionServiceType, t: number, p0: Vector3, p1: Vector3, p2: Vector3) -> Vector3,

	Animate: (
		self: MotionServiceType,
		object: Instance,
		property: string,
		target: Tweenable,
		duration: number?,
		options: TweenOptions?
	) -> AnimationHandle?,

	Move: (
		self: MotionServiceType,
		object: Instance,
		property: string,
		target: Tweenable,
		duration: number?,
		options: TweenOptions?
	) -> AnimationHandle?,

	AnimateTo: (
		self: MotionServiceType,
		object: Instance,
		goals: { [string]: Tweenable },
		duration: number?,
		options: TweenOptions?
	) -> { [string]: AnimationHandle? },

	BezierMove: (
		self: MotionServiceType,
		object: Instance,
		property: string,
		points: { Vector3 },
		duration: number?,
		options: TweenOptions?
	) -> AnimationHandle?,

	Delay: (self: MotionServiceType, seconds: number, callback: () -> ()) -> AnimationHandle,

	Cancel: (self: MotionServiceType, handleOrId: AnimationHandle | number) -> (),
	Pause: (self: MotionServiceType, handleOrId: AnimationHandle | number) -> (),
	Resume: (self: MotionServiceType, handleOrId: AnimationHandle | number) -> (),
	IsPlaying: (self: MotionServiceType, handleOrId: AnimationHandle | number) -> boolean,
	GetHandle: (self: MotionServiceType, id: number) -> AnimationHandle?,
	GetActiveCount: (self: MotionServiceType) -> number,
	CancelAll: (self: MotionServiceType) -> (),
}

local MotionService = {} :: any
MotionService.__index = MotionService

local function clamp01(t: number): number
	if t < 0 then
		return 0
	elseif t > 1 then
		return 1
	end
	return t
end

local function mergeConfig(base: MotionConfig?, override: MotionConfig?): MotionConfig
	return {
		DefaultDuration = (override and override.DefaultDuration) or (base and base.DefaultDuration) or 0.35,
		DefaultEasingStyle = (override and override.DefaultEasingStyle) or (base and base.DefaultEasingStyle) or "Quad",
		DefaultEasingDirection = (override and override.DefaultEasingDirection) or (base and base.DefaultEasingDirection) or "Out",
		UpdateSignal = (override and override.UpdateSignal) or (base and base.UpdateSignal) or "Heartbeat",
	}
end

local function safePCall<T>(fn: () -> T): (boolean, T?)
	return pcall(fn)
end

local function safeWarn(prefix: string, err: any)
	warn(prefix .. tostring(err))
end

local function readProperty(object: Instance, property: string): any
	local ok, value = safePCall(function()
		return (object :: any)[property]
	end)

	if ok then
		return value
	end

	return nil
end

local function writeProperty(object: Instance, property: string, value: any): boolean
	local ok = pcall(function()
		(object :: any)[property] = value
	end)

	return ok
end

local function copyPoints(points: { Vector3 }): { Vector3 }
	local result = table.create(#points)
	for i, point in ipairs(points) do
		result[i] = point
	end
	return result
end

local function resolveSignalName(configured: "Heartbeat" | "RenderStepped" | "Stepped"): "Heartbeat" | "RenderStepped" | "Stepped"
	if configured == "RenderStepped" and not RunService:IsClient() then
		return "Heartbeat"
	end
	return configured
end

local function getSignal(signalName: "Heartbeat" | "RenderStepped" | "Stepped")
	if signalName == "Heartbeat" then
		return RunService.Heartbeat
	elseif signalName == "RenderStepped" then
		return RunService.RenderStepped
	else
		return RunService.Stepped
	end
end

local function getObjectMap(self: any, object: Instance): { [string]: number }
	local map = self._propertyMap[object]
	if map == nil then
		map = {}
		self._propertyMap[object] = map
	end
	return map
end

function MotionService._ensureState(self: any)
	if self.Config == nil then
		self.Config = mergeConfig(nil, nil)
	end
	if self.Queue == nil then
		self.Queue = {}
	end
	if self.NextId == nil then
		self.NextId = 0
	end
	if self.Running == nil then
		self.Running = false
	end
	if self._connection == nil then
		self._connection = nil
	end
	if self._propertyMap == nil then
		self._propertyMap = setmetatable({}, { __mode = "k" })
	end
	if self._deadIds == nil then
		self._deadIds = {}
	end
end

function MotionService.new(config: MotionConfig?)
	MotionService:Init(config)
	return MotionService
end

function MotionService:_nextHandleId(): number
	self.NextId += 1
	return self.NextId
end

function MotionService:_register(handle: AnimationHandle): AnimationHandle
	handle.Id = self:_nextHandleId()
	self.Queue[handle.Id] = handle
	return handle
end

function MotionService:_untrackHandle(handle: AnimationHandle)
	if handle.Object ~= nil and handle.Property ~= nil then
		local objectMap = self._propertyMap[handle.Object]
		if objectMap ~= nil and objectMap[handle.Property] == handle.Id then
			objectMap[handle.Property] = nil
		end
	end
end

function MotionService:_cancelConflict(object: Instance, property: string)
	local objectMap = self._propertyMap[object]
	if objectMap == nil then
		return
	end

	local existingId = objectMap[property]
	if existingId == nil then
		return
	end

	local existing = self.Queue[existingId]
	if existing ~= nil then
		existing.Playing = false
		existing.Completed = true
		self:_untrackHandle(existing)
		self.Queue[existingId] = nil
	end

	objectMap[property] = nil
end

function MotionService:_trackProperty(object: Instance, property: string, id: number)
	local objectMap = getObjectMap(self, object)
	objectMap[property] = id
end

function MotionService:_finishHandle(id: number, handle: AnimationHandle)
	handle.Playing = false
	handle.Completed = true
	self:_untrackHandle(handle)
	if handle.AutoDestroy then
		self.Queue[id] = nil
	end
end

function MotionService:Init(config: MotionConfig?)
	MotionService._ensureState(self)

	self.Config = mergeConfig(self.Config, config)

	if self._connection ~= nil then
		self._connection:Disconnect()
		self._connection = nil
	end

	self.Running = true

	local signalName = resolveSignalName(self.Config.UpdateSignal or "Heartbeat")
	local signal = getSignal(signalName)

	if signalName == "Stepped" then
		self._connection = signal:Connect(function(_: number, dt: number)
			self:Step(dt)
		end)
	else
		self._connection = signal:Connect(function(dt: number)
			self:Step(dt)
		end)
	end
end

function MotionService:Destroy()
	MotionService._ensureState(self)

	self.Running = false

	if self._connection ~= nil then
		self._connection:Disconnect()
		self._connection = nil
	end

	table.clear(self.Queue)
	table.clear(self._deadIds)
	table.clear(self._propertyMap)
end

function MotionService:PlayAll()
	MotionService._ensureState(self)

	if self.Running then
		return
	end

	self:Init(self.Config)
end

function MotionService:Ease(t: number, style: EasingStyle, direction: EasingDirection): number
	t = clamp01(t)

	if style == "Linear" then
		return t
	end

	if style == "Quad" then
		if direction == "In" then
			return t * t
		elseif direction == "Out" then
			return 1 - (1 - t) * (1 - t)
		end

		if t < 0.5 then
			return 2 * t * t
		end
		return 1 - ((-2 * t + 2) ^ 2) / 2
	end

	if style == "Cubic" then
		if direction == "In" then
			return t * t * t
		elseif direction == "Out" then
			local u = 1 - t
			return 1 - u * u * u
		end

		if t < 0.5 then
			return 4 * t * t * t
		end
		local u = -2 * t + 2
		return 1 - (u * u * u) / 2
	end

	if style == "Quart" then
		if direction == "In" then
			return t ^ 4
		elseif direction == "Out" then
			return 1 - (1 - t) ^ 4
		end

		if t < 0.5 then
			return 8 * t ^ 4
		end
		return 1 - ((-2 * t + 2) ^ 4) / 2
	end

	if style == "Quint" then
		if direction == "In" then
			return t ^ 5
		elseif direction == "Out" then
			return 1 - (1 - t) ^ 5
		end

		if t < 0.5 then
			return 16 * t ^ 5
		end
		return 1 - ((-2 * t + 2) ^ 5) / 2
	end

	if style == "Sine" then
		if direction == "In" then
			return 1 - math.cos((t * math.pi) / 2)
		elseif direction == "Out" then
			return math.sin((t * math.pi) / 2)
		end

		return -(math.cos(math.pi * t) - 1) / 2
	end

	if style == "Expo" then
		if direction == "In" then
			if t == 0 then
				return 0
			end
			return 2 ^ (10 * t - 10)
		elseif direction == "Out" then
			if t == 1 then
				return 1
			end
			return 1 - 2 ^ (-10 * t)
		end

		if t == 0 then
			return 0
		elseif t == 1 then
			return 1
		end

		if t < 0.5 then
			return (2 ^ (20 * t - 10)) / 2
		end
		return (2 - 2 ^ (-20 * t + 10)) / 2
	end

	if style == "Back" then
		local c1 = 1.70158
		local c2 = c1 * 1.525

		if direction == "In" then
			return (c1 + 1) * t * t * t - c1 * t * t
		elseif direction == "Out" then
			local u = t - 1
			return 1 + (c1 + 1) * u * u * u + c1 * u * u
		end

		if t < 0.5 then
			return ((2 * t) ^ 2 * ((c2 + 1) * 2 * t - c2)) / 2
		end

		local u = 2 * t - 2
		return ((u * u * ((c2 + 1) * u + c2)) + 2) / 2
	end

	if style == "Bounce" then
		local n1 = 7.5625
		local d1 = 2.75

		local function bounceOut(x: number): number
			if x < 1 / d1 then
				return n1 * x * x
			elseif x < 2 / d1 then
				x -= 1.5 / d1
				return n1 * x * x + 0.75
			elseif x < 2.5 / d1 then
				x -= 2.25 / d1
				return n1 * x * x + 0.9375
			else
				x -= 2.625 / d1
				return n1 * x * x + 0.984375
			end
		end

		if direction == "In" then
			return 1 - bounceOut(1 - t)
		elseif direction == "Out" then
			return bounceOut(t)
		end

		if t < 0.5 then
			return (1 - bounceOut(1 - 2 * t)) / 2
		end
		return (1 + bounceOut(2 * t - 1)) / 2
	end

	if style == "Elastic" then
		local c4 = (2 * math.pi) / 3
		local c5 = (2 * math.pi) / 4.5

		if direction == "In" then
			if t == 0 then
				return 0
			elseif t == 1 then
				return 1
			end
			return -(2 ^ (10 * t - 10)) * math.sin((t * 10 - 10.75) * c4)
		elseif direction == "Out" then
			if t == 0 then
				return 0
			elseif t == 1 then
				return 1
			end
			return (2 ^ (-10 * t)) * math.sin((t * 10 - 0.75) * c4) + 1
		end

		if t == 0 then
			return 0
		elseif t == 1 then
			return 1
		end

		if t < 0.5 then
			return -((2 ^ (20 * t - 10)) * math.sin((20 * t - 11.125) * c5)) / 2
		end

		return ((2 ^ (-20 * t + 10)) * math.sin((20 * t - 11.125) * c5)) / 2 + 1
	end

	return t
end

function MotionService:Lerp(a: Tweenable, b: Tweenable, t: number): Tweenable
	if typeof(a) ~= typeof(b) then
		return b
	end

	if typeof(a) == "number" then
		return (a :: number) + ((b :: number) - (a :: number)) * t
	elseif typeof(a) == "Vector2" then
		return (a :: Vector2):Lerp(b :: Vector2, t)
	elseif typeof(a) == "Vector3" then
		return (a :: Vector3):Lerp(b :: Vector3, t)
	elseif typeof(a) == "UDim2" then
		return (a :: UDim2):Lerp(b :: UDim2, t)
	elseif typeof(a) == "Color3" then
		return (a :: Color3):Lerp(b :: Color3, t)
	elseif typeof(a) == "CFrame" then
		return (a :: CFrame):Lerp(b :: CFrame, t)
	end

	return b
end

function MotionService:Bezier(t: number, p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3): Vector3
	local u = 1 - t
	return (u * u * u * p0) + (3 * u * u * t * p1) + (3 * u * t * t * p2) + (t * t * t * p3)
end

function MotionService:QuadraticBezier(t: number, p0: Vector3, p1: Vector3, p2: Vector3): Vector3
	local u = 1 - t
	return (u * u * p0) + (2 * u * t * p1) + (t * t * p2)
end

function MotionService:Animate(
	object: Instance,
	property: string,
	target: Tweenable,
	duration: number?,
	options: TweenOptions?
): AnimationHandle?
	MotionService._ensureState(self)

	local current = readProperty(object, property)
	if current == nil then
		return nil
	end

	if typeof(current) ~= typeof(target) then
		return nil
	end

	self:_cancelConflict(object, property)

	local handle: AnimationHandle = {
		Id = 0,
		Kind = "Tween",

		Playing = true,
		Paused = false,
		Completed = false,

		Elapsed = 0,
		Duration = math.max(duration or self.Config.DefaultDuration or 0.35, 0.0001),
		DelayRemaining = (options and options.Delay) or 0,

		Object = object,
		Property = property,

		From = current,
		To = target,

		Points = nil,
		BezierDegree = nil,

		EasingStyle = (options and options.EasingStyle) or self.Config.DefaultEasingStyle or "Quad",
		EasingDirection = (options and options.EasingDirection) or self.Config.DefaultEasingDirection or "Out",

		AutoDestroy = if options and options.AutoDestroy ~= nil then options.AutoDestroy else true,
		OnUpdate = options and options.OnUpdate or nil,
		OnComplete = options and options.OnComplete or nil,

		Callback = nil,
	}

	self:_register(handle)
	self:_trackProperty(object, property, handle.Id)

	if not self.Running then
		self:PlayAll()
	end

	return handle
end

function MotionService:Move(
	object: Instance,
	property: string,
	target: Tweenable,
	duration: number?,
	options: TweenOptions?
): AnimationHandle?
	return self:Animate(object, property, target, duration, options)
end

function MotionService:AnimateTo(
	object: Instance,
	goals: { [string]: Tweenable },
	duration: number?,
	options: TweenOptions?
): { [string]: AnimationHandle? }
	MotionService._ensureState(self)

	local handles: { [string]: AnimationHandle? } = {}
	for property, target in pairs(goals) do
		handles[property] = self:Animate(object, property, target, duration, options)
	end

	return handles
end

function MotionService:BezierMove(
	object: Instance,
	property: string,
	points: { Vector3 },
	duration: number?,
	options: TweenOptions?
): AnimationHandle?
	MotionService._ensureState(self)

	if #points ~= 3 and #points ~= 4 then
		error("BezierMove requires exactly 3 points for quadratic or 4 points for cubic.")
	end

	local current = readProperty(object, property)
	if current == nil then
		return nil
	end

	if typeof(current) ~= "Vector3" then
		return nil
	end

	self:_cancelConflict(object, property)

	-- Snap to curve start immediately so the curve begins cleanly.
	writeProperty(object, property, points[1])

	local handle: AnimationHandle = {
		Id = 0,
		Kind = "Bezier",

		Playing = true,
		Paused = false,
		Completed = false,

		Elapsed = 0,
		Duration = math.max(duration or self.Config.DefaultDuration or 0.35, 0.0001),
		DelayRemaining = (options and options.Delay) or 0,

		Object = object,
		Property = property,

		From = points[1],
		To = nil,

		Points = copyPoints(points),
		BezierDegree = #points,

		EasingStyle = (options and options.EasingStyle) or self.Config.DefaultEasingStyle or "Quad",
		EasingDirection = (options and options.EasingDirection) or self.Config.DefaultEasingDirection or "Out",

		AutoDestroy = if options and options.AutoDestroy ~= nil then options.AutoDestroy else true,
		OnUpdate = options and options.OnUpdate or nil,
		OnComplete = options and options.OnComplete or nil,

		Callback = nil,
	}

	self:_register(handle)
	self:_trackProperty(object, property, handle.Id)

	if not self.Running then
		self:PlayAll()
	end

	return handle
end

function MotionService:Delay(seconds: number, callback: () -> ()): AnimationHandle
	MotionService._ensureState(self)

	local handle: AnimationHandle = {
		Id = 0,
		Kind = "Delay",

		Playing = true,
		Paused = false,
		Completed = false,

		Elapsed = 0,
		Duration = math.max(seconds, 0),
		DelayRemaining = 0,

		Object = nil,
		Property = nil,

		From = nil,
		To = nil,

		Points = nil,
		BezierDegree = nil,

		EasingStyle = "Linear",
		EasingDirection = "Out",

		AutoDestroy = true,
		OnUpdate = nil,
		OnComplete = nil,

		Callback = callback,
	}

	self:_register(handle)

	if not self.Running then
		self:PlayAll()
	end

	return handle
end

function MotionService:Cancel(handleOrId: AnimationHandle | number)
	MotionService._ensureState(self)

	local id = if typeof(handleOrId) == "number" then handleOrId else (handleOrId :: AnimationHandle).Id
	local handle = self.Queue[id]

	if handle ~= nil then
		self:_untrackHandle(handle)
		handle.Playing = false
		handle.Completed = true
		self.Queue[id] = nil
	end
end

function MotionService:Pause(handleOrId: AnimationHandle | number)
	MotionService._ensureState(self)

	local id = if typeof(handleOrId) == "number" then handleOrId else (handleOrId :: AnimationHandle).Id
	local handle = self.Queue[id]

	if handle ~= nil then
		handle.Paused = true
	end
end

function MotionService:Resume(handleOrId: AnimationHandle | number)
	MotionService._ensureState(self)

	local id = if typeof(handleOrId) == "number" then handleOrId else (handleOrId :: AnimationHandle).Id
	local handle = self.Queue[id]

	if handle ~= nil then
		handle.Paused = false
	end
end

function MotionService:IsPlaying(handleOrId: AnimationHandle | number): boolean
	MotionService._ensureState(self)

	local id = if typeof(handleOrId) == "number" then handleOrId else (handleOrId :: AnimationHandle).Id
	local handle = self.Queue[id]

	return handle ~= nil and handle.Playing and not handle.Paused and not handle.Completed
end

function MotionService:GetHandle(id: number): AnimationHandle?
	MotionService._ensureState(self)
	return self.Queue[id]
end

function MotionService:GetActiveCount(): number
	MotionService._ensureState(self)

	local count = 0
	for _, handle in pairs(self.Queue) do
		if handle.Playing and not handle.Paused and not handle.Completed then
			count += 1
		end
	end
	return count
end

function MotionService:CancelAll()
	MotionService._ensureState(self)

	local ids = table.create(16)
	for id in pairs(self.Queue) do
		table.insert(ids, id)
	end

	for _, id in ipairs(ids) do
		local handle = self.Queue[id]
		if handle ~= nil then
			self:_untrackHandle(handle)
			handle.Playing = false
			handle.Completed = true
			self.Queue[id] = nil
		end
	end
end

function MotionService:Step(dt: number)
	MotionService._ensureState(self)

	if not self.Running then
		return
	end

	local deadIds = self._deadIds
	table.clear(deadIds)

	for id, handle in pairs(self.Queue) do
		if not handle.Playing or handle.Paused then
			continue
		end

		if handle.DelayRemaining > 0 then
			handle.DelayRemaining = math.max(0, handle.DelayRemaining - dt)
			continue
		end

		if handle.Kind == "Delay" then
			handle.Elapsed += dt

			if handle.Elapsed >= handle.Duration then
				handle.Playing = false
				handle.Completed = true

				if handle.Callback ~= nil then
					task.spawn(function()
						local ok, err = pcall(handle.Callback :: any)
						if not ok then
							safeWarn("[MotionService Delay callback error] ", err)
						end
					end)
				end

				table.insert(deadIds, id)
			end

			continue
		end

		handle.Elapsed += dt
		local alpha = clamp01(handle.Elapsed / handle.Duration)
		local easedAlpha = self:Ease(alpha, handle.EasingStyle, handle.EasingDirection)

		if handle.Kind == "Tween" then
			if handle.Object ~= nil and handle.Property ~= nil and handle.From ~= nil and handle.To ~= nil then
				local value = self:Lerp(handle.From, handle.To, easedAlpha)
				local wrote = writeProperty(handle.Object, handle.Property, value)

				if wrote then
					if handle.OnUpdate ~= nil then
						task.spawn(function()
							local ok, err = pcall(function()
								handle.OnUpdate(alpha, easedAlpha, value)
							end)
							if not ok then
								safeWarn("[MotionService OnUpdate error] ", err)
							end
						end)
					end
				else
					self:_finishHandle(id, handle)
					table.insert(deadIds, id)
					continue
				end
			end
		elseif handle.Kind == "Bezier" then
			if handle.Object ~= nil and handle.Property ~= nil and handle.Points ~= nil and handle.BezierDegree ~= nil then
				local pts = handle.Points
				local value: Vector3?

				if handle.BezierDegree == 3 and #pts == 4 then
					value = self:Bezier(easedAlpha, pts[1], pts[2], pts[3], pts[4])
				elseif handle.BezierDegree == 4 and #pts == 4 then
					-- Fallback: treat 4 points as cubic.
					value = self:Bezier(easedAlpha, pts[1], pts[2], pts[3], pts[4])
				elseif handle.BezierDegree == 3 and #pts == 3 then
					value = self:QuadraticBezier(easedAlpha, pts[1], pts[2], pts[3])
				elseif handle.BezierDegree == 4 and #pts == 3 then
					value = self:QuadraticBezier(easedAlpha, pts[1], pts[2], pts[3])
				else
					-- Input state is invalid; stop cleanly instead of crashing.
					self:_finishHandle(id, handle)
					table.insert(deadIds, id)
					continue
				end

				if value ~= nil then
					local wrote = writeProperty(handle.Object, handle.Property, value)
					if wrote then
						if handle.OnUpdate ~= nil then
							task.spawn(function()
								local ok, err = pcall(function()
									handle.OnUpdate(alpha, easedAlpha, value :: Tweenable)
								end)
								if not ok then
									safeWarn("[MotionService OnUpdate error] ", err)
								end
							end)
						end
					else
						self:_finishHandle(id, handle)
						table.insert(deadIds, id)
						continue
					end
				end
			end
		end

		if alpha >= 1 then
			self:_finishHandle(id, handle)

			if handle.OnComplete ~= nil then
				task.spawn(function()
					local ok, err = pcall(handle.OnComplete :: any)
					if not ok then
						safeWarn("[MotionService OnComplete error] ", err)
					end
				end)
			end

			if handle.AutoDestroy then
				table.insert(deadIds, id)
			end
		end
	end

	for i = 1, #deadIds do
		self.Queue[deadIds[i]] = nil
	end
end

return MotionService
