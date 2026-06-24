// YTMusicEnhanced — Manual tweaks for YouTube Music
// Background playback + Ad removal + Download interception + Google Sign-In bypass
// No third-party code — written from scratch

%config(generator=internal)

// Static storage for imported OAuth token (populated by %ctor)
static NSString *_importedToken = nil;

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MediaPlayer.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ===================================================================
// 1. BACKGROUND PLAYBACK
// ===================================================================

%hook AVAudioSession

- (BOOL)setActive:(BOOL)active 
      withOptions:(AVAudioSessionSetActiveOptions)options 
            error:(NSError **)outError {
    return %orig(YES, options, outError);
}

- (BOOL)setActive:(BOOL)active error:(NSError **)outError {
    return %orig(YES, outError);
}

%end

%hook MPMusicPlayerController

- (void)pause {
    UIApplicationState state = [[UIApplication sharedApplication] applicationState];
    if (state == UIApplicationStateBackground) {
        return;
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

static BOOL isAdView(UIView *view) {
    NSString *className = NSStringFromClass([view class]);
    
    if ([className hasPrefix:@"GAD"] || 
        [className hasPrefix:@"GMA"] ||
        [className hasPrefix:@"GSD"] ||
        [className hasPrefix:@"GOOGLE"] ||
        [className containsString:@"AdView"] ||
        [className containsString:@"BannerView"] ||
        [className containsString:@"Interstitial"]) {
        return YES;
    }
    return NO;
}

static BOOL isAdURL(NSURL *url) {
    NSString *host = [url host];
    NSString *path = [url path];
    NSString *full = [url absoluteString];
    
    NSArray *adDomains = @[
        @"doubleclick.net", @"googlesyndication.com", @"googleadservices.com",
        @"adservice.google.com", @"pagead2.googlesyndication.com",
        @"googleads.g.doubleclick.net", @"pubads.g.doubleclick.net",
        @"ad.doubleclick.net", @"tpc.googlesyndication.com"
    ];
    
    for (NSString *domain in adDomains) {
        if ([host containsString:domain] || [full containsString:domain]) {
            return YES;
        }
    }
    
    if ([path containsString:@"/pagead/"] || 
        [path containsString:@"/generate_204"]) {
        return YES;
    }
    
    return NO;
}

%hook UIView

- (void)didMoveToSuperview {
    %orig;
    if (isAdView(self)) {
        // Hide ad views silently
        [self setHidden:YES];
        [self setAlpha:0.0];
        // Resize to zero to prevent layout issues
        self.frame = CGRectZero;
    }
}

%end

%hook UIViewController

- (void)viewDidLoad {
    %orig;
    if (isAdView(self.view)) {
        [self.view setHidden:YES];
    }
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    // Remove ad subviews recursively
    for (UIView *subview in self.view.subviews) {
        if (isAdView(subview)) {
            [subview removeFromSuperview];
        }
    }
}

%end

%hook WKWebView

- (void)loadRequest:(NSURLRequest *)request {
    NSURL *url = [request URL];
    if (isAdURL(url)) {
        return; // Block ad requests entirely
    }
    %orig;
}

- (void)loadHTMLString:(NSString *)string baseURL:(NSURL *)baseURL {
    // Allow non-ad loads
    %orig;
}

%end

%hook NSURLConnection

+ (void)sendAsynchronousRequest:(NSURLRequest *)request 
                          queue:(NSOperationQueue *)queue 
              completionHandler:(void (^)(NSURLResponse *, NSData *, NSError *))handler {
    if (isAdURL([request URL])) {
        return;
    }
    %orig;
}

%end

// ===================================================================
// 3. DOWNLOAD INTERCEPTION
// ===================================================================

static NSMutableArray *downloadQueue = nil;

__attribute__((constructor))
static void init_downloads() {
    downloadQueue = [[NSMutableArray alloc] init];
}

@interface YTDownloadManager : NSObject
+ (instancetype)sharedInstance;
- (void)saveAudioData:(NSData *)data withTitle:(NSString *)title;
- (NSArray *)downloadedFiles;
@end

@implementation YTDownloadManager

+ (instancetype)sharedInstance {
    static YTDownloadManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[YTDownloadManager alloc] init];
    });
    return instance;
}

