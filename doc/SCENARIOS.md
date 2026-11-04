# Scenario checks

`make scenarios [ONLY=glob] [SCN_N=4] [TRACE=1]` runs every `tools/scenarios/*.json` SCN_N times (seeds 1..N) into `build/scenarios/` and scores its `scenario.check` list. A scenario passes when each check holds in at least `pass_rate` (default 0.5) of its runs and no run has a script error. The make target exits 1 if any scenario fails.

## Check forms

| Form | Reads |
| --- | --- |
| `{"ship": "SP1", "end": "torpedoes_fired", "op": ">=", "value": 1}` | the ship's metrics row at the end; `a+b` sums fields |
| `{"match": "winning_team", "op": "==", "value": 1}` | top-level metrics |
| `{"ship": "SP1", "scn": "skill", "op": "==", "value": "Disengage", "within_s": 20}` | traced SCN lines over time |

- **`ship`:** a ship name or player id.
- **`op`:** `== != >= <= > <`, or `has` (substring).
- **`value`:** a literal, or `{"ship", "end"}` to compare against another ship's metric.

### SCN checks

- **Fields:** any `key=value` on the SCN line (`skill`, `seen`, `shots`, `hp`, `d`, `spd`, `hdg`, `dis`, `prio`...), `stance` (the text after `|`), `off_bow:<ship>`: degrees from our bow to that ship, 0 = bow-on, 180 = stern-on, and `dist:<ship>`: metres to it. Both ships must be traced.
- **Window:** `from_s` (default 0) and `to_s`. `from_s` may instead be an event, `{"ship", "scn", "op", "value"}`: the first sample where it holds.
- **Pass rule:**
  - `within_s`: true at some sample within that many seconds of `from_s`.
  - `share`: true for at least that fraction of samples.
  - neither: true at every sample.
- **`delta: true`:** values relative to the window's first sample, e.g. shots fired since an event.

## Scenario fields

Per-ship setup fields (`pos`, `fixed`, `bloom_m`/`bloom_s`, `lkp`, `consumables`...) are listed at the top of `src/server/bot_scenario.gd`.
