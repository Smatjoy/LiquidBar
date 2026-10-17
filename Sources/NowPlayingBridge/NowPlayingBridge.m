//  NowPlayingBridge
//
//  Since macOS 15.4, mediaremoted only answers Now Playing queries from
//  Apple-signed processes. This library is therefore not loaded into the app:
//  it is loaded into /usr/bin/perl (an Apple platform binary) via DynaLoader,
//  and talks to the app over stdio.
//
//    stdout  one JSON object per line describing the current Now Playing state
//    stdin   one command per line: play | pause | toggle | next | previous |
//            seek <seconds> | refresh | queue | queueplay <id> |
//            queueremove <id> | queuemove <id> <afterId>
//
//  The process exits when stdin closes, so it never outlives the app.

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <objc/message.h>
#include <stdio.h>
#include "NowPlayingBridge.h"

typedef void (*MRRegisterFn)(dispatch_queue_t);
typedef void (*MRGetInfoFn)(dispatch_queue_t, void (^)(NSDictionary *));
typedef void (*MRGetIsPlayingFn)(dispatch_queue_t, void (^)(Boolean));
typedef void (*MRGetClientFn)(dispatch_queue_t, void (^)(id));
typedef CFStringRef (*MRClientStringFn)(id);
typedef Boolean (*MRSendCommandFn)(int, NSDictionary *);
typedef void (*MRSetElapsedFn)(double);
// (request, origin, client, queue, completion), recovered by disassembly: it
// builds a player path from origin/client and calls ...ForPlayer.
typedef void (*MRRequestQueueFn)(id, id, id, dispatch_queue_t, void (^)(id, NSError *));
typedef CFStringRef (*MRItemStringFn)(id);
typedef CFDataRef (*MRItemDataFn)(id);

enum {
  kMRPlay = 0, kMRPause = 1, kMRTogglePlayPause = 2, kMRNextTrack = 4, kMRPreviousTrack = 5,
  // From MRMediaRemoteCopyCommandDescription.
  kMRRemoveFromPlaybackQueue = 129, kMRReorderPlaybackQueue = 130, kMRPlayItemInPlaybackQueue = 131,
};

static MRRegisterFn MRRegister;
static MRGetInfoFn MRGetInfo;
static MRGetIsPlayingFn MRGetIsPlaying;
static MRGetClientFn MRGetClient;
static MRClientStringFn MRClientBundleID;
static MRClientStringFn MRClientParentBundleID;
static MRSendCommandFn MRSendCommand;
static MRSetElapsedFn MRSetElapsed;
static MRRequestQueueFn MRRequestQueue;
static MRItemStringFn MRItemTitle, MRItemArtist, MRItemIdentifier;
static MRItemDataFn MRItemArtwork;
static NSString *optContentItemID, *optInsertAfterContentItemID;

static dispatch_queue_t workQueue;
static BOOL emitPending = NO;
static NSString *lastArtworkHash = nil;
static NSString *lastQueueTitle = nil;
static NSMutableSet<NSString *> *sentQueueArtwork;

static void writeLine(NSDictionary *object) {
  NSData *json = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
  if (!json) return;
  fwrite(json.bytes, 1, json.length, stdout);
  fputc('\n', stdout);
  fflush(stdout);
}

// FNV-1a over the whole payload. NSData's -hash only looks at a prefix, which
// collides for JPEGs that share a header.
static NSString *hashData(NSData *data) {
  uint64_t h = 0xcbf29ce484222325ULL;
  const uint8_t *bytes = data.bytes;
  for (NSUInteger i = 0; i < data.length; i++) {
    h ^= bytes[i];
    h *= 0x100000001b3ULL;
  }
  return [NSString stringWithFormat:@"%016llx", h];
}

static id orNull(id value) { return value ?: [NSNull null]; }
static NSString *const kMusicBundleID = @"com.apple.Music";
static void emitQueue(void);
static void emitQuality(void);

