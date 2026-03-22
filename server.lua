-- Parcelo server
-- Put this on the hidden/main server computer

local MODEM_SIDE = "back"
local HOST_PROTOCOL = "parcelo_host"
local HOSTNAME = "parcelo_server"
local API_PROTOCOL = "parcelo_api"
local DATA_FILE = "parcelo_db.txt"

local HOLD_MS = 60 * 60 * 1000 -- 1 hour = 3 in-game days

math.randomseed(os.epoch("utc"))

local db = {
  nextOrderId = 1001,
  nextTrackingId = 5001,
  orders = {}
}

local function nowMs()
  return os.epoch("utc")
end

local function trim(s)
  if s == nil then return "" end
  return tostring(s):match("^%s*(.-)%s*$")
end

local function normalizeName(s)
  return trim(s):lower()
end

local function deepCopy(tbl)
  return textutils.unserialise(textutils.serialise(tbl))
end

local function saveDb()
  local f = fs.open(DATA_FILE, "w")
  f.write(textutils.serialise(db))
  f.close()
end

local function loadDb()
  if fs.exists(DATA_FILE) then
    local f = fs.open(DATA_FILE, "r")
    local raw = f.readAll()
    f.close()
    local loaded = textutils.unserialise(raw)
    if type(loaded) == "table" then
      db = loaded
    end
  else
    saveDb()
  end
end

local function makeOrderId()
  local id = string.format("ORD-%04d", db.nextOrderId)
  db.nextOrderId = db.nextOrderId + 1
  return id
end

local function makeTrackingId()
  local id = string.format("PCL-%04d", db.nextTrackingId)
  db.nextTrackingId = db.nextTrackingId + 1
  return id
end

local function addHistory(order, status, by, note)
  order.history = order.history or {}
  table.insert(order.history, 1, {
    time = nowMs(),
    status = status,
    by = by or "system",
    note = note or ""
  })
end

local function getOrderById(orderId)
  return db.orders[orderId]
end

local function getOrderByTracking(trackingId)
  trackingId = trim(trackingId)
  for _, order in pairs(db.orders) do
    if order.trackingId == trackingId then
      return order
    end
  end
  return nil
end

local function getOrdersForPlayer(playerName)
  local out = {}
  local wanted = normalizeName(playerName)
  for _, order in pairs(db.orders) do
    if normalizeName(order.player) == wanted then
      table.insert(out, deepCopy(order))
    end
  end
  table.sort(out, function(a, b)
    return (a.createdAt or 0) > (b.createdAt or 0)
  end)
  return out
end

local function getAllOrders()
  local out = {}
  for _, order in pairs(db.orders) do
    table.insert(out, deepCopy(order))
  end
  table.sort(out, function(a, b)
    return (a.createdAt or 0) > (b.createdAt or 0)
  end)
  return out
end

local function setStatus(order, status, by, note, locker)
  order.status = status or order.status
  order.updatedAt = nowMs()
  order.updatedBy = by or "system"

  if locker ~= nil then
    locker = trim(locker)
    if locker == "" then
      order.locker = nil
    else
      order.locker = locker
    end
  end

  if status == "Awaiting Pickup" then
    order.pickupExpiresAt = nowMs() + HOLD_MS
  elseif status == "Delivered" or status == "Returned" then
    order.pickupExpiresAt = nil
  end

  addHistory(order, order.status, by, note)
end

local function createOrder(player, itemName, amount, deliveryType, address)
  local orderId = makeOrderId()
  local order = {
    orderId = orderId,
    trackingId = nil,
    player = trim(player),
    itemName = trim(itemName),
    amount = tonumber(amount) or 1,
    deliveryType = trim(deliveryType) ~= "" and trim(deliveryType) or "locker",
    address = trim(address),
    status = "Order Received",
    locker = nil,
    pickupExpiresAt = nil,
    createdAt = nowMs(),
    updatedAt = nowMs(),
    updatedBy = trim(player),
    history = {}
  }

  addHistory(order, "Order Received", order.player, "Order created")
  db.orders[orderId] = order
  saveDb()
  return deepCopy(order)
end

local function sendResponse(targetId, payload)
  rednet.send(targetId, payload, API_PROTOCOL)
