# Dictify fork of `mediaremote-adapter`

Upstream: https://github.com/ejbills/mediaremote-adapter
Vendored from `master` at `cf30c4f1af29b5829d859f088f8dbdf12611a046`.

Vendored rather than consumed as a remote package for two reasons: the project
tracked upstream's `master` branch (an unpinned moving target for a component
that drives a private system framework), and Dictify needs a behaviour change
that upstream does not provide.

## Local patches

### 1. Emit now-playing payloads that have no title

`Sources/CIMediaRemote/MediaRemoteAdapter.m`, `processNowPlayingInfo`.

Upstream bailed out - printing *nothing at all* on stdout - when the
now-playing item had no `kMRMediaRemoteNowPlayingInfoTitle`. `MediaController`
maps an empty response to `onReceive(nil)`, which is indistinguishable from
"nothing is playing". Any source that does not publish a title was therefore
invisible: untagged local files, QuickTime Player, VLC/IINA, and every web
player that never calls `navigator.mediaSession.setMetadata`. Dictify's
"pause media while dictating" silently did nothing for those sources while
working fine for Music/Spotify/YouTube, which is what made the bug look
intermittent.

The title is optional metadata; the playback state is not. The payload is now
always emitted and the caller decides which fields it needs.

### 2. A blocking command path for app termination

`Sources/MediaRemoteAdapter/MediaController.swift`, `sendCommandBlocking` /
`playBlocking`.

`sendCommand` dispatches the write onto a background queue and returns. A
caller inside `applicationWillTerminate` gets no further turn of the run loop,
so the queued write is simply lost and media the app paused stays paused after
the app quits. `playBlocking()` performs the same write on the calling thread.

### 3. A way to tell that the listener stopped reporting

`Sources/MediaRemoteAdapter/MediaController.swift`, `isListenerActive`.

`onListenerTerminated` is suppressed when the helper dies having only ever
emitted `NIL` (`eventCount` is still 0), and it never fires at all when a
respawn fails to launch. A caller that caches the last report then keeps
answering from a process that no longer exists - for Dictify that means
"nothing is playing" forever, and the pause silently stops happening, which is
the bug this whole component exists to avoid. `isListenerActive` reports
whether any further reports are coming. It stays `true` across the internal
100-event restart (`isRestartPending`) so a caller cannot race that restart by
starting a second helper.

## Licensing

Upstream `ejbills/mediaremote-adapter` ships no `LICENSE` file, but its sources
carry BSD 3-Clause headers from the project it derives from,
`ungive/mediaremote-adapter` (Copyright (c) 2025 Jonas van den Berg). BSD-3
requires the licence text and disclaimer to travel with redistributed source,
so `LICENSE` here is that project's, and the per-file copyright headers are
left intact.

Two files carry their own separate notices, also unmodified:
`Sources/CIMediaRemote/include/MediaRemote.h` (Copyright (c) 2013-2014 Cykey /
David Murray - reverse-engineered framework header) and
`Sources/CIMediaRemote/include/MediaRemoteAdapter.h` (Copyright (c) 2024 Ethan
Bills).

## Re-syncing with upstream

Diff this tree against the upstream revision above, replay the patches listed
here, then update the revision recorded in this file. `LICENSE` is not
upstream's file - carry it across unchanged.
