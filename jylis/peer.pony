use "crdt"
use "net"

primitive PeerAddrHashFn
  fun hash(x: PeerAddr): U64 =>
    (0x2f * x._1.hash()) + (0x1f * x._2.hash()) + x._3.hash()
  
  fun eq(x: PeerAddr, y: PeerAddr): Bool =>
    (x._1 == y._1) and (x._2 == y._2) and (x._3 == y._3)

type PeerAddr is (String, String, String)

type PeerAddrP2Set is P2HashSet[PeerAddr, PeerAddrHashFn]

trait box PeerMsg

class box PeerMsgHello is PeerMsg
  let advert_addr: PeerAddr
  let peer_addrs: PeerAddrP2Set
  new box create(
    advert_addr': PeerAddr,
    peer_addrs': PeerAddrP2Set)
  =>
    advert_addr = advert_addr'
    peer_addrs = peer_addrs'

class Peer
  let addr: PeerAddr
  new create(addr': PeerAddr) =>
    (addr) = (addr')

type _Listen is TCPListener

class iso PeerListenNotify is TCPListenNotify
  let _cluster: Cluster
  let _signature: Array[U8] val
  new iso create(cluster': Cluster, signature': Array[U8] val) =>
    (_cluster, _signature) = (cluster', signature')
  
  fun ref not_listening(listen: TCPListener ref) => _cluster._listen_failed()
  fun ref listening(listen: TCPListener ref) => _cluster._listen_ready()
  fun ref connected(listen: TCPListener ref): FramedNotify^ =>
    let inner: TCPConnectionNotify iso = ClusterNotify(_cluster, _signature)
    FramedNotify(consume inner)