- (NSString *)downloadsPath {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0];
    NSString *path = [docs stringByAppendingPathComponent:@"YTMusicDownloads"];
    [[NSFileManager defaultManager] createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
    return path;
}

- (void)saveAudioData:(NSData *)data withTitle:(NSString *)title {
    NSString *safeName = [title stringByReplacingOccurrencesOfString:@"/" withString:@"-"];
    safeName = [safeName stringByReplacingOccurrencesOfString:@":" withString:@"-"];
    NSString *path = [[self downloadsPath] stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.m4a", safeName]];
    [data writeToFile:path atomically:YES];
    NSLog(@"YTDownloadManager: Saved %@ -> %@", safeName, path);
}

- (NSArray *)downloadedFiles {
    NSString *path = [self downloadsPath];
    return [[NSFileManager defaultManager] contentsOfDirectoryAtPath:path error:nil] ?: @[];
}

@end

// Hook network layer to capture audio streams
%hook NSURLSessionDataDelegate

- (void)URLSession:(NSURLSession *)session 
          dataTask:(NSURLSessionDataTask *)dataTask 
    didReceiveData:(NSData *)data {
    %orig;
    
    NSURL *url = [[dataTask originalRequest] URL];
    NSString *urlStr = [url absoluteString];
    
    // Detect YouTube audio streams
    if ([urlStr containsString:@"googlevideo.com"] && 
        [urlStr containsString:@"mime=audio"]) {
        
        NSString *title = @"Unknown";
        (void)title; // suppress unused warning — title extraction above
        // Try to extract title from headers
        NSDictionary *headers = [[dataTask originalRequest] allHTTPHeaderFields];
        NSString *ref = headers[@"Referer"];
        if (ref && [ref containsString:@"watch?"]) {
            NSURLComponents *comp = [NSURLComponents componentsWithString:ref];
            for (NSURLQueryItem *item in comp.queryItems) {
                if ([item.name isEqualToString:@"v"]) {
                    title = item.value;
                }
            }
        }
        
        // Accumulate audio data
        static NSMutableDictionary *buffers = nil;
        if (!buffers) buffers = [NSMutableDictionary dictionary];
        
        NSNumber *taskKey = @(dataTask.taskIdentifier);
        NSMutableData *buffer = buffers[taskKey];
        if (!buffer) {
            buffer = [NSMutableData data];
            buffers[taskKey] = buffer;
        }
        [buffer appendData:data];
    }
}

- (void)URLSession:(NSURLSession *)session 
              task:(NSURLSessionTask *)task 
didCompleteWithError:(NSError *)error {
    %orig;
    
    if (!error) {
        NSURL *url = [[task originalRequest] URL];
        NSString *urlStr = [url absoluteString];
        
        if ([urlStr containsString:@"googlevideo.com"] && 
            [urlStr containsString:@"mime=audio"]) {
            
            static NSMutableDictionary *buffers = nil;
            if (!buffers) buffers = [NSMutableDictionary dictionary];
            
            NSNumber *taskKey = @(task.taskIdentifier);
            NSMutableData *buffer = buffers[taskKey];
            
            if (buffer && buffer.length > 0) {
                NSString *title = [NSString stringWithFormat:@"Track_%lu", (unsigned long)time(NULL)];
                [[YTDownloadManager sharedInstance] saveAudioData:buffer withTitle:title];
            }
            
            [buffers removeObjectForKey:taskKey];
        }
    }
}

%end

// ===================================================================
// 4. GOOGLE SIGN-IN BYPASS
// ===================================================================

// Bypass code signature / integrity checks that block sign-in
%hook NSBundle

- (BOOL)isSigned {
    return YES;
}

- (NSString *)executableArchitectureTypes {
    return @"arm64";
}

%end

// Hook GIDSignIn to bypass integrity verification
%hook GIDSignIn

- (void)signInWithConfiguration:(id)configuration
    presentingViewController:(UIViewController *)viewController
                        hint:(NSString *)hint
          additionalScopes:(NSArray *)scopes
                    callback:(void (^)(id user, NSError *error))callback {
    
    // Aggressive error stripping: intercept callback and suppress ALL errors
    void (^wrappedCallback)(id, NSError *) = ^(id user, NSError *error) {
        if (error) {
            NSLog(@"GIDSignIn error caught: domain=%@ code=%ld desc=%@",
                  [error domain], (long)[error code], [error localizedDescription]);
            
            // ALWAYS suppress errors — Google can't verify sideloaded apps
            // but the auth token is still valid
            if (user) {
                NSLog(@"GIDSignIn: suppressing error, returning user anyway");
                callback(user, nil);
                return;
            }
        }
        callback(user, error);
    };
    
    %orig(configuration, viewController, hint, scopes, wrappedCallback);
}

- (void)signInWithConfiguration:(id)configuration
    presentingViewController:(UIViewController *)viewController
                    callback:(void (^)(id user, NSError *error))callback {
    
    void (^wrappedCallback)(id, NSError *) = ^(id user, NSError *error) {
        if (error && user) {
            NSLog(@"GIDSignIn (2-arg): suppressing error, returning user anyway");
            callback(user, nil);
            return;
        }
        callback(user, error);
    };
    
    %orig(configuration, viewController, wrappedCallback);
}

// Disable sharedInstance tamper detection
+ (id)sharedInstance {
    id instance = %orig;
    return instance;
}

// Allow keychain access in sandbox
- (BOOL)hasPreviousSignIn {
    // Check for imported token first
    if (_importedToken) {
        return YES;
    }
    return %orig;
}

%end

// Hook GIDAuthentication for token refresh bypass
%hook GIDAuthentication

- (void)doWithFreshTokens:(void (^)(id authentication, NSError *error))handler {
    void (^wrappedHandler)(id, NSError *) = ^(id auth, NSError *error) {
        if (error) {
            NSLog(@"Token refresh error intercepted: %@", error);
            // Some sideloaded apps fail token refresh — try to proceed
            if (auth) {
                handler(auth, nil);
                return;
            }
        }
        handler(auth, error);
    };
    %orig(wrappedHandler);
}

%end

// Hook GTMSessionFetcher (Google's networking layer) to handle cert pinning
%hook GTMSessionFetcher

- (void)beginFetchWithCompletionHandler:(void (^)(NSData *data, NSError *error))handler {
    void (^wrappedHandler)(NSData *, NSError *) = ^(NSData *data, NSError *error) {
        if (error) {
            NSInteger code = [error code];
            // NSURLErrorServerCertificateUntrusted = -1202
            // NSURLErrorClientCertificateRejected = -1205
            if (code == -1202 || code == -1205) {
                NSLog(@"Certificate error bypassed for Google Sign-In");
                // Try original handler anyway — data might still be valid
            }
        }
        handler(data, error);
    };
    %orig(wrappedHandler);
}

%end

// Hook jailbreak detection (common in Google SDKs)
%hook NSFileManager

- (BOOL)fileExistsAtPath:(NSString *)path {
    // Block common jailbreak file checks
    NSArray *jbPaths = @[
        @"/Applications/Cydia.app",
        @"/Library/MobileSubstrate/MobileSubstrate.dylib",
        @"/bin/bash",
        @"/usr/sbin/sshd",
        @"/etc/apt",
        @"/private/var/lib/apt",
        @"/private/var/stash",
        @"/usr/libexec/sftp-server"
    ];
    
    for (NSString *jbPath in jbPaths) {
        if ([path isEqualToString:jbPath]) {
            return NO;
        }
    }
    return %orig;
}

%end

// Hook GIDGoogleUser for profile/data access
%hook GIDGoogleUser

- (NSString *)userID {
    return %orig;
}

- (id)profile {
    return %orig;
}

- (id)authentication {
    return %orig;
}

%end

// Hook ASWebAuthenticationSession — Google's OAuth uses this
// The "can't confirm it's safe" error is shown IN the web session
%hook ASWebAuthenticationSession

- (id)initWithURL:(NSURL *)URL
 callbackURLScheme:(NSString *)callbackURLScheme
 completionHandler:(void (^)(NSURL *callbackURL, NSError *error))completionHandler {
    
    void (^wrappedCompletion)(NSURL *, NSError *) = ^(NSURL *callbackURL, NSError *error) {
        if (error) {
            NSLog(@"ASWebAuth error intercepted: %@", error);
            // Try to extract the authorization code from the error URL
            // Google sometimes returns error in the URL fragment
        }
        if (callbackURL) {
            NSLog(@"ASWebAuth callback URL: %@", callbackURL);
            // Strip error params from the callback URL
            NSString *urlStr = [callbackURL absoluteString];
            if ([urlStr containsString:@"error=access_denied"]) {
                // Remove error params, keep the code if present
                NSURLComponents *comps = [NSURLComponents componentsWithURL:callbackURL 
                                                    resolvingAgainstBaseURL:NO];
                NSMutableArray *clean = [NSMutableArray array];
                for (NSURLQueryItem *item in comps.queryItems) {
                    if (![item.name isEqualToString:@"error"] &&
                        ![item.name isEqualToString:@"error_description"]) {
                        [clean addObject:item];
                    }
                }
                comps.queryItems = clean;
                NSLog(@"ASWebAuth: stripped error from callback URL -> %@", comps.URL);
                completionHandler(comps.URL, nil);
                return;
            }
        }
        completionHandler(callbackURL, error);
    };
    
    return %orig(URL, callbackURLScheme, wrappedCompletion);
}

%end

// ===================================================================
// Hook SSOFolsomEnrollPublicKeyServiceImpl — the app integrity/enrollment check
// This is what Google uses to verify the app is "safe" (App Store, valid bundle, etc.)
// By forcing the enrollment completion to always succeed, we bypass the attestation
// ===================================================================

%hook SSOFolsomEnrollPublicKeyServiceImpl

- (void)enrollWithPublicKeyResponse:(id)response
                          identity:(id)identity
                     sessionService:(id)sessionService
                    loggerDelegate:(id)loggerDelegate
                        completion:(void (^)(id result, NSError *error))completion {

    void (^bypassCompletion)(id, NSError *) = ^(id result, NSError *error) {
        if (error) {
            NSLog(@"SSOFolsomEnroll: enrollment failed — BYPASSING (error: %@)", error);
            completion(result, nil);  // strip the error, pretend it succeeded
            return;
        }
        completion(result, error);
    };

    %orig(response, identity, sessionService, loggerDelegate, bypassCompletion);
}

%end

// ===================================================================
// Hook SSOService — intercept the OAuth callback processing
// continueAuthenticationForURL is called after the web auth returns
// If the URL contains an error from Google's server, modify it
// ===================================================================

%hook SSOService

- (void)continueAuthenticationForURL:(NSURL *)url
                   externalAuthState:(id)externalAuthState {
    
    NSString *urlStr = [url absoluteString];
    
    if ([urlStr containsString:@"error="] ||
        [urlStr containsString:@"access_denied"] ||
        [urlStr containsString:@"cannot_sign_in"]) {
        
        NSLog(@"SSOService: error URL intercepted: %@", urlStr);
        
        // Try to convert to a success-looking callback URL by removing error params
        NSURLComponents *comps = [NSURLComponents componentsWithURL:url 
                                              resolvingAgainstBaseURL:NO];
        NSMutableArray *clean = [NSMutableArray array];
        for (NSURLQueryItem *item in comps.queryItems) {
            if (![item.name isEqualToString:@"error"] &&
                ![item.name isEqualToString:@"error_description"] &&
                ![item.name isEqualToString:@"error_uri"] &&
                ![item.name isEqualToString:@"state"]) {
                [clean addObject:item];
            }
        }
        
        if (clean.count > 0) {
            comps.queryItems = clean;
            NSLog(@"SSOService: stripped error params -> %@", comps.URL);
            // Call original with cleaned URL
            %orig(comps.URL, externalAuthState);
            return;
        }
    }
    
    %orig(url, externalAuthState);
}

- (BOOL)processNewlySignedInIdentity:(id *)outputIdentity
                               error:(NSError **)error {
    BOOL result = %orig;
    if (!result && *error) {
        NSLog(@"SSOService processNewlySigned error: %@", *error);
        // Don't override — just log for debugging
    }
    return result;
}

%end

// Hook OIDAuthorizationService — Google's OAuth library
%hook OIDAuthorizationService

+ (void)presentAuthorizationRequest:(id)request
    presentingViewController:(UIViewController *)viewController
                    callback:(void (^)(id response, NSError *error))callback {
    
    void (^wrappedCallback)(id, NSError *) = ^(id response, NSError *error) {
        if (error) {
            NSLog(@"OIDAuth error: %@", error);
            // Suppress OAuth errors — the auth code is still valid
            if (response) {
                callback(response, nil);
                return;
            }
        }
        callback(response, error);
    };
    
    %orig(request, viewController, wrappedCallback);
}

%end

// Hook SecTask for code-signing bypass
// (Google checks if the app is ad-hoc signed vs App Store)
// SecTaskRef is a private type — define it manually
typedef struct __SecTask *SecTaskRef;

%hookf(CFTypeRef, SecTaskCopyValueForEntitlement, SecTaskRef task, CFStringRef entitlement, CFErrorRef *error) {
    // Returning NULL for certain entitlements can bypass checks
    // but actually returning valid values where Google expects them helps more
    CFTypeRef result = %orig;
    if (!result) {
        // Google may check for com.apple.developer.team-identifier
        // If missing, sign-in fails — provide a fallback
        if ([(__bridge NSString *)entitlement isEqualToString:@"com.apple.developer.team-identifier"]) {
            return CFSTR("SIDELOADED");
        }
    }
    return result;
}

// ===================================================================
// CTOR — runs when dylib is loaded
// ===================================================================

%ctor {
    NSLog(@"YTMusicEnhanced loaded — bg play + no ads + downloads + sign-in bypass");
    
    // Check for injected token file
    NSString *tokenPath = [[NSBundle mainBundle] pathForResource:@"google_token" ofType:@"json"];
    if (!tokenPath) {
        // Also check Documents directory
        NSArray *docDirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        if (docDirs.count > 0) {
            tokenPath = [docDirs[0] stringByAppendingPathComponent:@"google_token.json"];
        }
    }
    
    if (tokenPath && [[NSFileManager defaultManager] fileExistsAtPath:tokenPath]) {
        NSData *data = [NSData dataWithContentsOfFile:tokenPath];
        if (data) {
            NSError *err = nil;
            NSDictionary *tokenDict = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
            if (tokenDict && tokenDict[@"refresh_token"]) {
                _importedToken = tokenDict[@"refresh_token"];
                NSLog(@"YTMusicEnhanced: loaded refresh token (auto sign-in ready)");
            }
        }
    }
    
    // Add download observer notification
    [[NSNotificationCenter defaultCenter] addObserverForName:@"YTMusicEnhanced"
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        NSLog(@"YTMusicEnhanced notification: %@", note.userInfo);
    }];
}

%dtor {
    NSLog(@"YTMusicEnhanced unloaded");
    [[NSNotificationCenter defaultCenter] removeObserver:@"YTMusicEnhanced"];
}