static void emitState(void) {
  MRGetInfo(workQueue, ^(NSDictionary *info) {
    MRGetIsPlaying(workQueue, ^(Boolean isPlaying) {
      void (^finish)(NSString *) = ^(NSString *bundleID) {
        // Only Apple Music is shown; any other player (a browser tab, a video
        // app) reads as "nothing playing".
        if (![bundleID isEqualToString:kMusicBundleID]) {
          lastQueueTitle = nil;
          writeLine(@{ @"type": @"state", @"playing": @NO, @"bundleID": orNull(bundleID) });
          return;
        }
        NSMutableDictionary *out = [NSMutableDictionary dictionary];
        out[@"type"] = @"state";
        // Boolean is an unsigned char; box it as a real BOOL so JSON gets true/false.
        out[@"playing"] = isPlaying ? @YES : @NO;
        out[@"bundleID"] = orNull(bundleID);
        out[@"title"] = orNull(info[@"kMRMediaRemoteNowPlayingInfoTitle"]);
        out[@"artist"] = orNull(info[@"kMRMediaRemoteNowPlayingInfoArtist"]);
        out[@"album"] = orNull(info[@"kMRMediaRemoteNowPlayingInfoAlbum"]);
        out[@"duration"] = orNull(info[@"kMRMediaRemoteNowPlayingInfoDuration"]);
        out[@"elapsed"] = orNull(info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"]);
        out[@"rate"] = orNull(info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"]);

        NSDate *timestamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
        out[@"timestamp"] = [timestamp isKindOfClass:[NSDate class]]
          ? @(timestamp.timeIntervalSince1970) : [NSNull null];

        NSData *artwork = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
        if ([artwork isKindOfClass:[NSData class]] && artwork.length > 0) {
          NSString *hash = hashData(artwork);
          out[@"artworkHash"] = hash;
          // Artwork is large; only ship the bytes when they change.
          if (![hash isEqualToString:lastArtworkHash]) {
            out[@"artwork"] = [artwork base64EncodedStringWithOptions:0];
            lastArtworkHash = hash;
          }
        } else {
          out[@"artworkHash"] = [NSNull null];
        }
        writeLine(out);
        emitQuality();
        // A new track shifts the queue; refresh it alongside.
        NSString *title = info[@"kMRMediaRemoteNowPlayingInfoTitle"];
        if (title && ![title isEqual:lastQueueTitle]) {
          lastQueueTitle = title;
          emitQueue();
        }
      };

      if (!MRGetClient || !MRClientBundleID) { finish(nil); return; }
      MRGetClient(workQueue, ^(id client) {
        NSString *bundleID = nil;
        if (client) {
          // Browser tabs report a WebKit helper; the parent is the browser itself.
          if (MRClientParentBundleID) bundleID = (__bridge NSString *)MRClientParentBundleID(client);
          if (!bundleID) bundleID = (__bridge NSString *)MRClientBundleID(client);
        }
        finish(bundleID);
      });
    });
  });
}

// MediaRemote fires several notifications per track change; coalesce them.
static void scheduleEmit(void) {
  dispatch_async(workQueue, ^{
    if (emitPending) return;
    emitPending = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_MSEC), workQueue, ^{
      emitPending = NO;
      emitState();
    });
  });
}

