--!strict
-- Minimal signal. Handlers run in their own threads, so an error or a yield
-- in one handler never affects the module or other handlers.

local Types = require(script.Parent.Types)

type Connection = Types.Connection
type Signal<T...> = Types.Signal<T...>

type Handler = {
	Connected: boolean,
	Callback: (...any) -> (),
	Disconnect: (self: Handler) -> (),
}

local Signal = {}

function Signal.new<T...>(): Signal<T...>
	local handlers: { Handler } = {}

	local function disconnect(handler: Handler)
		if not handler.Connected then
			return
		end
		handler.Connected = false
		local index = table.find(handlers, handler)
		if index then
			table.remove(handlers, index)
		end
	end

	local function connect(callback: (...any) -> ()): Handler
		local handler: Handler = {
			Connected = true,
			Callback = callback,
			Disconnect = disconnect,
		}
		table.insert(handlers, handler)
		return handler
	end

	local signal = {}

	function signal.Connect(_self: any, callback: (...any) -> ()): Connection
		return connect(callback) :: any
	end

	function signal.Once(_self: any, callback: (...any) -> ()): Connection
		local handler: Handler
		handler = connect(function(...)
			disconnect(handler)
			callback(...)
		end)
		return handler :: any
	end

	function signal.Wait(_self: any): ...any
		local thread = coroutine.running()
		local handler: Handler
		handler = connect(function(...)
			disconnect(handler)
			task.spawn(thread, ...)
		end)
		return coroutine.yield()
	end

	function signal.Fire(_self: any, ...: any)
		-- Snapshot, so handlers connected or disconnected during Fire behave predictably.
		for _, handler in table.clone(handlers) do
			if handler.Connected then
				task.spawn(handler.Callback, ...)
			end
		end
	end

	function signal.DisconnectAll(_self: any)
		for _, handler in handlers do
			handler.Connected = false
		end
		table.clear(handlers)
	end

	return signal :: any
end

return Signal
