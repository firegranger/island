// Lit la musique en cours via MediaRemote (framework privé).
// Depuis macOS 15.4, seuls les binaires Apple y ont accès : ce dylib est donc
// chargé par /usr/bin/perl (voir bridge.pl), qui lui sert de "passe-droit".
// Sortie : une ligne JSON par changement sur stdout.
// Entrée : commandes texte sur stdin (toggle, next, prev, seek <secondes>).

#import <Foundation/Foundation.h>
#include <dlfcn.h>

typedef void (*MRRegisterFn)(dispatch_queue_t);
typedef void (*MRGetInfoFn)(dispatch_queue_t, void (^)(NSDictionary *));
typedef void (*MRGetPlayingFn)(dispatch_queue_t, void (^)(BOOL));
typedef void (*MRGetClientFn)(dispatch_queue_t, void (^)(id));
typedef NSString *(*MRClientStringFn)(id);
typedef Boolean (*MRSendCommandFn)(int, NSDictionary *);
typedef void (*MRSetElapsedFn)(double);

enum { kPlay = 0, kPause = 1, kToggle = 2, kNext = 4, kPrevious = 5 };

static MRGetInfoFn getInfo;
static MRGetPlayingFn getPlaying;
static MRGetClientFn getClient;
static MRClientStringFn clientBundle, clientParentBundle;
static MRSendCommandFn sendCommand;
static MRSetElapsedFn setElapsed;

static NSData *lastArtwork;
static BOOL emitScheduled;
static NSMutableData *inputBuffer;

static void writeLine(NSDictionary *payload) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    if (!json) return;
    fwrite(json.bytes, 1, json.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

static void emit(NSDictionary *info, BOOL playing, NSString *bundle) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    out[@"playing"] = @(playing);
    NSDictionary *keys = @{
        @"title": @"kMRMediaRemoteNowPlayingInfoTitle",
        @"artist": @"kMRMediaRemoteNowPlayingInfoArtist",
        @"album": @"kMRMediaRemoteNowPlayingInfoAlbum",
        @"duration": @"kMRMediaRemoteNowPlayingInfoDuration",
        @"elapsed": @"kMRMediaRemoteNowPlayingInfoElapsedTime",
        @"rate": @"kMRMediaRemoteNowPlayingInfoPlaybackRate",
    };
    for (NSString *key in keys) {
        id value = info[keys[key]];
        if ([value isKindOfClass:NSString.class] || [value isKindOfClass:NSNumber.class]) out[key] = value;
    }
    NSDate *timestamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
    if ([timestamp isKindOfClass:NSDate.class]) out[@"timestamp"] = @(timestamp.timeIntervalSince1970);
    if (bundle.length) out[@"bundle"] = bundle;

    // La pochette n'est envoyée que lorsqu'elle change ("" = plus de pochette).
    NSData *artwork = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
    if (![artwork isKindOfClass:NSData.class]) artwork = nil;
    BOOL same = (artwork == nil && lastArtwork == nil) || [artwork isEqualToData:lastArtwork];
    if (!same) {
        out[@"artwork"] = artwork ? [artwork base64EncodedStringWithOptions:0] : @"";
        lastArtwork = artwork;
    }
    writeLine(out);
}

static void refresh(void) {
    dispatch_queue_t q = dispatch_get_main_queue();
    getInfo(q, ^(NSDictionary *info) {
        getPlaying(q, ^(BOOL playing) {
            if (!getClient || !clientBundle) return emit(info, playing, nil);
            getClient(q, ^(id client) {
                NSString *bundle = nil;
                if (client && clientParentBundle) bundle = clientParentBundle(client);
                if (client && !bundle.length) bundle = clientBundle(client);
                emit(info, playing, bundle);
            });
        });
    });
}

// Regroupe les rafales de notifications MediaRemote en une seule mise à jour.
static void scheduleRefresh(void) {
    if (emitScheduled) return;
    emitScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 40 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        emitScheduled = NO;
        refresh();
    });
}

static void handleCommand(NSString *line) {
    if ([line isEqualToString:@"toggle"]) sendCommand(kToggle, nil);
    else if ([line isEqualToString:@"play"]) sendCommand(kPlay, nil);
    else if ([line isEqualToString:@"pause"]) sendCommand(kPause, nil);
    else if ([line isEqualToString:@"next"]) sendCommand(kNext, nil);
    else if ([line isEqualToString:@"prev"]) sendCommand(kPrevious, nil);
    else if ([line hasPrefix:@"seek "] && setElapsed) {
        setElapsed([line substringFromIndex:5].doubleValue);
        scheduleRefresh();
    }
}

static void readInput(void) {
    char buffer[1024];
    ssize_t n = read(STDIN_FILENO, buffer, sizeof buffer);
    if (n <= 0) exit(0); // l'app parente s'est fermée
    [inputBuffer appendBytes:buffer length:(NSUInteger)n];
    for (;;) {
        NSRange newline = [inputBuffer rangeOfData:[NSData dataWithBytes:"\n" length:1]
                                           options:0
                                             range:NSMakeRange(0, inputBuffer.length)];
        if (newline.location == NSNotFound) break;
        NSData *lineData = [inputBuffer subdataWithRange:NSMakeRange(0, newline.location)];
        [inputBuffer replaceBytesInRange:NSMakeRange(0, newline.location + 1) withBytes:NULL length:0];
        NSString *line = [[NSString alloc] initWithData:lineData encoding:NSUTF8StringEncoding];
        if (line.length) handleCommand(line);
    }
}

void island_bridge_run(void) {
    void *mr = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    if (!mr) { fprintf(stderr, "MediaRemote introuvable\n"); exit(1); }

    MRRegisterFn registerForNotifications = dlsym(mr, "MRMediaRemoteRegisterForNowPlayingNotifications");
    getInfo = dlsym(mr, "MRMediaRemoteGetNowPlayingInfo");
    getPlaying = dlsym(mr, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    getClient = dlsym(mr, "MRMediaRemoteGetNowPlayingClient");
    clientBundle = dlsym(mr, "MRNowPlayingClientGetBundleIdentifier");
    clientParentBundle = dlsym(mr, "MRNowPlayingClientGetParentAppBundleIdentifier");
    sendCommand = dlsym(mr, "MRMediaRemoteSendCommand");
    setElapsed = dlsym(mr, "MRMediaRemoteSetElapsedTime");
    if (!registerForNotifications || !getInfo || !getPlaying || !sendCommand) {
        fprintf(stderr, "API MediaRemote incomplète\n");
        exit(1);
    }

    registerForNotifications(dispatch_get_main_queue());
    for (NSString *name in @[
        @"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
        @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
        @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
    ]) {
        [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:nil
                                                    usingBlock:^(NSNotification *note) { scheduleRefresh(); }];
    }

    inputBuffer = [NSMutableData data];
    dispatch_source_t input = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, STDIN_FILENO, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(input, ^{ readInput(); });
    dispatch_resume(input);

    refresh();
    CFRunLoopRun();
}