// Up to 30 items starting at the current one; artwork bytes are shipped once
// per distinct image, later items reference the hash.
static void emitQueue(void) {
  if (!MRRequestQueue) return;
  Class requestClass = NSClassFromString(@"MRPlaybackQueueRequest");
  id (*makeRequest)(Class, SEL, NSRange) = (void *)objc_msgSend;
  id request = makeRequest(requestClass, NSSelectorFromString(@"defaultPlaybackQueueRequestWithRange:"), NSMakeRange(0, 30));
  if (!request) return;
  ((void (*)(id, SEL, BOOL))objc_msgSend)(request, NSSelectorFromString(@"setIncludeMetadata:"), YES);
  ((void (*)(id, SEL, double))objc_msgSend)(request, NSSelectorFromString(@"setArtworkWidth:"), 96);
  ((void (*)(id, SEL, double))objc_msgSend)(request, NSSelectorFromString(@"setArtworkHeight:"), 96);

  MRRequestQueue(request, nil, nil, workQueue, ^(id queue, NSError *error) {
    NSMutableArray *items = [NSMutableArray array];
    NSInteger location = 0;
    if (queue && !error) {
      location = [[queue valueForKey:@"location"] integerValue];
      for (id item in [queue valueForKey:@"contentItems"]) {
        NSMutableDictionary *entry = [NSMutableDictionary dictionary];
        entry[@"id"] = orNull((__bridge NSString *)MRItemIdentifier(item));
        entry[@"title"] = orNull((__bridge NSString *)MRItemTitle(item));
        entry[@"artist"] = orNull((__bridge NSString *)MRItemArtist(item));
        NSData *art = MRItemArtwork ? (__bridge NSData *)MRItemArtwork(item) : nil;
        if (art.length) {
          NSString *hash = hashData(art);
          entry[@"artworkHash"] = hash;
          if (![sentQueueArtwork containsObject:hash]) {
            entry[@"artwork"] = [art base64EncodedStringWithOptions:0];
            [sentQueueArtwork addObject:hash];
          }
        }
        [items addObject:entry];
      }
    }
    writeLine(@{ @"type": @"queue", @"location": @(location), @"items": items,
                 @"supported": (queue != nil && error == nil) ? @YES : @NO });
  });
}

// The current item's audio format, as Liqoria's helper reads it: the
// content item's metadata `activeFormat` (else `preferredFormat`) `tier`,
// where 2 is Lossless, 3 Hi-Res Lossless and 4 Dolby Atmos.
static void emitQuality(void) {
  if (!MRRequestQueue) return;
  Class requestClass = NSClassFromString(@"MRPlaybackQueueRequest");
  id (*makeRequest)(Class, SEL, NSRange) = (void *)objc_msgSend;
  id request = makeRequest(requestClass, NSSelectorFromString(@"defaultPlaybackQueueRequestWithRange:"), NSMakeRange(0, 1));
  if (!request) return;
  ((void (*)(id, SEL, BOOL))objc_msgSend)(request, NSSelectorFromString(@"setIncludeMetadata:"), YES);

  MRRequestQueue(request, nil, nil, workQueue, ^(id queue, NSError *error) {
    NSString *quality = nil;
    NSString *title = nil;
    NSArray *items = queue && !error ? [queue valueForKey:@"contentItems"] : nil;
    id item = items.firstObject;
    if (item) {
      title = (__bridge NSString *)MRItemTitle(item);
      id metadata = [item valueForKey:@"metadata"];
      id format = [metadata valueForKey:@"activeFormat"] ?: [metadata valueForKey:@"preferredFormat"];
      switch ([[format valueForKey:@"tier"] integerValue]) {
        case 2: quality = @"lossless"; break;
        case 3: quality = @"hiResLossless"; break;
        case 4: quality = @"dolbyAtmos"; break;
        default: break;
      }
    }
    writeLine(@{ @"type": @"quality", @"quality": orNull(quality), @"title": orNull(title) });
  });
}

static void sendQueueCommand(int command, NSDictionary *options) {
  if (MRSendCommand(command, options)) {
    // The player updates its queue asynchronously; read it back shortly.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 350 * NSEC_PER_MSEC), workQueue, ^{ emitQueue(); });
  }
}

static void handleCommand(NSString *line) {
  NSArray<NSString *> *parts = [line componentsSeparatedByString:@" "];
  NSString *verb = parts.firstObject;
  if ([verb isEqualToString:@"play"]) MRSendCommand(kMRPlay, nil);
  else if ([verb isEqualToString:@"pause"]) MRSendCommand(kMRPause, nil);
  else if ([verb isEqualToString:@"toggle"]) MRSendCommand(kMRTogglePlayPause, nil);
  else if ([verb isEqualToString:@"next"]) MRSendCommand(kMRNextTrack, nil);
  else if ([verb isEqualToString:@"previous"]) MRSendCommand(kMRPreviousTrack, nil);
  else if ([verb isEqualToString:@"seek"] && parts.count > 1 && MRSetElapsed) {
    MRSetElapsed(parts[1].doubleValue);
  } else if ([verb isEqualToString:@"refresh"]) {
    dispatch_async(workQueue, ^{ lastArtworkHash = nil; [sentQueueArtwork removeAllObjects]; });
  } else if ([verb isEqualToString:@"queue"]) {
    dispatch_async(workQueue, ^{ emitQueue(); });
    return;
  } else if ([verb isEqualToString:@"queueplay"] && parts.count > 1 && optContentItemID) {
    sendQueueCommand(kMRPlayItemInPlaybackQueue, @{ optContentItemID: parts[1] });
  } else if ([verb isEqualToString:@"queueremove"] && parts.count > 1 && optContentItemID) {
    sendQueueCommand(kMRRemoveFromPlaybackQueue, @{ optContentItemID: parts[1] });
    return;
  } else if ([verb isEqualToString:@"queuemove"] && parts.count > 2 && optContentItemID && optInsertAfterContentItemID) {
    sendQueueCommand(kMRReorderPlaybackQueue, @{ optContentItemID: parts[1], optInsertAfterContentItemID: parts[2] });
    return;
  }
  scheduleEmit();
}

