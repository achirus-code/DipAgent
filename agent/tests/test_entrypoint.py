"""The container entrypoint: Home Assistant options → env vars, taking over /data."""

import json
import os

from app import entrypoint


def test_missing_options_file_means_plain_docker(tmp_path):
    assert entrypoint.read_options(tmp_path / "options.json") == {}


def test_options_file_is_read(tmp_path):
    path = tmp_path / "options.json"
    path.write_text(json.dumps({"exchange": "mock"}))
    assert entrypoint.read_options(path) == {"exchange": "mock"}
    path.write_text("[1, 2]")
    assert entrypoint.read_options(path) == {}


def test_all_options_become_strings():
    options = {"api_token": "t0k", "exchange": "mock", "tick_seconds": 30, "taker_fee": 0.0009, "mock_speed": 1}
    assert entrypoint.env_from_options(options, {}) == {
        "API_TOKEN": "t0k",
        "EXCHANGE": "mock",
        "TICK_SECONDS": "30",
        "TAKER_FEE": "0.0009",
        "MOCK_SPEED": "1",
    }


def test_empty_values_are_skipped_so_the_agent_generates_a_token():
    assert entrypoint.env_from_options({"api_token": "", "exchange": None}, {}) == {}


def test_existing_environment_wins():
    env = {"EXCHANGE": "revolutx"}
    assert entrypoint.env_from_options({"exchange": "mock", "tick_seconds": 5}, env) == {"TICK_SECONDS": "5"}


def test_unknown_keys_are_ignored():
    assert entrypoint.env_from_options({"SUPERVISOR_TOKEN": "x", "log_level": "debug"}, {}) == {}


def test_take_over_data_dir_skips_options_json(tmp_path, monkeypatch):
    (tmp_path / "dipagent.db").write_text("")
    (tmp_path / "api_token").write_text("t")
    (tmp_path / "options.json").write_text("{}")
    calls = []
    monkeypatch.setattr(os, "chown", lambda p, uid, gid: calls.append((p.name, uid, gid)))

    entrypoint.take_over_data_dir(tmp_path, 10001, 10001)

    assert sorted(calls) == [("api_token", 10001, 10001), ("dipagent.db", 10001, 10001), (tmp_path.name, 10001, 10001)]


def test_take_over_data_dir_survives_chown_errors(tmp_path, monkeypatch, capsys):
    (tmp_path / "engine.lock").write_text("")

    def fail(*_):
        raise PermissionError("nope")

    monkeypatch.setattr(os, "chown", fail)
    entrypoint.take_over_data_dir(tmp_path, 10001, 10001)
    assert "cannot chown" in capsys.readouterr().err
