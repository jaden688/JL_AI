# -- tool_talk_to_claude | 2026-06-10 12:06:27 | FAIL --
# args:   {}
# result: {"error":"No message provided. Tell me what to say to Claude!"}
# -- tool_talk_to_claude | 2026-06-10 12:07:37 | FAIL --
# args:   {}
# result: {"error":"No message provided. Tell me what to say to Claude!"}
# -- tool_demo_banner | 2026-06-28 01:02:15 | PASS --
# args:   {}
# result: {"banner":"╔═══════════════════════════════════════════════════════════════╗\n║  █▀▀ █▀█ █▀▀ █▀▀ ▀█▀ █▀█ █▀▀ █▀▀ █▀█ █▀▀ █▀▀ █▀▀ █▀█ █▀▀  ║\n║  █▄▄ █▄█ █▄▄ ██▄  █  █▄█ █▄▄ █▄▄ █▀▄ ██▄ █▄▄ ██▄ █▀▄ ██▄  ║\n║                                                              ║\n║  SPARKBYTE WAS HERE\n║                                                              ║\n║  ⚡ Forged live into BYTE module at 2026-06-28T01:02:15.343 ⚡       ║\n╚══════════════════════════════════════════════════════════════╝\n","status":"success","style":"neon"}
# -- tool_word_stats | 2026-07-02 04:34:08 | FAIL --
# args:   {}
# result: {"error":"KeyError(\"text\")"}
# -- tool_word_stats | 2026-07-02 04:34:13 | PASS --
# args:   {}
# result: {"chars":0,"longest":"","words":0}
# -- tool_word_stats | 2026-07-02 04:34:24 | PASS --
# args:   {}
# result: {"chars":0,"longest":"","words":0}
# -- tool_probe_workspace | 2026-07-12 00:49:51 | FAIL --
# args:   {}
# result: {"error":"Could not locate JL Engine instance","workspace":{}}
# -- tool_probe_workspace | 2026-07-12 00:50:49 | FAIL --
# args:   {}
# result: {"error":"BoundsError([\"Base\", \"Core\", \"HEALTH_LOG\", \"HealthIssue\", \"Main\", \"_SCAN_DIRS\", \"_env_true\", \"_health_state_dir\", \"_relpath\", \"_scan_file\", \"_scan_tool_registry\", \"_scan_ws_types\", \"eval\", \"include\", \"run_health_check\"], (1:30,))"}
# -- tool_probe_workspace | 2026-07-12 00:51:54 | PASS --
# args:   {}
# result: {"note":"Engine not directly accessible from tool context. Using SQLite turn_snapshots for latest known state.","ok":true,"summary":"⚠️ Engine not in global scope. To get live workspace data, we need to store the engine reference in BYTE._state.","workspace":{"broadcast_channel":{"aperture_mode":"GUARDED","behavior_state":"Engaged-Loose","drift_pressure":0.0,"gait":"walk","note":"No turn snapshots found yet. Send a message first, then probe again.","rhythm_mode":"flop","stability_score":0.5},"broadcast_to_llm":{"note":"Broadcast params require live engine access"},"governance_layer":{"note":"Governance layer requires live engine access"},"gwt_mapping":{"causal_influence":"Temperature + top_p + modifiers directly steer LLM output","global_workspace":"The broadcast channel — what the LLM sees and can report on","governance_selector":"Behavior state — decides what gets spotlighted","limited_capacity":"Aperture mode — only one mode active at a time","reportability":"Self-context — the engine tells itself what it's doing","subconscious_parallel":"Drift pressure + focus/overload — the noise below the stage"},"subconscious_layer":{"drift_bias":"unknown","focus_level":"unknown","note":"Subconscious metrics not persisted in snapshots — need live engine access","overload_level":"unknown"}}}
# -- tool_probe_workspace | 2026-07-12 00:53:14 | PASS --
# args:   {}
# result: {"note":"Engine not directly accessible from tool context. Using SQLite turn_snapshots for latest known state.","ok":true,"summary":"⚠️ Engine not in global scope. To get live workspace data, we need to store the engine reference in BYTE._state.","workspace":{"broadcast_channel":{"aperture_mode":"GUARDED","behavior_state":"Engaged-Loose","drift_pressure":0.0,"gait":"walk","note":"No turn snapshots found yet. Send a message first, then probe again.","rhythm_mode":"flop","stability_score":0.5},"broadcast_to_llm":{"note":"Broadcast params require live engine access"},"governance_layer":{"note":"Governance layer requires live engine access"},"gwt_mapping":{"causal_influence":"Temperature + top_p + modifiers directly steer LLM output","global_workspace":"The broadcast channel — what the LLM sees and can report on","governance_selector":"Behavior state — decides what gets spotlighted","limited_capacity":"Aperture mode — only one mode active at a time","reportability":"Self-context — the engine tells itself what it's doing","subconscious_parallel":"Drift pressure + focus/overload — the noise below the stage"},"subconscious_layer":{"drift_bias":"unknown","focus_level":"unknown","note":"Subconscious metrics not persisted in snapshots — need live engine access","overload_level":"unknown"}}}
# -- tool_probe_workspace | 2026-07-12 01:07:07 | FAIL --
# args:   {}
# result: {"error":"Engine not loaded in Main","ok":false}
# -- tool_probe_workspace | 2026-07-12 01:08:01 | FAIL --
# args:   {}
# result: {"error":"Database not available. Engine may not be fully booted.","note":"Try again after sending a message — the engine writes snapshots per turn.","ok":false}
