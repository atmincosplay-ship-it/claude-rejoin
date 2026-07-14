# ==========================================================================
# NOMO SYSTEMS — Phase 1: RejoinSystem (+ Process/State it depends on)
# ==========================================================================
# Drop-in facade. Paste this block at the BOTTOM of nomo_rejoin.py (after the
# functions it wraps are defined), OR keep it here and `from nomo_rejoin import *`
# at the top of this file.
#
# WHY THIS IS SAFE:
#   Every method just calls an EXISTING module-level function with the exact
#   same args. Behavior is identical to calling those functions directly, so
#   you can wire this in one mode at a time and roll back instantly.
#
# HOW TO ADOPT:
#   1. Build the systems once:
#          sys = build_systems(cfg)
#   2. Replace scattered calls with the system API as you touch each area:
#          open_roblox(pkg, link, cfg, soft=True)   ->   sys.rejoin.open(pkg, link, soft=True)
#          force_stop_package(pkg, cfg)             ->   sys.rejoin.stop(pkg)
#          read_state(tab)                          ->   sys.state.read(tab)
#   3. LATER (Phase 2): when a function needs real changes, move its body INTO
#      the method and delete the module-level version. No big-bang rewrite.
#
# ADDING A FUTURE FEATURE (the whole point):
#   New behavior lives in one place. Example — a "gentle first, hard second"
#   reopen policy becomes a RejoinSystem method; callers still just do
#   sys.rejoin.reopen(pkg, link). See reopen() at the bottom for the pattern.
# ==========================================================================


class Ctx:
    """Shared runtime handed to every system. Kills the cfg/rt/hcfg/open_queue
    argument soup — pass one Ctx instead of five positional args."""

    def __init__(self, cfg, rt=None, hcfg=None, open_queue=None):
        self.cfg = cfg
        self.rt = rt if rt is not None else load_runtime()
        self.hcfg = hcfg
        self.open_queue = open_queue if open_queue is not None else []

    def tab_rt(self, package):
        """Per-package runtime dict (creates it if missing)."""
        return get_runtime_tab(self.rt, package)

    def save(self):
        save_runtime(self.rt)


class ProcessSystem:
    """The sibling-safe PID layer. Everything that stops a clone goes THROUGH
    here — never reimplement a kill elsewhere. There is deliberately no
    am force-stop / killall / pkill anywhere in this system."""

    def __init__(self, ctx: Ctx):
        self.ctx = ctx

    def pids(self, package):
        return package_pids(package, self.ctx.cfg)

    def alive(self, package, fresh=False):
        return package_alive(package, self.ctx.cfg, fresh=fresh)

    def stop(self, package, tries=3, wait_after=0.8, settle=1.0):
        """Exact-PID stop only. Returns (ok, msg)."""
        return force_stop_package(
            package, self.ctx.cfg, tries=tries, wait_after=wait_after, settle=settle
        )

    def clear_cache(self, package, rt_tab=None, reason=""):
        return clear_package_cache(package, self.ctx.cfg, rt_tab=rt_tab, reason=reason)


class StateSystem:
    """State read + freshness/health. The single source of truth for 'is this
    clone actually fine?' so rejoin decisions don't re-derive it."""

    def __init__(self, ctx: Ctx):
        self.ctx = ctx

    def read(self, tab):
        """-> (state_dict | None, err_str). Age is already computed inside."""
        return read_state(tab)

    def is_fresh(self, state, seconds=None):
        return state_is_fresh(state, self.ctx.cfg, seconds=seconds)

    def is_clean(self, state):
        return state_is_clean(state)

    def is_clean_fresh(self, state, seconds=None):
        return state_is_clean_fresh(state, self.ctx.cfg, seconds=seconds)

    def health(self, tab, mode="market", hcfg=None, prof=None,
               raw_alive=None, state=None, err=None):
        rt_tab = self.ctx.tab_rt(tab.get("package"))
        return evaluate_package_health(
            tab, self.ctx.cfg, rt_tab, mode=mode,
            hcfg=hcfg if hcfg is not None else self.ctx.hcfg,
            prof=prof, raw_alive=raw_alive, state=state, err=err,
        )


