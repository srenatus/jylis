use "crdt"
use "resp"
use "promises"

class val System
  let _sys: _System
  new val create(config': Config) =>
    _sys = _System(config')
    config'.log.set_sys(_sys)
  
  fun repo(): RepoManagerAny => _sys

actor _System is RepoManagerAny
  let _config: Config
  let _core: RepoManagerCore[RepoSYSTEM, RepoSYSTEMHelp]
  
  new create(config': Config) =>
    _config = config'
    _core   = _core.create("SYSTEM", _config.addr.hash64())
  
  be apply(resp: Respond, cmd: Array[String] val) =>
    _core(resp, cmd)
  
  be flush_deltas(fn: _SendDeltasFn) =>
    _core.flush_deltas(fn)
  
  be converge_deltas(deltas: Array[(String, Any box)] val) =>
    _core.converge_deltas(deltas)
  
  be clean_shutdown(promise: Promise[None]) =>
    _core.clean_shutdown(promise)
  
  ///
  // System private methods, meant for use only within the jylis server.
  // Generally, the purpose is to fill data that is read-only to the user.
  
  be log(string': String) =>
    let string: String = _config.addr.string().>push(' ').>append(string')
    _core.repo()._inslog(string)
    _core.repo()._trimlog(_config.system_log_trim)
