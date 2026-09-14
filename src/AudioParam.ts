/**
 * The controllable value of an audio node (GainNode.gain). Only the static `value` is
 * meaningful here: the graph is declarative and nothing is scheduled against a clock, so the
 * automation methods (`setValueAtTime`, ...) are deliberately absent rather than stubbed.
 *
 * @see {@link https://developer.mozilla.org/en-US/docs/Web/API/AudioParam MDN}
 */
export default class AudioParam {
    readonly defaultValue: number;
    readonly minValue: number;
    readonly maxValue: number;
    private _value: number;

    constructor(defaultValue: number, minValue = -3.4028234663852886e38, maxValue = 3.4028234663852886e38) {
        this.defaultValue = defaultValue;
        this.minValue = minValue;
        this.maxValue = maxValue;
        this._value = defaultValue;
    }

    get value(): number {
        return this._value;
    }

    set value(value: number) {
        const numeric = Number(value);

        // WebIDL `float`: a non-finite value is a TypeError, not a silent clamp.
        if (!Number.isFinite(numeric)) {
            throw new TypeError(`AudioParam value must be a finite number, got ${value}`);
        }

        this._value = Math.min(this.maxValue, Math.max(this.minValue, numeric));
    }
}