class RejoinSystem:
    """The core. Opening, stopping, and deciding-to-rejoin a clone.
    Depends on Process + State (passed in, not global) so the wiring is a DAG."""

    def __init__(self, ctx: Ctx, proc: ProcessSystem, state: StateSystem):
        self.ctx = ctx
        self.proc = proc
        self.state = state

    # ---- primitives (delegate to Process so there's one kill path) ----------
    def stop(self, package, **kw):
        return self.proc.stop(package, **kw)

    def clear_cache(self, package, rt_tab=None, reason=""):
        return self.proc.clear_cache(package, rt_tab=rt_tab, reason=reason)

    # ---- open / launch ------------------------------------------------------
    def open(self, package, link, soft=False, rt_tab=None, reason="",
             require_stop=True, skip_force_stop=False):
        return open_roblox(
            package, link, self.ctx.cfg, soft=soft, rt_tab=rt_tab, reason=reason,
            require_stop=require_stop, skip_force_stop=skip_force_stop,
        )

    def wait_fresh(self, tab, opened_at, timeout_override=None, allow_solver_probe=True):
        return wait_until_fresh_after_open(
            tab, self.ctx.cfg, self.ctx.rt, opened_at,
            timeout_override=timeout_override, allow_solver_probe=allow_solver_probe,
        )

    # ---- decisions ----------------------------------------------------------
    def should_force_disconnect(self, alive, age):
        return should_force_disconnect_rejoin(alive, age, self.ctx.cfg)

    def act(self, tab, target, rt_tab, health, mode="market", hcfg=None):
        """Apply the chosen rejoin action against the shared open_queue."""
        return apply_rejoin_action(
            self.ctx.open_queue, tab, target, rt_tab, self.ctx.cfg, self.ctx.rt,
            health, hcfg=hcfg if hcfg is not None else self.ctx.hcfg, mode=mode,
        )

    def queue_disconnect_ui(self, tab, target, rt_tab):
        return queue_disconnect_ui_rejoin(
            self.ctx.open_queue, tab, target, rt_tab, self.ctx.cfg
        )

    # ---- mode selection + runners ------------------------------------------
    def mode(self):
        return active_rejoin_mode(self.ctx.cfg)

    def set_mode(self, mode):
        return set_active_rejoin_mode(mode, self.ctx.cfg)

    def run(self):
        """Master entry — mirrors start_rejoin(cfg) exactly."""
        if self.mode() == "rejoin_only":
            return self.run_rejoin_only()
        return self.run_market()

    def run_market(self):
        return _nomo_start_market_rejoin_original(self.ctx.cfg)

    def run_rejoin_only(self):
        return start_rejoin_only(self.ctx.cfg)

    def run_booster(self):
        return start_booster_safe_rejoiner(self.ctx.cfg)

    def run_hatcher(self):
        return start_hatcher_safe_rejoiner(self.ctx.cfg)

    # ---- Phase-2 example: a NEW feature that lives in ONE place -------------
    def reopen(self, package, link, rt_tab=None, reason="reopen"):
        """Gentle-first reopen: try soft, fall back to hard stop + open.
        This is the shape future features take — callers just call reopen();
        the policy is contained here instead of threaded through call sites."""
        ok, _ = self.open(package, link, soft=True, rt_tab=rt_tab, reason=reason,
                          require_stop=False, skip_force_stop=True) if False else (True, "")
        # ^ placeholder: wire your real soft-open here. Falls through to hard:
        self.stop(package)
        return self.open(package, link, soft=False, rt_tab=rt_tab, reason=reason)


def build_systems(cfg, rt=None, hcfg=None, open_queue=None):
    """One call wires the whole DAG. Reuse `sys` for a whole loop/session so
    every system shares the same cfg/rt/open_queue."""
    ctx = Ctx(cfg, rt=rt, hcfg=hcfg, open_queue=open_queue)
    proc = ProcessSystem(ctx)
    state = StateSystem(ctx)
    rejoin = RejoinSystem(ctx, proc, state)

    class _Systems:
        pass

    s = _Systems()
    s.ctx = ctx
    s.proc = proc
    s.state = state
    s.rejoin = rejoin
    return s
