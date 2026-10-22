#if defined(__APPLE__)
// The macOS half of host_settings.h: what FlutterMacOS reads for its apps.
#include "host_settings.h"

#import <Foundation/Foundation.h>

namespace raccoon {

HostSettings ReadHostSettings() {
  HostSettings settings;
  @autoreleasepool {
    for (NSString* tag in [NSLocale preferredLanguages]) {
      HostLocale locale = ParseLocale(tag.UTF8String);
      if (!locale.language.empty()) settings.locales.push_back(locale);
    }
    // Set to "Dark" while the system is dark, "Auto" included, and absent
    // when light; no application is needed to read it. A message to nil
    // answers 0, which is NSOrderedSame: the key has to be there.
    NSString* style = [[NSUserDefaults standardUserDefaults] stringForKey:@"AppleInterfaceStyle"];
    settings.dark = style != nil && [style caseInsensitiveCompare:@"Dark"] == NSOrderedSame;
    // The hour cycle of the user's locale, their 24-hour switch included.
    NSString* hours = [NSDateFormatter dateFormatFromTemplate:@"j"
                                                      options:0
                                                       locale:[NSLocale currentLocale]];
    settings.always_24_hour = [hours rangeOfString:@"H"].location != NSNotFound ||
                              [hours rangeOfString:@"k"].location != NSNotFound;
  }
  return settings;
}

}  // namespace raccoon
#endif  // __APPLE__
