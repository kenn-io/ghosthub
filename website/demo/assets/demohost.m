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
static NSString *const DemoInputAcknowledgement =
    @"com.ghosthub.demo.input.ack";

@interface DemoController : NSObject
@end

static NSWindow *DemoRootWindow(void);

static NSString *DemoHostName(id self, SEL _cmd) {
  return @"studio.local";
}

static BOOL DemoSendKey(NSString *characters, unsigned short keyCode,
                        NSEventModifierFlags modifiers) {
  NSWindow *window = [NSApp keyWindow] ?: [NSApp mainWindow];
  if (window == nil) return NO;
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
  return YES;
}

static NSMenuItem *DemoFindMenuItem(NSMenu *menu, NSString *title) {
  for (NSMenuItem *item in menu.itemArray) {
    if ([item.title isEqualToString:title]) return item;
    NSMenuItem *match = DemoFindMenuItem(item.submenu, title);
    if (match != nil) return match;
  }
  return nil;
}

static NSMenuItem *DemoMenuItemForShortcut(
    NSString *title, NSString *characters,
    NSEventModifierFlags modifiers) {
  NSMenuItem *item = DemoFindMenuItem(NSApp.mainMenu, title);
  NSEventModifierFlags mask =
      item.keyEquivalentModifierMask &
      NSEventModifierFlagDeviceIndependentFlagsMask;
  return [item.keyEquivalent isEqualToString:characters] &&
                 mask == modifiers
             ? item
             : nil;
}

static BOOL DemoClick(NSPoint point) {
  NSWindow *window = DemoRootWindow();
  if (window == nil) return NO;
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
  return YES;
}

static BOOL DemoInsertText(NSString *text) {
  id responder = [NSApp keyWindow].firstResponder;
  if (![responder respondsToSelector:
          @selector(insertText:replacementRange:)]) return NO;
  [responder insertText:text
       replacementRange:NSMakeRange(NSNotFound, 0)];
  return YES;
}

// SwiftUI's accessibility tree can contain private AppKit nodes that advertise
// NSObject ancestry but throw for standard accessibility selectors. Keep those
// implementation details from escaping the demo controller as an app crash.
static NSString *DemoAccessibilityLabel(id element) {
  @try {
    return [element accessibilityLabel];
  } @catch (NSException *exception) {
    (void)exception;
    return nil;
  }
}

static id DemoAccessibilityValue(id element) {
  @try {
    return [element accessibilityValue];
  } @catch (NSException *exception) {
    (void)exception;
    return nil;
  }
}

static NSArray *DemoAccessibilityChildren(id element) {
  @try {
    id children = [element accessibilityChildren];
    return [children isKindOfClass:[NSArray class]] ? children : @[];
  } @catch (NSException *exception) {
    (void)exception;
    return @[];
  }
}

static BOOL DemoAccessibilityPress(id element) {
  @try {
    return [element accessibilityPerformPress];
  } @catch (NSException *exception) {
    (void)exception;
    return NO;
  }
}

static BOOL DemoPressLabelWalk(id element, NSString *label,
                               NSUInteger depth, NSUInteger *budget) {
  if (element == nil || depth > 20 || *budget == 0) return NO;
  *budget -= 1;
  if ([DemoAccessibilityLabel(element) isEqualToString:label]) {
    return DemoAccessibilityPress(element);
  }
  for (id child in DemoAccessibilityChildren(element)) {
    if (DemoPressLabelWalk(
            child, label, depth + 1, budget)) return YES;
  }
  return NO;
}

static BOOL DemoPressLabel(id element, NSString *label, NSUInteger depth) {
  NSUInteger budget = 4096;
  return DemoPressLabelWalk(element, label, depth, &budget);
}

static BOOL DemoContainsTextWalk(id element, NSString *text,
                                 NSUInteger depth, NSUInteger *budget) {
  if (element == nil || depth > 20 || *budget == 0) return NO;
  *budget -= 1;
  if ([DemoAccessibilityLabel(element) isEqualToString:text] ||
      [[DemoAccessibilityValue(element) description]
          isEqualToString:text]) {
    return YES;
  }
  for (id child in DemoAccessibilityChildren(element)) {
    if (DemoContainsTextWalk(
            child, text, depth + 1, budget)) return YES;
  }
  return NO;
}

