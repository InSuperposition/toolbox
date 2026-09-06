# Retro snapshots

One JSON per `/retro` run (`YYYY-MM-DD-N.json`). Each holds the window's
metrics, per-author rollup, streak, and a tweetable line. `/retro` reads
the most recent one to compute week-over-week deltas — commit each new
snapshot so the trend line survives.

Narrative retros go to the conversation, not here; only the JSON is
persisted.