end

local function ok(targetId, extra)
  extra = extra or {}
  extra.ok = true
  sendResponse(targetId, extra)
end

local function fail(targetId, message)
  sendResponse(targetId, { ok = false, message = message or "Unknown error" })
end

local function handlePlaceOrder(sender, msg)
  local player = trim(msg.player)
  local itemName = trim(msg.itemName)

  if player == "" then
    fail(sender, "Player name is required")
    return
  end

  if itemName == "" then
    fail(sender, "Item name is required")
    return
  end

  local order = createOrder(
    player,
    itemName,
    msg.amount,
    msg.deliveryType,
    msg.address
  )

  ok(sender, { message = "Order placed", order = order })
end

local function handleGetMyOrders(sender, msg)
  local player = trim(msg.player)
  if player == "" then
    fail(sender, "Player name is required")
    return
  end

  ok(sender, { orders = getOrdersForPlayer(player) })
end

local function handleGetAllOrders(sender)
  ok(sender, { orders = getAllOrders() })
end

local function handleGetOrder(sender, msg)
  local order = getOrderById(trim(msg.orderId))
  if not order then
    fail(sender, "Order not found")
    return
  end

  ok(sender, { order = deepCopy(order) })
end

local function handleGetByTracking(sender, msg)
  local trackingId = trim(msg.trackingId)
  if trackingId == "" then
    fail(sender, "Tracking code is required")
    return
  end

  local order = getOrderByTracking(trackingId)
  if not order then
    fail(sender, "Tracking code not found")
    return
  end

  ok(sender, { order = deepCopy(order) })
end

local function handleAssignTracking(sender, msg)
  local order = getOrderById(trim(msg.orderId))
  if not order then
    fail(sender, "Order not found")
    return
  end

  if not order.trackingId then
    order.trackingId = makeTrackingId()
  end

  setStatus(
    order,
    trim(msg.status) ~= "" and trim(msg.status) or "Packaging",
    trim(msg.staff),
    trim(msg.note),
    msg.locker
  )

  saveDb()
  ok(sender, { message = "Tracking assigned", order = deepCopy(order) })
end

local function handleUpdateStatus(sender, msg)
  local order = getOrderById(trim(msg.orderId))
  if not order then
    fail(sender, "Order not found")
    return
  end

  local status = trim(msg.status)
  if status == "" then
    fail(sender, "Status is required")
    return
  end

  setStatus(order, status, trim(msg.staff), trim(msg.note), msg.locker)
  saveDb()

  ok(sender, { message = "Status updated", order = deepCopy(order) })
end

local function handlePing(sender)
  ok(sender, { message = "Parcelo server online" })
end

local function handleRequest(sender, msg)
  if type(msg) ~= "table" then
    fail(sender, "Invalid request")
    return
  end

  local action = trim(msg.action)

  if action == "ping" then
    handlePing(sender)
  elseif action == "place_order" then
    handlePlaceOrder(sender, msg)
  elseif action == "get_my_orders" then
    handleGetMyOrders(sender, msg)
  elseif action == "get_all_orders" then
    handleGetAllOrders(sender)
  elseif action == "get_order" then
    handleGetOrder(sender, msg)
  elseif action == "get_by_tracking" then
    handleGetByTracking(sender, msg)
  elseif action == "assign_tracking" then
    handleAssignTracking(sender, msg)
  elseif action == "update_status" then
    handleUpdateStatus(sender, msg)
  else
    fail(sender, "Unknown action: " .. action)
  end
end

loadDb()

if not rednet.isOpen(MODEM_SIDE) then
  rednet.open(MODEM_SIDE)
end

pcall(function()
  rednet.unhost(HOST_PROTOCOL)
end)
rednet.host(HOST_PROTOCOL, HOSTNAME)

term.clear()
term.setCursorPos(1, 1)
print("Parcelo server online")
print("Hostname: " .. HOSTNAME)
print("Orders loaded: " .. tostring(#getAllOrders()))
print("")
print("Waiting for requests...")

while true do
  local senderId, msg = rednet.receive(API_PROTOCOL)
  handleRequest(senderId, msg)
end
