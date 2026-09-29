# MCP server: driving Framewright from an AI agent (plan, 2026-09-29, proposed)

## Goal
An AI agent (Claude Code, a desktop assistant, a script) can open Framewright's project, import media, build and
change the timeline, look at frames, and export, through the Model Context Protocol (MCP): the same JSON-RPC tool
interface those agents already speak. The user watches the edits happen in the app, can undo an agent's batch in
one step, and can switch the whole thing off. Nothing is exposed that the app's own UI cannot do.

## Shape
- **Where the server lives:** inside the running app, on a Unix domain socket in the app's container
  (`~/Library/Containers/com.justjohn12345.framewright/Data/mcp.sock`, mode 0600). A Unix socket needs no
  network entitlement, is reachable only by the same user, and dies with the app. Localhost HTTP is not offered
  in slice 1 (it would need `com.apple.security.network.server` and a bearer token story).
- **How a client attaches:** MCP clients speak stdio to a server process, so the app bundles a tiny command line
  shim, `Framewright.app/Contents/MacOS/framewright-mcp`, that bridges stdio to the socket (and launches the app
  if it is not running, via `open -b`). A client config is one line:
  `{"command": "/Applications/Framewright.app/Contents/MacOS/framewright-mcp"}`. The shim is plain Swift on
  Foundation, no sandbox, no UI.
- **Protocol:** MCP over JSON-RPC 2.0: `initialize`, `tools/list`, `tools/call`, `resources/list`,
  `resources/read`, notifications for progress. The official Swift MCP SDK (MIT, SPM) if its transport can be
  given the socket; otherwise a hand-rolled server of the five methods (the protocol surface used here is
  small, about 500 lines). Decide in the first day and record it.
- **Threading:** every tool call is marshalled to the main thread and goes through `ProjectStore`, the same
  paths the UI uses, so selection, undo, the status line and the monitors stay coherent and the user sees the
  edits live. Calls are serialised; a call that arrives during a user gesture waits for the gesture to end.
- **Undo grouping:** each `tools/call` is one undo step; a client may open a named batch (`batch_begin` /
  `batch_end`) so a whole agent operation is one step, shown in the Edit menu as "Undo Agent: <label>".
- **Safety and consent:** off by default; Preferences > Agents has the switch and shows the socket path and the
  connected client's name. The status line shows "Agent connected" while a session is open. Destructive tools
  (deleting media from the bin, overwriting a file on export, New/Open with unsaved changes) require
  `confirm: true` in the call and are also gated by the app's normal prompts. The server never reads files
  outside what the app's sandbox already can (imports go through the same security-scoped bookmark path; the
  agent passes a path the user has already granted, or the app asks the user).

## Tools (slice 1)
All take and return JSON; ids are the facade's ids; times are `{value, timescale}` or seconds for convenience,
frames where the app thinks in frames. Names are stable API.
- Project: `project_new`, `project_open(path)`, `project_save(path?)`, `project_info`.
- Media: `media_import(paths[])`, `media_list`, `media_info(assetId)`.
- Sequence and reading: `sequence_info`, `sequence_snapshot` (tracks, clips, spans, transitions as the facade's
  snapshot), `clip_info(clipId)`, `frame_at(time, width?)` (a PNG, base64, of the composed program frame:
  the agent can look), `thumbnail(assetId, time)`.
- Edits: `insert(assetId, at, trackId?, in?, out?)`, `overwrite(...)`, `move(clipId, to, trackId?)`,
  `trim(clipId, edge, to)`, `split(clipId, at)`, `delete(clipIds[], ripple?)`, `link`, `unlink`, `set_speed`,
  `set_reversed`, `add_transition(cut or edge, kind, duration, shares?)`, `set_transition_kind`,
  `remove_transition`, `add_span(clipId, kind, range, start, end, lane?)`, `set_span_values`,
  `set_span_range`, `remove_span`, `continue_motion(spanId)`, `set_clip_params(clipId, video/audio statics)`.
- Transport: `seek(time)`, `play`, `pause`, `current_time`.
- Export: `export_begin(preset, path, confirm?)`, `export_status`, `export_cancel`.
- Undo: `undo`, `redo`, `batch_begin(label)`, `batch_end`.
- Resources: `framewright://project` (the project JSON), `framewright://sequence/<id>` (the snapshot),
  `framewright://frame/<time>` (the picture). Tool descriptions carry the same wording as the app's help so an
  agent's mental model matches the user's.

## Slice 2
- `framewright-mcp --headless`: the engine alone (no window) for scripted use and CI; export and frame reads
  work, monitors do not.
- Streamable HTTP on localhost behind a token, for clients that cannot run a local process.
- Events: `notifications/resources/updated` when the user edits, so an agent watching the project sees changes.

## Tests
- An MCP client in AppTests over the socket: `initialize`, `tools/list` equals the documented set, then a
  scripted edit (import, insert, split, add a dissolve, add a Motion span, `frame_at` returns a PNG whose burn-in
  code matches the frame, export) with every call asserted to be one undo step and the store's model matching.
- Calls during a gesture wait; a second client is refused while one is connected; the switch off closes the
  socket; destructive calls without `confirm` are refused with the reason; the shim round-trips a request.
- The engine and app schemes stay green; the server adds no work when off.

## Risks
- The sandbox and the socket path: verify a non-sandboxed shim can connect to a socket inside the container
  (it can; the container is a normal directory for the same user) and that the path is stable across updates.
- Marshalling frames as PNG through JSON: cap `frame_at` at 1920 px wide and encode off the main thread.
- The MCP spec moves; pin the protocol version in `initialize` and test against the SDK's client.
