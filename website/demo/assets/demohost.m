/* Keeps marketing capture behavior inside the isolated demo process:
 * - swizzles the hostname so real machine details never appear;
 * - accepts exact-PID distributed controls for documented UI states; and
 * - captures its own composited window without Screen Recording access.
 *
 * Built by stage.sh; loaded via DYLD_INSERT_LIBRARIES in run.sh (the app
 * copy is re-signed without the hardened runtime so the insert applies). */
#import <AppKit/AppKit.h>
#import <ImageIO/ImageIO.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <unistd.h>

static NSString *const DemoCaptureNotification =
    @"com.ghosthub.demo.capture";
static NSString *const DemoInputNotification =
    @"com.ghosthub.demo.input";

@interface DemoController : NSObject
@end

static NSWindow *DemoRootWindow(void);

static NSString *DemoHostName(id self, SEL _cmd) {
  return @"studio.local";
}

static void DemoSendKey(NSString *characters, unsigned short keyCode,
                        NSEventModifierFlags modifiers) {
  NSWindow *window = [NSApp keyWindow] ?: [NSApp mainWindow];
  if (window == nil) return;
  NSTimeInterval now = [NSProcessInfo processInfo].systemUptime;
  NSEvent *down = [NSEvent keyEventWithType:NSEventTypeKeyDown
                                   location:NSZeroPoint
                              modifierFlags:modifiers
                                  timestamp:now
                               windowNumber:window.windowNumber
                                    context:nil
                                 characters:characters
                charactersIgnoringModifiers:characters
                                  isARepeat:NO
                                    keyCode:keyCode];
  NSEvent *up = [NSEvent keyEventWithType:NSEventTypeKeyUp
                                 location:NSZeroPoint
                            modifierFlags:modifiers
                                timestamp:now
                             windowNumber:window.windowNumber
                                  context:nil
                               characters:characters
              charactersIgnoringModifiers:characters
                                isARepeat:NO
                                  keyCode:keyCode];
  [NSApp sendEvent:down];
  [NSApp sendEvent:up];
}

static void DemoClick(NSPoint point) {
  NSWindow *window = DemoRootWindow();
  if (window == nil) return;
  NSTimeInterval now = [NSProcessInfo processInfo].systemUptime;
  NSEvent *down = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown
                                     location:point
                                modifierFlags:0
                                    timestamp:now
                                 windowNumber:window.windowNumber
                                      context:nil
                                  eventNumber:0
                                   clickCount:1
                                     pressure:1];
  NSEvent *up = [NSEvent mouseEventWithType:NSEventTypeLeftMouseUp
                                   location:point
                              modifierFlags:0
                                  timestamp:now
                               windowNumber:window.windowNumber
                                    context:nil
                                eventNumber:0
                                 clickCount:1
                                   pressure:0];
  [NSApp sendEvent:down];
  [NSApp sendEvent:up];
}

static void DemoInsertText(NSString *text) {
  id responder = [NSApp keyWindow].firstResponder;
  if ([responder respondsToSelector:
          @selector(insertText:replacementRange:)]) {
    [responder insertText:text
         replacementRange:NSMakeRange(NSNotFound, 0)];
  }
}

static BOOL DemoPressLabel(id element, NSString *label, NSUInteger depth) {
  if (element == nil || depth > 20) return NO;
  if ([[element accessibilityLabel] isEqualToString:label]) {
    return [element accessibilityPerformPress];
  }
  for (id child in [element accessibilityChildren] ?: @[]) {
    if (DemoPressLabel(child, label, depth + 1)) return YES;
  }
  return NO;
}

static NSWindow *DemoRootWindow(void) {
  NSWindow *window = [NSApp keyWindow] ?: [NSApp mainWindow];
  while (window.sheetParent != nil) {
    window = window.sheetParent;
  }
  return window;
}

static CGRect DemoWindowBounds(CGWindowID windowID) {
  CFArrayRef info = CGWindowListCopyWindowInfo(
      kCGWindowListOptionIncludingWindow, windowID);
  CGRect bounds = CGRectNull;
  if (info != NULL && CFArrayGetCount(info) > 0) {
    CFDictionaryRef entry = CFArrayGetValueAtIndex(info, 0);
    CFDictionaryRef rawBounds =
        CFDictionaryGetValue(entry, kCGWindowBounds);
    if (rawBounds != NULL) {
      CGRectMakeWithDictionaryRepresentation(rawBounds, &bounds);
    }
  }
  if (info != NULL) CFRelease(info);
  return bounds;
}

