class_name _AlexandriaNetClient extends AlexandriaNet

var connection := AlexandriaNet_PacketPeerTCP.new()
var config := AlexandriaNetClientConfig.new()

func is_client() -> bool:
  return true

func _ready() -> void:
  Alexandria.config.save_properties.connect(config.save_properties)
  Alexandria.config.load_properties.connect(config.load_properties)
  await Alexandria.config.loaded
  if not config.enabled:
    return
  match connection.connect_to_host(config.address, config.port):
    OK:
      print("AlexandriaNetClient connected @ ", config.address, ":", config.port)
    var error:
      push_error("AlexandriaNetClient failed to connect @ ", config.address, ":", config.port, "; Error: ", error_string(error))
      return
  read_database_entry_response.connect(_store_remote_entry_response.bind(read_responses))
  created_database_entry_response.connect(_store_remote_entry_response.bind(create_responses))
  updated_database_entry_response.connect(_store_remote_entry_response.bind(update_responses))
  deleted_database_entry_response.connect(_store_remote_entry_response.bind(delete_responses))
  database_schema_entries_response.connect(_store_remote_schema_response.bind(schema_entries_responses))
  transaction_response.connect(_store_remote_transaction_response.bind(transaction_responses))

func _process(_delta: float) -> void:
  connection.poll()
  if not connection.is_socket_connected():
    return
  while connection.get_available_packet_count() > 0:
    var data := AlexandriaNet_PacketDataBuffer.new(connection.get_packet())
    var packet := deserialize_packet(data)
    packet.handle(connection, self)

# Schema Name -> Entry Name -> Entry Data
var read_responses := {}
# Schema Name -> Entry Name -> Error Code
var create_responses := {}
var update_responses := {}
var delete_responses := {}
func _store_remote_entry_response(schema_name: String, entry_name: String, response, response_dictionary: Dictionary) -> void:
  if not response_dictionary.has(schema_name):
    response_dictionary[schema_name] = {}
  response_dictionary[schema_name][entry_name] = response

# Schema Name -> Entry Names
var schema_entries_responses := {}
func _store_remote_schema_response(schema_name: String, response, response_dictionary: Dictionary) -> void:
  response_dictionary[schema_name] = response

# Transaction Name -> [Error Code, Error Reason]
var transaction_responses := {}
func _store_remote_transaction_response(transaction_name: String, response_code: Error, response_reason: String, response_dictionary: Dictionary) -> void:
  response_dictionary[transaction_name] = [response_code, response_reason]

func _perform_remote_request(request_packet: Packet, response_dictionary: Dictionary, timeout: float) -> Variant:
  match connection.put_packet(serialize_packet(request_packet).raw_bytes()):
    OK:
      pass
    var error:
      push_error("AlexandriaNetClient failed to send read request packet: ", error_string(error))
      return null
  if request_packet is DatabaseEntryPacket:
    if response_dictionary.get(request_packet.schema_name, {}).has(request_packet.entry_name):
      response_dictionary[request_packet.schema_name].erase(request_packet.entry_name)
    var max_time := Time.get_ticks_msec() + timeout * 1000.0
    while not response_dictionary.get(request_packet.schema_name, {}).has(request_packet.entry_name):
      if Time.get_ticks_msec() > max_time:
        push_error("AlexandriaNetClient remote request [", request_packet.get_name(), "] for ", request_packet.schema_name, "/", request_packet.entry_name, " timed out")
        return null
      await get_tree().create_timer(0.1).timeout
    return response_dictionary[request_packet.schema_name][request_packet.entry_name]
  elif request_packet is DatabaseSchemaPacket:
    if response_dictionary.has(request_packet.schema_name):
      response_dictionary[request_packet.schema_name].erase(request_packet.entry_name)
    var max_time := Time.get_ticks_msec() + timeout * 1000.0
    while not response_dictionary.has(request_packet.schema_name):
      if Time.get_ticks_msec() > max_time:
        push_error("AlexandriaNetClient remote request [", request_packet.get_name(), "] for ", request_packet.schema_name, "/", request_packet.entry_name, " timed out")
        return null
      await get_tree().create_timer(0.1).timeout
    return response_dictionary[request_packet.schema_name]
  elif request_packet is DatabaseTransactionPacket:
    if response_dictionary.has(request_packet.transaction_name):
      response_dictionary.erase(request_packet.transaction_name)
    var max_time := Time.get_ticks_msec() + timeout * 1000.0
    while not response_dictionary.has(request_packet.transaction_name):
      if Time.get_ticks_msec() > max_time:
        push_error("AlexandriaNetClient remote request [", request_packet.get_name(), "] for \"", request_packet.transaction_name, "\" timed out")
        return null
      await get_tree().create_timer(0.1).timeout
    return response_dictionary[request_packet.transaction_name]
  return null

func create_remote_entry(schema_name: String, entry_name: String, timeout := 10.0) -> Error:
  return await _perform_remote_request(DatabaseCreateRequestPacket.new(schema_name, entry_name), create_responses, timeout)

func get_remote_entry(schema_name: String, entry_name: String, timeout := 10.0) -> Resource:
  return await _perform_remote_request(DatabaseReadRequestPacket.new(schema_name, entry_name), read_responses, timeout)

func update_remote_entry(schema_name: String, entry_name: String, entry_data: Resource, timeout := 10.0) -> Error:
  var request_packet := DatabaseUpdateRequestPacket.new(schema_name, entry_name)
  var schema_data := Alexandria.get_schema_data(schema_name)
  if not schema_data:
    return ERR_QUERY_FAILED
  request_packet.entry_data = schema_data.serialize_entry(entry_name, entry_data)
  return await _perform_remote_request(request_packet, update_responses, timeout)

func delete_remote_entry(schema_name: String, entry_name: String, timeout := 10.0) -> Error:
  return await _perform_remote_request(DatabaseDeleteRequestPacket.new(schema_name, entry_name), delete_responses, timeout)

func get_remote_entries(schema_name: String, timeout := 10.0) -> PackedStringArray:
  return await _perform_remote_request(DatabaseSchemaEntriesRequestPacket.new(schema_name), schema_entries_responses, timeout)

## Returned Array contains two items: [error_code: Error, error_reason: String]
## error_reason may be left empty (aka: ""), but may contain useful debugging information
func apply_remote_transaction(transaction_name: String, transaction: Alexandria_Transaction = null, timeout := 10.0) -> Array:
  var transaction_data := Alexandria.get_transaction_data(transaction_name)
  if transaction_data == null:
    push_error("No registered transaction with the name \"", transaction_name, "\"")
    return [ERR_CANT_ACQUIRE_RESOURCE, "Failed "]
  if transaction == null:
    transaction = transaction_data.resource_script.new()
  var packet := DatabaseTransactionRequestPacket.new(transaction, transaction_name)
  var response = await _perform_remote_request(packet, transaction_responses, timeout)
  return response if response != null else [ERR_CANT_RESOLVE, "Underlying _perform_remote_request function failed; likely a timeout"]
