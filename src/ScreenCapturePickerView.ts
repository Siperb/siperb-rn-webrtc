
import { type ViewProps, requireNativeComponent } from 'react-native';

/**
 * iOS only: wraps RPSystemBroadcastPickerView. Mount it (zero-sized is fine) and present the
 * system broadcast sheet with `UIManager.dispatchViewManagerCommand(findNodeHandle(ref), 'show', [])`.
 * Typed as a view so `style` and `ref` are accepted; it renders nothing of its own.
 */
export default requireNativeComponent<ViewProps>('ScreenCapturePickerView');