static NSString *stringConstant(void *handle, const char *name) {
  CFStringRef *ref = dlsym(handle, name);
  return ref ? (__bridge NSString *)*ref : [NSString stringWithUTF8String:name];
}

void npb_run(void) {
  @autoreleasepool {
    void *mr = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    if (!mr) { writeLine(@{ @"type": @"error", @"message": @"MediaRemote unavailable" }); exit(1); }

    MRRegister = dlsym(mr, "MRMediaRemoteRegisterForNowPlayingNotifications");
    MRGetInfo = dlsym(mr, "MRMediaRemoteGetNowPlayingInfo");
    MRGetIsPlaying = dlsym(mr, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    MRGetClient = dlsym(mr, "MRMediaRemoteGetNowPlayingClient");
    MRClientBundleID = dlsym(mr, "MRNowPlayingClientGetBundleIdentifier");
    MRClientParentBundleID = dlsym(mr, "MRNowPlayingClientGetParentAppBundleIdentifier");
    MRSendCommand = dlsym(mr, "MRMediaRemoteSendCommand");
    MRSetElapsed = dlsym(mr, "MRMediaRemoteSetElapsedTime");
    MRRequestQueue = dlsym(mr, "MRMediaRemoteRequestNowPlayingPlaybackQueue");
    MRItemTitle = dlsym(mr, "MRContentItemGetTitle");
    MRItemArtist = dlsym(mr, "MRContentItemGetTrackArtistName");
    MRItemIdentifier = dlsym(mr, "MRContentItemGetIdentifier");
    MRItemArtwork = dlsym(mr, "MRContentItemGetArtworkData");
    if (!MRItemTitle || !MRItemArtist || !MRItemIdentifier) MRRequestQueue = NULL;
    optContentItemID = stringConstant(mr, "kMRMediaRemoteOptionContentItemID");
    optInsertAfterContentItemID = stringConstant(mr, "kMRMediaRemoteOptionInsertAfterContentItemID");
    sentQueueArtwork = [NSMutableSet set];

    if (!MRRegister || !MRGetInfo || !MRGetIsPlaying || !MRSendCommand) {
      writeLine(@{ @"type": @"error", @"message": @"MediaRemote symbols missing" });
      exit(1);
    }

    workQueue = dispatch_queue_create("bridge.work", DISPATCH_QUEUE_SERIAL);
    MRRegister(workQueue);

    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    for (NSString *name in @[
      stringConstant(mr, "kMRMediaRemoteNowPlayingInfoDidChangeNotification"),
      stringConstant(mr, "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification"),
      stringConstant(mr, "kMRMediaRemoteNowPlayingApplicationDidChangeNotification"),
    ]) {
      [center addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *note) {
        scheduleEmit();
      }];
    }

    writeLine(@{ @"type": @"ready" });
    scheduleEmit();

    [NSThread detachNewThreadWithBlock:^{
      char buffer[512];
      while (fgets(buffer, sizeof buffer, stdin)) {
        NSString *line = [[NSString stringWithUTF8String:buffer]
          stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (line.length) handleCommand(line);
      }
      exit(0);
    }];

    CFRunLoopRun();
  }
}
