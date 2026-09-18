#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * A process-wide map of integer keys → native UIViews that {@link getWhiteboardMedia} can sample
 * when the view is NOT React-managed. `getWhiteboardMedia` normally resolves its `sourceTag`
 * through RCTViewRegistry (`viewForReactTag:`), which only knows views RN mounted. A host whose
 * UI is native (SwiftUI / UIKit) has no such tag for its drawing surface, so it registers that
 * view here under a key it then hands to `GetWhiteboardMedia({ sourceTag: key })`; the capture path
 * falls back to this registry when the React lookup misses.
 *
 * Views are held WEAKLY — the host owns the view's lifetime, and a deallocated view simply
 * resolves to nil (the same NotFoundError a stale React tag gives). Keys are the host's to choose;
 * pick a range that will not collide with React tags (which are small positive integers).
 */
@interface SiperbCaptureViewRegistry : NSObject

+ (void)registerView:(UIView *)view forKey:(NSInteger)key;
+ (void)removeKey:(NSInteger)key;
+ (nullable UIView *)viewForKey:(NSInteger)key;

@end

NS_ASSUME_NONNULL_END