static BOOL DemoContainsText(id element, NSString *text,
                             NSUInteger depth) {
  NSUInteger budget = 4096;
  return DemoContainsTextWalk(element, text, depth, &budget);
}

static BOOL DemoPalettePostcondition(NSString *kind,
                                     NSWindow *paletteSheet) {
  NSWindow *currentSheet = DemoRootWindow().attachedSheet;
  BOOL paletteOpen = currentSheet == paletteSheet;
  if ([kind isEqualToString:@"palette-open"]) {
    return paletteOpen;
  }
  if ([kind isEqualToString:@"palette-closed"]) {
    return !paletteOpen;
  }
  if ([kind isEqualToString:@"palette-replaced"]) {
    return !paletteOpen && currentSheet != nil;
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

static CFArrayRef DemoOwnedWindowIDs(CGRect captureBounds) {
  CFArrayRef info = CGWindowListCopyWindowInfo(
      kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
  CFMutableArrayRef windowIDs = CFArrayCreateMutable(
      kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
  if (info == NULL) return windowIDs;

  pid_t demoPID = getpid();
  for (CFIndex index = 0; index < CFArrayGetCount(info); index++) {
    CFDictionaryRef entry = CFArrayGetValueAtIndex(info, index);
    CFNumberRef owner = CFDictionaryGetValue(entry, kCGWindowOwnerPID);
    int ownerPID = 0;
    if (owner == NULL ||
        !CFNumberGetValue(owner, kCFNumberIntType, &ownerPID) ||
        ownerPID != demoPID) {
      continue;
    }

    CFDictionaryRef rawBounds =
        CFDictionaryGetValue(entry, kCGWindowBounds);
    CGRect windowBounds = CGRectNull;
    if (rawBounds == NULL ||
        !CGRectMakeWithDictionaryRepresentation(rawBounds, &windowBounds) ||
        CGRectIsNull(CGRectIntersection(captureBounds, windowBounds))) {
      continue;
    }

    CFNumberRef windowID =
        CFDictionaryGetValue(entry, kCGWindowNumber);
    if (windowID != NULL) CFArrayAppendValue(windowIDs, windowID);
  }
  CFRelease(info);
  return windowIDs;
}

typedef CGImageRef (*DemoCreateWindowImage)(
    CGRect, CGWindowListOption, CGWindowID, CGWindowImageOption);

static CGImageRef DemoCreateOwnedWindowComposite(
    CGRect captureBounds, CFArrayRef windowIDs,
    DemoCreateWindowImage createImage) {
  size_t width = (size_t)ceil(CGRectGetWidth(captureBounds));
  size_t height = (size_t)ceil(CGRectGetHeight(captureBounds));
  CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
  CGContextRef context = CGBitmapContextCreate(
      NULL, width, height, 8, width * 4, colorSpace,
      (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
  CGColorSpaceRelease(colorSpace);
  if (context == NULL) return NULL;

  CGWindowImageOption imageOptions =
      kCGWindowImageBoundsIgnoreFraming | kCGWindowImageNominalResolution;
  for (CFIndex index = CFArrayGetCount(windowIDs); index > 0; index--) {
    CFNumberRef rawWindowID = CFArrayGetValueAtIndex(windowIDs, index - 1);
    CGWindowID windowID = kCGNullWindowID;
    if (!CFNumberGetValue(
            rawWindowID, kCGWindowIDCFNumberType, &windowID)) {
      continue;
    }
    CGRect windowBounds = DemoWindowBounds(windowID);
    if (CGRectIsNull(windowBounds)) continue;
    CGImageRef windowImage = createImage(
        windowBounds, kCGWindowListOptionIncludingWindow, windowID,
        imageOptions);
    if (windowImage == NULL) continue;

    CGRect destination = CGRectMake(
        CGRectGetMinX(windowBounds) - CGRectGetMinX(captureBounds),
        CGRectGetHeight(captureBounds) -
            (CGRectGetMinY(windowBounds) - CGRectGetMinY(captureBounds)) -
            CGRectGetHeight(windowBounds),
        CGRectGetWidth(windowBounds), CGRectGetHeight(windowBounds));
    CGContextDrawImage(context, destination, windowImage);
    CGImageRelease(windowImage);
  }

  CGImageRef composite = CGBitmapContextCreateImage(context);
  CGContextRelease(context);
  return composite;
}

static BOOL DemoCaptureWindow(NSWindow *window, NSString *path,
                              BOOL exactWindow) {
  if (window == nil) return NO;
  CGRect bounds = DemoWindowBounds((CGWindowID)window.windowNumber);
  if (CGRectIsNull(bounds)) return NO;

  /* The macOS 26 SDK makes the legacy function unavailable to new source,
   * but the runtime retains it for binary compatibility. Resolving it here
   * lets the injected process capture only its existing on-screen demo
   * window without ScreenCaptureKit's system-wide recording permission. */
  DemoCreateWindowImage createImage =
      (DemoCreateWindowImage)dlsym(
          RTLD_DEFAULT, "CGWindowListCreateImage");
  if (createImage == NULL) return NO;
  CGImageRef image = NULL;
  CGWindowImageOption imageOptions =
      kCGWindowImageBoundsIgnoreFraming | kCGWindowImageNominalResolution;
  if (exactWindow) {
    image = createImage(
        bounds, kCGWindowListOptionIncludingWindow,
        (CGWindowID)window.windowNumber, imageOptions);
  } else {
    CFArrayRef windowIDs = DemoOwnedWindowIDs(bounds);
    if (CFArrayGetCount(windowIDs) > 0) {
      image = DemoCreateOwnedWindowComposite(
          bounds, windowIDs, createImage);
    }
    CFRelease(windowIDs);
  }
  if (image == NULL) return NO;

  BOOL wrote = NO;
  NSString *temporary = [path stringByAppendingString:@".tmp"];
  NSURL *url = [NSURL fileURLWithPath:temporary];
  CGImageDestinationRef destination = CGImageDestinationCreateWithURL(
      (__bridge CFURLRef)url, CFSTR("public.png"), 1, NULL);
  if (destination != NULL) {
    CGImageDestinationAddImage(destination, image, NULL);
    if (CGImageDestinationFinalize(destination)) {
      NSFileManager *files = [NSFileManager defaultManager];
      [files removeItemAtPath:path error:nil];
      wrote = [files moveItemAtPath:temporary toPath:path error:nil];
    }
    CFRelease(destination);
  }
  CGImageRelease(image);
  return wrote;
}

static NSArray<NSWindow *> *DemoWorkspaceWindows(void) {
  NSMutableArray<NSWindow *> *windows = [NSMutableArray array];
  for (NSWindow *window in NSApp.windows) {
    if (!window.isVisible || window.isSheet || window.sheetParent != nil ||
        window.parentWindow != nil || window.level != NSNormalWindowLevel ||
        window.contentView == nil) {
      continue;
    }
    [windows addObject:window];
  }
  [windows sortUsingComparator:^NSComparisonResult(NSWindow *left,
                                                    NSWindow *right) {
    if (left.windowNumber < right.windowNumber) return NSOrderedAscending;
    if (left.windowNumber > right.windowNumber) return NSOrderedDescending;
    return NSOrderedSame;
  }];
  if (windows.count > 6) {
    return [windows subarrayWithRange:NSMakeRange(0, 6)];
  }
  return windows;
}

static void DemoArrangeMatrix(NSArray<NSWindow *> *windows) {
  if (windows.count != 6) return;
  NSRect screen = NSScreen.mainScreen.visibleFrame;
  CGFloat gap = 6;
  CGFloat width = floor((screen.size.width - (2 * gap)) / 3);
  CGFloat height = floor((screen.size.height - gap) / 2);
  for (NSUInteger index = 0; index < windows.count; index++) {
    NSUInteger column = index % 3;
    NSUInteger row = index / 3;
    CGFloat x = screen.origin.x + column * (width + gap);
    CGFloat y = screen.origin.y + (1 - row) * (height + gap);
    NSWindow *window = windows[index];
    [window setFrame:NSMakeRect(x, y, width, height) display:YES];
    [window orderFront:nil];
  }
}

static void DemoCapture(NSString *path, BOOL matrix) {
  if (!matrix) {
    DemoCaptureWindow(DemoRootWindow(), path, NO);
    return;
  }

  NSArray<NSWindow *> *windows = DemoWorkspaceWindows();
  if (windows.count != 6) return;
  DemoArrangeMatrix(windows);
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, 1000 * NSEC_PER_MSEC),
      dispatch_get_main_queue(), ^{
        for (NSUInteger index = 0; index < windows.count; index++) {
          NSString *windowPath = index == 0
              ? path
              : [path stringByAppendingFormat:@".%lu",
                                                 (unsigned long)index];
          if (!DemoCaptureWindow(windows[index], windowPath, YES)) return;
        }
      });
}

@implementation DemoController

- (void)acknowledge:(NSString *)requestID
            success:(BOOL)success
            message:(NSString *)message {
  NSString *target =
      [NSString stringWithFormat:@"%d",
                                 [NSProcessInfo processInfo].processIdentifier];
  [[NSDistributedNotificationCenter defaultCenter]
      postNotificationName:DemoInputAcknowledgement
                    object:target
                  userInfo:@{
                    @"requestID": requestID,
                    @"success": @(success),
                    @"message": message ?: @"",
                  }];
}

- (void)capture:(NSNotification *)notification {
  NSString *path = notification.userInfo[@"path"];
  BOOL matrix = [notification.userInfo[@"mode"] isEqualToString:@"matrix"];
  if (path.length == 0) return;
  dispatch_async(dispatch_get_main_queue(), ^{
    DemoCapture(path, matrix);
  });
}

- (void)input:(NSNotification *)notification {
  NSString *action = notification.userInfo[@"action"];
  NSString *requestID = notification.userInfo[@"requestID"];
  NSString *text = notification.userInfo[@"text"] ?: @"";
  NSString *expectKind = notification.userInfo[@"expectKind"] ?: @"";
  BOOL submit =
      [notification.userInfo[@"submit"] isEqualToString:@"true"];
  if (action.length == 0 || requestID.length == 0) return;

  dispatch_async(dispatch_get_main_queue(), ^{
    if ([action isEqualToString:@"palette"]) {
      [[NSNotificationCenter defaultCenter]
          postNotificationName:@"ghosthubCommandPalette"
                        object:nil];
      dispatch_after(
          dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC),
          dispatch_get_main_queue(), ^{
            if (!DemoInsertText(text)) {
              [self acknowledge:requestID
                        success:NO
                        message:@"command palette did not accept text"];
              return;
            }
            NSWindow *paletteSheet = DemoRootWindow().attachedSheet;
            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC),
                dispatch_get_main_queue(), ^{
                  if (!submit) {
                    BOOL matched = DemoPalettePostcondition(
                        expectKind, paletteSheet);
                    [self acknowledge:requestID
                              success:matched
                              message:matched
                                  ? @"command palette matched requested state"
                                  : @"command palette did not match requested state"];
                    return;
                  }
                  dispatch_after(
                      dispatch_time(
                          DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC),
                      dispatch_get_main_queue(), ^{
                        if (!DemoSendKey(@"\r", 36, 0)) {
                          [self acknowledge:requestID
                                    success:NO
                                    message:@"command palette lost its window"];
                          return;
                        }
                        dispatch_after(
                            dispatch_time(
                                DISPATCH_TIME_NOW, 750 * NSEC_PER_MSEC),
                            dispatch_get_main_queue(), ^{
                              BOOL matched = DemoPalettePostcondition(
                                  expectKind, paletteSheet);
                              [self acknowledge:requestID
                                        success:matched
                                        message:matched
                                            ? @"command reached requested state"
                                            : @"command did not reach requested state"];
                            });
                      });
                });
          });
    } else if ([action isEqualToString:@"text"]) {
      BOOL inserted = DemoInsertText(text);
      [self acknowledge:requestID
                success:inserted
                message:inserted ? @"text inserted"
                                 : @"focused control did not accept text"];
    } else if ([action isEqualToString:@"escape"]) {
      BOOL sent = DemoSendKey(@"\x1b", 53, 0);
      [self acknowledge:requestID
                success:sent
                message:sent ? @"escape sent" : @"no active window"];
    } else if ([action isEqualToString:@"new-window"]) {
      NSUInteger windowCount = DemoWorkspaceWindows().count;
      NSMenuItem *newWindow = DemoMenuItemForShortcut(
          @"New Window", @"n", NSEventModifierFlagCommand);
      if (newWindow == nil) {
        [self acknowledge:requestID
                  success:NO
                  message:@"New Window is not bound to Cmd-N"];
        return;
      }
      dispatch_async(dispatch_get_main_queue(), ^{
        if (![NSApp sendAction:newWindow.action
                            to:newWindow.target
                          from:newWindow]) {
          [self acknowledge:requestID
                    success:NO
                    message:@"New Window menu action was not handled"];
          return;
        }
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
            dispatch_get_main_queue(), ^{
              BOOL created =
                  DemoWorkspaceWindows().count > windowCount;
              NSString *message = created
                  ? @"workspace window created"
                  : [NSString stringWithFormat:
                      @"workspace window did not appear "
                       "(workspace=%lu, app=%lu, tabs=%lu)",
                      (unsigned long)DemoWorkspaceWindows().count,
                      (unsigned long)NSApp.windows.count,
                      (unsigned long)(
                          DemoRootWindow().tabbedWindows.count)];
              [self acknowledge:requestID
                        success:created
                        message:message];
            });
      });
    } else if ([action isEqualToString:@"sidebar"]) {
      NSView *content = DemoRootWindow().contentView;
      BOOL wasVisible = DemoContainsText(content, @"Workspaces", 0);
      BOOL sent =
          DemoSendKey(@"b", 11, NSEventModifierFlagCommand);
      if (!sent) {
        [self acknowledge:requestID
                  success:NO
                  message:@"no active window"];
        return;
      }
      dispatch_after(
          dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC),
          dispatch_get_main_queue(), ^{
            BOOL isVisible =
                DemoContainsText(content, @"Workspaces", 0);
            BOOL toggled = isVisible != wasVisible;
            [self acknowledge:requestID
                      success:toggled
                      message:toggled ? @"sidebar visibility changed"
                                      : @"sidebar visibility did not change"];
          });
    } else if ([action isEqualToString:@"frame"]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
      [NSApp activateIgnoringOtherApps:YES];
#pragma clang diagnostic pop
      NSRect frame = NSMakeRect(160, 25, 1600, 1000);
      NSArray<NSString *> *parts =
          [text componentsSeparatedByString:@","];
      if (text.length > 0 && parts.count != 4) {
        [self acknowledge:requestID
                  success:NO
                  message:@"frame requires x,y,width,height"];
        return;
      }
      if (parts.count == 4) {
        frame = NSMakeRect(parts[0].doubleValue, parts[1].doubleValue,
                           parts[2].doubleValue, parts[3].doubleValue);
      }
      NSWindow *window = DemoRootWindow();
      if (window != nil) [window setFrame:frame display:YES];
      [self acknowledge:requestID
                success:window != nil
                message:window != nil ? @"window framed"
                                      : @"no workspace window"];
    } else if ([action isEqualToString:@"click"]) {
      NSArray<NSString *> *parts =
          [text componentsSeparatedByString:@","];
      BOOL clicked =
          parts.count == 2 &&
          DemoClick(NSMakePoint(parts[0].doubleValue,
                                parts[1].doubleValue));
      [self acknowledge:requestID
                success:clicked
                message:clicked ? @"click sent"
                                : @"click requires x,y and a workspace window"];
    } else if ([action isEqualToString:@"press"]) {
      BOOL pressed =
          text.length > 0 &&
          DemoPressLabel(DemoRootWindow().contentView, text, 0);
      [self acknowledge:requestID
                success:pressed
                message:pressed ? @"accessibility control pressed"
                                : @"accessibility label not found"];
    } else {
      [self acknowledge:requestID
                success:NO
                message:@"unknown demo action"];
    }
  });
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
