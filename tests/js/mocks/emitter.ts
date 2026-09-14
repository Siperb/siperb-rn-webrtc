/**
 * Stand-in for react-native/Libraries/vendor/emitter/EventEmitter: the subset EventEmitter.ts
 * uses (addListener returning a removable subscription, emit).
 */
type Listener = (...args: any[]) => void;

export default class EventEmitter {
    private _listeners = new Map<string, Set<Listener>>();

    addListener(eventName: string, listener: Listener) {
        if (!this._listeners.has(eventName)) {
            this._listeners.set(eventName, new Set());
        }

        this._listeners.get(eventName)?.add(listener);

        return { remove: () => this._listeners.get(eventName)?.delete(listener) };
    }

    emit(eventName: string, ...args: any[]) {
        for (const listener of Array.from(this._listeners.get(eventName) ?? [])) {
            listener(...args);
        }
    }
}
