#import "SiperbCaptureViewRegistry.h"

@implementation SiperbCaptureViewRegistry

// strongToWeakObjects: the key is a boxed integer we own; the value is the host's view, held
// weakly so this registry never keeps a screen off-screen view alive.
+ (NSMapTable<NSNumber *, UIView *> *)table {
    static NSMapTable *table;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        table = [NSMapTable strongToWeakObjectsMapTable];
    });
    return table;
}

+ (void)registerView:(UIView *)view forKey:(NSInteger)key {
    if (view == nil) {
        return;
    }
    @synchronized(self) {
        [[self table] setObject:view forKey:@(key)];
    }
}

+ (void)removeKey:(NSInteger)key {
    @synchronized(self) {
        [[self table] removeObjectForKey:@(key)];
    }
}

+ (nullable UIView *)viewForKey:(NSInteger)key {
    @synchronized(self) {
        return [[self table] objectForKey:@(key)];
    }
}

@end
