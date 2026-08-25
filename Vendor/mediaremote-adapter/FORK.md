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

## Re-syncing with upstream

Diff this tree against the upstream revision above, replay the patches listed
here, then update the revision recorded in this file.
