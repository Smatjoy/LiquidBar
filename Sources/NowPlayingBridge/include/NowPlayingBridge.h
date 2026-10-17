#pragma once

/// Runs the Now Playing bridge loop. Never returns; exits when stdin closes.
/// Meant to be called from inside /usr/bin/perl, see NowPlayingBridge.m.
void npb_run(void);
