use "collections"
use "crdt"

actor Cluster
  let _auth: AmbientAuth // TODO: de-escalate to NetAuth
  let _log: Log
  let _config: Config
  let _my_addr: Address
  let _database: Database
  let _serial: _Serialise
  let _listen: _Listen
  let _heart: Heart
  let _deltas_fn: _SendDeltasFn
  var _tick: U64                        = 0
  let _known_addrs: P2Set[Address]      = _known_addrs.create()
  let _passives: SetIs[_Conn]           = _passives.create()
  let _actives: Map[Address, _Conn]     = _actives.create()
  let _last_activity: MapIs[_Conn, U64] = _last_activity.create()
  
  new create(
    auth': AmbientAuth,
    config': Config,
    database': Database)
  =>
    _auth = auth'
    _config = config'
    _database = database'
    
    _log = _config.log
    _my_addr = _config.addr
    _serial = _Serialise(auth')
    
    let listen_notify = ClusterListenNotify(this, _serial.signature())
    _listen = _Listen(auth', consume listen_notify, "", _my_addr.port)
    
    _heart = Heart(this, (_config.heartbeat_time * 1_000_000_000).u64())
    _deltas_fn = this~broadcast_deltas(_serial)
    
    _known_addrs.set(_my_addr)
    _known_addrs.union(_config.seed_addrs.values())
    
    _heartbeat()
  
  be dispose() =>
    _log.info() and _log.i("cluster listener shutting down")
    _listen.dispose()
    _heart.dispose()
    for conn in _actives.values() do conn.dispose() end
    for conn in _passives.values() do conn.dispose() end
  
  fun ref _sync_actives() =>
    """
    Make sure that active connections are being attempted for all known
    addresses and abort connections for addresses that have been removed.
    """
    for addr in _actives.keys() do
      if _known_addrs.contains(addr) then continue end
      
      _log.info() and _log.i("forgetting old address: " + addr.string())
      
      try _actives.remove(addr)?._2.dispose() end
    end
    
    for addr in _known_addrs.values() do
      if (_my_addr == addr) or _actives.contains(addr) then continue end
      
      _log.info() and _log.i("connecting to address: " + addr.string())
      
      let notify = FramedNotify(ClusterNotify(this, _serial.signature()))
      _actives(addr) = _Conn(_auth, consume notify, addr.host, addr.port)
    end
  
  fun ref _find_active(conn: _Conn tag): Address? =>
    """
    Find the connect address for the given active connection reference.
    Raises an error if the connection reference was not in the map.
    """
    for (addr, conn') in _actives.pairs() do
      if conn is conn' then return addr end
    end
    error
  
  fun ref _remove_passive(conn: _Conn tag) =>
    """
    Stop the given passive connection and remove it from our mappings.
    If the other side of the connection cares, they can connect to us again.
    """
    conn.dispose()
    _passives.unset(conn)
    try _last_activity.remove(conn)? end
  
  fun ref _remove_active(conn: _Conn tag) =>
    """
    Stop the given active connection and remove it from our mappings.
    Let it be created again later the next time _sync_actives is called.
    """
    conn.dispose()
    try _actives.remove(_find_active(conn)?)? end
    try _last_activity.remove(conn)? end
  
  fun ref _remove_either(conn: _Conn tag) =>
    """
    Stop the given connection and remove it from our mappings.
    This method will work for either an active or passive connection.
    """
    if _passives.contains(conn)
    then _remove_passive(conn)
    else _remove_active(conn)
    end
  
  be _heartbeat() =>
    """
    Receive the periodic message from the Heart we're holding,
    and take some general housekeeping/timekeeping actions here.
    """
    _tick = _tick + 1
    
    // Close connections that have been inactive for 10 or more ticks.
    for (conn, last_tick) in _last_activity.pairs() do
      if (last_tick + 10) < _tick then _remove_either(conn) end
    end
    
    // On every third tick, announce our addresses to other nodes.
    if (_tick % 3) == 0 then
      for conn in _actives.values() do
        _send(conn, MsgAnnounceAddrs(_known_addrs))
      end
    end
    
    // On every tick, flush deltas to other nodes.
    _database.flush_deltas(_deltas_fn)
    
    // On every tick, sync active connections.
    _sync_actives()
  
  be _listen_failed() =>
    _log.err() and _log.e("cluster listener failed to listen")
    dispose()
  
  be _listen_ready() => None
    _log.info() and _log.i("cluster listener ready")
  
  be _passive_established(conn: _Conn tag, remote_addr: Address) =>
    _log.info() and _log.i("passive cluster connection established from: " +
      remote_addr.string())
    
    _passives.set(conn)
    _last_activity(conn) = _tick
  
  be _active_established(conn: _Conn tag) =>
    _log.info() and _log.i("active cluster connection established to: " +
      try _find_active(conn)?.string() else "" end)
    
    _send(conn, MsgExchangeAddrs(_known_addrs))
    _last_activity(conn) = _tick
  
  be _active_missed(conn: _Conn tag) =>
    _log.warn() and _log.w("active cluster connection missed: " +
      try _find_active(conn)?.string() else "" end)
    
    _remove_active(conn)
  
  be _passive_lost(conn: _Conn tag) =>
    _log.warn() and _log.w("passive cluster connection lost")
    _remove_passive(conn)
  
  be _active_lost(conn: _Conn tag) =>
    _log.warn() and _log.w("active cluster connection lost: " +
      try _find_active(conn)?.string() else "" end)
    
    _remove_active(conn)
  
  be _passive_error(conn: _Conn tag, a: String, b: String) =>
    _log.warn() and _log.w("passive cluster connection error: " + a + "; " + b)
    _remove_passive(conn)
  
  be _active_error(conn: _Conn tag, a: String, b: String) =>
    _log.warn() and _log.w("active cluster connection error: " + a + "; " + b)
    _remove_active(conn)
  
  be _passive_frame(conn: _Conn tag, data: Array[U8] val) =>
    try
      let msg = _serial.from_bytes[Msg](data)?
      _log.debug() and _log.d("received" + msg.string())
      _passive_msg(conn, msg)
    else
      _passive_error(conn, "invalid message on passive cluster connection", "")
    end
  
  be _active_frame(conn: _Conn tag, data: Array[U8] val) =>
    try
      let msg = _serial.from_bytes[Msg](data)?
      _log.debug() and _log.d("received " + msg.string())
      _active_msg(conn, msg)
    else
      _active_error(conn, "invalid message on active cluster connection", "")
    end
  
  fun ref _send(conn: _Conn tag, msg: Msg box) =>
    _log.debug() and _log.d("sending " + msg.string())
    try conn.write(_serial.to_bytes(msg)?)
    else _log.err() and _log.e("failed to serialise message")
    end
  
  be _broadcast_bytes(data: Array[U8] val) =>
    _log.debug() and _log.d("broadcasting data")
    for conn in _actives.values() do conn.write(data) end
  
  fun tag broadcast_deltas(
    serial: _Serialise,
    deltas: (String, Array[(String, Any box)] box))
  =>
    try _broadcast_bytes(serial.to_bytes(MsgPushDeltas(deltas))?) end
  
  fun ref _converge_addrs(received_addrs: P2Set[Address] box) =>
    if _known_addrs.converge(received_addrs) then
      // Find any other addrs that have the same host and port as we do.
      // By our own assertion, they are outdated and need to be blacklisted.
      let blacklist = Array[Address]
      for addr in _known_addrs.values() do
        if (addr.host == _my_addr.host)
        and (addr.port == _my_addr.port)
        and (addr.name != _my_addr.name)
        then blacklist.push(addr)
        end
      end
      for addr in blacklist.values() do
        _log.info() and _log.i("blacklisting outdated address: " + addr.string())
        _known_addrs.unset(addr)
      end
      
      // Refresh our active connections based on these updated addresses.
      _sync_actives()
      
      // Also notify other nodes we're connected to of our updated addresses.
      for conn in _actives.values() do
        _send(conn, MsgExchangeAddrs(_known_addrs))
      end
    end
  
  fun ref _passive_msg(conn: _Conn tag, msg': Msg) =>
    _last_activity(conn) = _tick
    match msg'
    | let msg: MsgExchangeAddrs =>
      _converge_addrs(msg.known_addrs)
      _send(conn, MsgExchangeAddrs(_known_addrs))
    | let msg: MsgAnnounceAddrs =>
      _converge_addrs(msg.known_addrs)
      _send(conn, MsgPong)
    | let msg: MsgPushDeltas =>
      _database.converge_deltas(msg.deltas)
      _send(conn, MsgPong)
    else
      _passive_error(conn, "unhandled cluster message", msg'.string())
    end
  
  fun ref _active_msg(conn: _Conn tag, msg': Msg) =>
    _last_activity(conn) = _tick
    match msg'
    | let msg: MsgPong => None
    | let msg: MsgExchangeAddrs =>
      _converge_addrs(msg.known_addrs)
    else
      _active_error(conn, "unhandled cluster message", msg'.string())
    end