static void DemoCapture(NSString *path) {
  NSWindow *window = DemoRootWindow();
  if (window == nil) return;
  CGRect bounds = DemoWindowBounds((CGWindowID)window.windowNumber);
  if (CGRectIsNull(bounds)) return;

  /* The macOS 26 SDK makes the legacy function unavailable to new source,
   * but the runtime retains it for binary compatibility. Resolving it here
   * lets the injected process capture only its existing on-screen demo
   * window without ScreenCaptureKit's system-wide recording permission. */
  typedef CGImageRef (*CreateWindowImage)(
      CGRect, CGWindowListOption, CGWindowID, CGWindowImageOption);
  CreateWindowImage createImage =
      (CreateWindowImage)dlsym(RTLD_DEFAULT, "CGWindowListCreateImage");
  if (createImage == NULL) return;
  CGImageRef image = createImage(
      bounds, kCGWindowListOptionOnScreenOnly, kCGNullWindowID,
      kCGWindowImageBoundsIgnoreFraming | kCGWindowImageNominalResolution);
  if (image == NULL) return;

  NSString *temporary = [path stringByAppendingString:@".tmp"];
  NSURL *url = [NSURL fileURLWithPath:temporary];
  CGImageDestinationRef destination = CGImageDestinationCreateWithURL(
      (__bridge CFURLRef)url, CFSTR("public.png"), 1, NULL);
  if (destination != NULL) {
    CGImageDestinationAddImage(destination, image, NULL);
    if (CGImageDestinationFinalize(destination)) {
      NSFileManager *files = [NSFileManager defaultManager];
      [files removeItemAtPath:path error:nil];
      [files moveItemAtPath:temporary toPath:path error:nil];
    }
    CFRelease(destination);
  }
  CGImageRelease(image);
}

@implementation DemoController

- (void)capture:(NSNotification *)notification {
  NSString *path = notification.userInfo[@"path"];
  if (path.length == 0) return;
  dispatch_async(dispatch_get_main_queue(), ^{
    DemoCapture(path);
  });
}

- (void)input:(NSNotification *)notification {
  NSString *action = notification.userInfo[@"action"];
  if ([action isEqualToString:@"palette"]) {
    NSString *query = notification.userInfo[@"text"] ?: @"";
    BOOL submit =
        [notification.userInfo[@"submit"] isEqualToString:@"true"];
    [[NSNotificationCenter defaultCenter]
        postNotificationName:@"ghosthubCommandPalette"
                      object:nil];
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC),
        dispatch_get_main_queue(), ^{
          DemoInsertText(query);
          if (submit) {
            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC),
                dispatch_get_main_queue(), ^{
                  DemoSendKey(@"\r", 36, 0);
                });
          }
        });
  } else if ([action isEqualToString:@"text"]) {
    DemoInsertText(notification.userInfo[@"text"] ?: @"");
  } else if ([action isEqualToString:@"escape"]) {
    DemoSendKey(@"\x1b", 53, 0);
  } else if ([action isEqualToString:@"new-window"]) {
    DemoSendKey(@"n", 45,
                NSEventModifierFlagCommand | NSEventModifierFlagOption);
  } else if ([action isEqualToString:@"sidebar"]) {
    DemoSendKey(@"b", 11, NSEventModifierFlagCommand);
  } else if ([action isEqualToString:@"frame"]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    [NSApp activateIgnoringOtherApps:YES];
#pragma clang diagnostic pop
    NSRect frame = NSMakeRect(160, 25, 1600, 1000);
    NSArray<NSString *> *parts =
        [notification.userInfo[@"text"] componentsSeparatedByString:@","];
    if (parts.count == 4) {
      frame = NSMakeRect(parts[0].doubleValue, parts[1].doubleValue,
                         parts[2].doubleValue, parts[3].doubleValue);
    }
    [DemoRootWindow() setFrame:frame display:YES];
  } else if ([action isEqualToString:@"click"]) {
    NSArray<NSString *> *parts =
        [notification.userInfo[@"text"] componentsSeparatedByString:@","];
    if (parts.count == 2) {
      DemoClick(NSMakePoint(parts[0].doubleValue, parts[1].doubleValue));
    }
  } else if ([action isEqualToString:@"press"]) {
    DemoPressLabel(DemoRootWindow().contentView,
                   notification.userInfo[@"text"], 0);
  }
}

@end

static DemoController *controller;

__attribute__((constructor)) static void demo_controller_init(void) {
  /* macOS 26 Foundation backs NSProcessInfo with _NSSwiftProcessInfo, which
   * overrides hostName; swizzle the concrete class of the shared instance. */
  Class cls = object_getClass([NSProcessInfo processInfo]);
  Method m = class_getInstanceMethod(cls, @selector(hostName));
  if (m != NULL) {
    method_setImplementation(m, (IMP)DemoHostName);
  }

  dispatch_async(dispatch_get_main_queue(), ^{
    controller = [DemoController new];
    NSString *target =
        [NSString stringWithFormat:@"%d", [NSProcessInfo processInfo].processIdentifier];
    NSDistributedNotificationCenter *notifications =
        [NSDistributedNotificationCenter defaultCenter];
    [notifications addObserver:controller
                      selector:@selector(capture:)
                          name:DemoCaptureNotification
                        object:target];
    [notifications addObserver:controller
                      selector:@selector(input:)
                          name:DemoInputNotification
                        object:target];
  });
}
