/* Swizzles -[NSProcessInfo hostName] so the demo app shows a generic
 * machine name in marketing screenshots instead of the real hostname.
 * Built by stage.sh; loaded via DYLD_INSERT_LIBRARIES in run.sh (the app
 * copy is re-signed without the hardened runtime so the insert applies). */
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static NSString *DemoHostName(id self, SEL _cmd) {
  return @"studio.local";
}

__attribute__((constructor)) static void demo_hostname_init(void) {
  /* macOS 26 Foundation backs NSProcessInfo with _NSSwiftProcessInfo, which
   * overrides hostName; swizzle the concrete class of the shared instance. */
  Class cls = object_getClass([NSProcessInfo processInfo]);
  Method m = class_getInstanceMethod(cls, @selector(hostName));
  if (m != NULL) {
    method_setImplementation(m, (IMP)DemoHostName);
  }
}
