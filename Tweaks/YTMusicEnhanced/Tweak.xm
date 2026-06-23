# YTMusicEnhanced — Manual tweaks for YouTube Music
# Background playback + Ad removal + Download interception
# No third-party code — written from scratch

%config(generator=internal)

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MediaPlayer.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ===================================================================
// 1. BACKGROUND PLAYBACK
// ===================================================================

// Prevent audio session from being deactivated when app backgrounds
%hook AVAudioSession

- (BOOL)setActive:(BOOL)active 
      withOptions:(AVAudioSessionSetActiveOptions)options 
            error:(NSError **)outError {
    // Force active — background playback stays alive
    return %orig(YES, options, outError);
}

- (BOOL)setActive:(BOOL)active error:(NSError **)outError {
    return %orig(YES, outError);
}

%end

// Hook MPMusicPlayerController to prevent system music from stopping
%hook MPMusicPlayerController

- (void)pause {
    // Don't pause when backgrounding — check if we should actually pause
    UIApplicationState state = [[UIApplication sharedApplication] applicationState];
    if (state == UIApplicationStateBackground) {
        return; // Don't pause — user hit home button, not pause button
    }
    %orig;
}

- (void)stop {
    UIApplicationState state = [[UIApplication sharedApplication] applicationState];
    if (state == UIApplicationStateBackground) {
        return;
    }
    %orig;
}

%end

// Also hook AVPlayer for non-MPMusicPlayer playback paths
%hook AVPlayer

- (void)pause {
    UIApplicationState state = [[UIApplication sharedApplication] applicationState];
    if (state == UIApplicationStateBackground) {
        return;
    }
    %orig;
}

%end

// ===================================================================
// 2. AD REMOVAL
// ===================================================================

// Hook UIView additions to catch ad views
static BOOL isAdView(UIView *view) {
    NSString *className = NSStringFromClass([view class]);
    
    // Google ad framework classes
    if ([className hasPrefix:@"GAD"] || 
        [className hasPrefix:@"GMA"] ||
        [className hasPrefix:@"GSD"] ||
        [className hasPrefix:@"GOOGLE"]) {
        return YES;
    }
    
    // YouTube-specific ad classes (prefix YT)
    if ([className hasPrefix:@"YT"] && 
        ([className containsString:@"Ad"] || 
         [className containsString:@"Promo"] ||
         [className containsString:@"Sponsor"])) {
        return YES;
    }
    
    // Generic ad view identifiers
    if ([className containsString:@"AdView"] ||
        [className containsString:@"BannerView"] ||
        [className containsString:@"Interstitial"]) {
        return YES;
    }
    
    return NO;
}

%hook UIView

- (void)didMoveToSuperview {
    %orig;
    if (isAdView(self)) {
        self.hidden = YES;
        self.alpha = 0;
        // Schedule removal to avoid layout issues
        dispatch_async(dispatch_get_main_queue(), ^{
            [self removeFromSuperview];
        });
    }
}

- (void)didMoveToWindow {
    %orig;
    if (isAdView(self) && self.window != nil) {
        self.hidden = YES;
        self.alpha = 0;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self removeFromSuperview];
        });
    }
}

%end

// Also hook WKWebView to inject ad-blocking CSS
%hook WKWebView

- (void)loadRequest:(NSURLRequest *)request {
    NSString *urlStr = request.URL.absoluteString;
    // Block known ad/tracking domains
    if ([urlStr containsString:@"doubleclick"] ||
        [urlStr containsString:@"googlesyndication"] ||
        [urlStr containsString:@"googleadservices"] ||
        [urlStr containsString:@"adservice"] ||
        [urlStr containsString:@"ads.youtube"] ||
        [urlStr containsString:@"youtube.com/pagead"] ||
        [urlStr containsString:@"youtube.com/ptracking"]) {
        return; // Block the request
    }
    %orig;
}

%end

// ===================================================================
// 3. DOWNLOAD INTERCEPTION
// ===================================================================

// Store downloaded URLs
static NSMutableArray *capturedStreams;

%ctor {
    capturedStreams = [[NSMutableArray alloc] init];
}

// Hook AVPlayerItem to capture stream URLs
%hook AVPlayerItem

- (instancetype)initWithURL:(NSURL *)URL {
    if (URL) {
        NSString *urlStr = URL.absoluteString;
        // Capture streaming audio URLs (YouTube Music uses googlevideo.com CDN)
        if ([urlStr containsString:@"googlevideo.com"] ||
            [urlStr containsString:@"youtube.com/videoplayback"]) {
            
            @synchronized(capturedStreams) {
                [capturedStreams addObject:@{
                    @"url": urlStr,
                    @"timestamp": [NSDate date]
                }];
            }
            
            // Log to console (viewable via device logs or FLEX)
            NSLog(@"[YTMusicEnhanced] Captured stream: %@", urlStr);
        }
    }
    return %orig;
}

%end

// Add method to retrieve captured streams
%hook UIViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    
    // Add a download button to the navigation bar on music player screens
    NSString *className = NSStringFromClass([self class]);
    if ([className containsString:@"Player"] || 
        [className containsString:@"NowPlaying"] ||
        [className containsString:@"Music"]) {
        
        // Check if we have a navigation bar
        if (self.navigationController && self.navigationItem) {
            // Only add if not already present
            if (!self.navigationItem.rightBarButtonItem || 
                ![self.navigationItem.rightBarButtonItem.title isEqualToString:@"⬇"]) {
                
                UIBarButtonItem *downloadBtn = [[UIBarButtonItem alloc] 
                    initWithTitle:@"⬇" 
                    style:UIBarButtonItemStylePlain 
                    target:self 
                    action:@selector(ytmusic_downloadCurrent)];
                self.navigationItem.rightBarButtonItem = downloadBtn;
            }
        }
    }
}

%new
- (void)ytmusic_downloadCurrent {
    NSString *latestUrl = nil;
    @synchronized(capturedStreams) {
        if (capturedStreams.count > 0) {
            latestUrl = [[capturedStreams lastObject] objectForKey:@"url"];
        }
    }
    
    if (latestUrl) {
        // Copy URL to clipboard and show alert
        [UIPasteboard generalPasteboard].string = latestUrl;
        
        UIAlertController *alert = [UIAlertController 
            alertControllerWithTitle:@"Download" 
            message:[NSString stringWithFormat:@"Stream URL copied to clipboard!\n\nOpen in Safari to download.\n\nURL length: %lu chars", 
                     (unsigned long)latestUrl.length]
            preferredStyle:UIAlertControllerStyleAlert];
        
        [alert addAction:[UIAlertAction actionWithTitle:@"Open in Safari" 
            style:UIAlertActionStyleDefault 
            handler:^(UIAlertAction *action) {
                [[UIApplication sharedApplication] openURL:[NSURL URLWithString:latestUrl] 
                    options:@{} completionHandler:nil];
        }]];
        
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" 
            style:UIAlertActionStyleCancel handler:nil]];
        
        [self presentViewController:alert animated:YES completion:nil];
    } else {
        UIAlertController *alert = [UIAlertController 
            alertControllerWithTitle:@"No Stream" 
            message:@"No audio stream captured yet.\nPlay a song first, then try again."
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" 
            style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

%end
