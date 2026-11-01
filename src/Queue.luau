--!strict
-- Batch queue: caps its size (oldest dropped), sends at most 100 events per POST /v1/batch and
-- retries 408, 429, 5xx and network failures with capped exponential backoff.

local Queue = {}
Queue.__index = Queue

Queue.MAX_BATCH = 100

export type Send = (body: string) -> number -- returns the HTTP status (0 = network failure)

export type Queue = typeof(setmetatable(
	{} :: {
		items: { any },
		maxSize: number,
		maxRetries: number,
		attempt: number,
		retryAt: number,
		dropped: number,
	},
	Queue
))

function Queue.new(maxSize: number?, maxRetries: number?): Queue
	return setmetatable({
		items = {},
		maxSize = maxSize or 1000,
		maxRetries = maxRetries or 5,
		attempt = 0,
		retryAt = 0,
		dropped = 0,
	}, Queue)
end

function Queue.push(self: Queue, e: any)
	table.insert(self.items, e)
	while #self.items > self.maxSize do
		table.remove(self.items, 1)
		self.dropped += 1
	end
end

function Queue.size(self: Queue): number
	return #self.items
end

function Queue.retryable(status: number): boolean
	return status == 0 or status == 408 or status == 429 or status >= 500
end

local function removeFirst(items: { any }, n: number)
	for _ = 1, math.min(n, #items) do
		table.remove(items, 1)
	end
end

-- Sends one batch when not waiting on a backoff. encode builds the body from the batch array.
-- Returns true when a batch was acknowledged or dropped (the caller may send the next one).
function Queue.sendOne(
	self: Queue,
	now: number,
	encode: ({ any }) -> string,
	send: Send,
	random: () -> number
): boolean
	if #self.items == 0 or now < self.retryAt then
		return false
	end
	local batch = table.move(self.items, 1, math.min(#self.items, Queue.MAX_BATCH), 1, {})
	local status = send(encode(batch))
	if status >= 200 and status <= 299 then
		removeFirst(self.items, #batch)
		self.attempt, self.retryAt = 0, 0
		return true
	end
	if not Queue.retryable(status) or self.attempt >= self.maxRetries then
		removeFirst(self.items, #batch)
		self.dropped += #batch
		self.attempt, self.retryAt = 0, 0
		return true
	end
	self.attempt += 1
	local cap = math.min(1000 * 2 ^ self.attempt, 30000)
	self.retryAt = now + math.floor(cap * (0.5 + 0.5 * random()))
	return false
end

return Queue
