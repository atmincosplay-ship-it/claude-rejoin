"""
Wiring tests for the NOMO systems facade.

The facade is pure delegation, so the ONE thing worth testing without a device
is: does every system method call the underlying harness function with the
exact right arguments? A typo in arg order here is the only real bug this layer
can introduce. These tests catch that and run anywhere (no su, no Android, no
Roblox) — which is exactly what CI can check.

The facade looks up harness functions as module globals at call time, so we
replace those globals on the nomo_systems module with spies and assert the call.
"""

import types
import pytest
from unittest.mock import MagicMock

import nomo_systems as ns


# Names the facade delegates to. We stub every one so importing/using the facade
# never needs the real 23k-line harness.
DELEGATES = [
    "load_runtime", "save_runtime", "get_runtime_tab",
    "package_pids", "package_alive", "force_stop_package", "clear_package_cache",
    "read_state", "state_is_fresh", "state_is_clean", "state_is_clean_fresh",
    "evaluate_package_health",
    "open_roblox", "wait_until_fresh_after_open", "should_force_disconnect_rejoin",
    "apply_rejoin_action", "queue_disconnect_ui_rejoin",
    "active_rejoin_mode", "set_active_rejoin_mode",
    "_nomo_start_market_rejoin_original", "start_rejoin_only",
    "start_booster_safe_rejoiner", "start_hatcher_safe_rejoiner",
]


@pytest.fixture
def spies(monkeypatch):
    m = {}
    for name in DELEGATES:
        spy = MagicMock(name=name, return_value=f"<{name}>")
        monkeypatch.setattr(ns, name, spy, raising=False)
        m[name] = spy
    # get_runtime_tab must return a real dict for health()
    m["get_runtime_tab"].return_value = {"package": "nomomarket"}
    return m


@pytest.fixture
def sys_(spies):
    cfg = {"env": "test"}
    rt = {}                      # pass rt so load_runtime() is not called
    hcfg = {"hatch": True}
    queue = []
    return ns.build_systems(cfg, rt=rt, hcfg=hcfg, open_queue=queue)


# --- Ctx -------------------------------------------------------------------

def test_ctx_does_not_load_runtime_when_rt_passed(spies):
    ns.build_systems({"a": 1}, rt={})
    spies["load_runtime"].assert_not_called()


def test_ctx_loads_runtime_when_rt_omitted(spies):
    ns.build_systems({"a": 1})
    spies["load_runtime"].assert_called_once()


# --- ProcessSystem ---------------------------------------------------------

def test_stop_uses_exact_pid_path(sys_, spies):
    sys_.rejoin.stop("nomomarket")
    spies["force_stop_package"].assert_called_once_with(
        "nomomarket", {"env": "test"}, tries=3, wait_after=0.8, settle=1.0
    )


def test_proc_alive_passes_fresh(sys_, spies):
    sys_.proc.alive("nomohatch1", fresh=True)
    spies["package_alive"].assert_called_once_with(
        "nomohatch1", {"env": "test"}, fresh=True
    )


def test_clear_cache_args(sys_, spies):
    sys_.rejoin.clear_cache("nokaA", reason="restock")
    spies["clear_package_cache"].assert_called_once_with(
        "nokaA", {"env": "test"}, rt_tab=None, reason="restock"
    )


# --- StateSystem -----------------------------------------------------------

def test_state_read(sys_, spies):
    sys_.state.read({"package": "nomomarket"})
    spies["read_state"].assert_called_once_with({"package": "nomomarket"})


def test_state_is_clean_fresh_passes_cfg(sys_, spies):
    sys_.state.is_clean_fresh({"ts": 1}, seconds=45)
    spies["state_is_clean_fresh"].assert_called_once_with(
        {"ts": 1}, {"env": "test"}, seconds=45
    )


def test_health_threads_rt_tab_and_hcfg(sys_, spies):
    tab = {"package": "nomomarket"}
    sys_.state.health(tab, mode="hatcher")
    spies["evaluate_package_health"].assert_called_once_with(
        tab, {"env": "test"}, {"package": "nomomarket"},
        mode="hatcher", hcfg={"hatch": True},
        prof=None, raw_alive=None, state=None, err=None,
    )


# --- RejoinSystem: open / wait / decide ------------------------------------

def test_open_full_arg_passthrough(sys_, spies):
    sys_.rejoin.open("nomomarket", "roblox://x", soft=True, reason="kick",
                     require_stop=False, skip_force_stop=True)
    spies["open_roblox"].assert_called_once_with(
        "nomomarket", "roblox://x", {"env": "test"},
        soft=True, rt_tab=None, reason="kick",
        require_stop=False, skip_force_stop=True,
    )


def test_wait_fresh_passes_rt_and_opened_at(sys_, spies):
    sys_.rejoin.wait_fresh({"package": "nokaA"}, 123456, timeout_override=30)
    spies["wait_until_fresh_after_open"].assert_called_once_with(
        {"package": "nokaA"}, {"env": "test"}, {}, 123456,
        timeout_override=30, allow_solver_probe=True,
    )


def test_should_force_disconnect(sys_, spies):
    sys_.rejoin.should_force_disconnect(True, 999)
    spies["should_force_disconnect_rejoin"].assert_called_once_with(
        True, 999, {"env": "test"}
    )


def test_act_uses_shared_queue_and_rt(sys_, spies):
    tab, rt_tab, health = {"package": "p"}, {"x": 1}, {"ok": True}
    sys_.rejoin.act(tab, "market", rt_tab, health, mode="booster")
    spies["apply_rejoin_action"].assert_called_once_with(
        [], tab, "market", rt_tab, {"env": "test"}, {}, health,
        hcfg={"hatch": True}, mode="booster",
    )


def test_queue_disconnect_ui(sys_, spies):
    tab, rt_tab = {"package": "p"}, {"x": 1}
    sys_.rejoin.queue_disconnect_ui(tab, "market", rt_tab)
    spies["queue_disconnect_ui_rejoin"].assert_called_once_with(
        [], tab, "market", rt_tab, {"env": "test"}
    )


# --- mode dispatch: run() must match start_rejoin(cfg) ---------------------

def test_run_dispatches_rejoin_only(sys_, spies):
    spies["active_rejoin_mode"].return_value = "rejoin_only"
    sys_.rejoin.run()
    spies["start_rejoin_only"].assert_called_once_with({"env": "test"})
    spies["_nomo_start_market_rejoin_original"].assert_not_called()


def test_run_dispatches_market_by_default(sys_, spies):
    spies["active_rejoin_mode"].return_value = "market"
    sys_.rejoin.run()
    spies["_nomo_start_market_rejoin_original"].assert_called_once_with({"env": "test"})
    spies["start_rejoin_only"].assert_not_called()


def test_set_mode(sys_, spies):
    sys_.rejoin.set_mode("booster")
    spies["set_active_rejoin_mode"].assert_called_once_with("booster", {"env": "test"})
