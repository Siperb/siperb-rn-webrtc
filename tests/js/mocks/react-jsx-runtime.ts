/** The automatic JSX runtime RTCPIPView.tsx compiles against; nothing is ever rendered here. */
export function jsx(type: unknown, props: unknown) {
    return { type, props };
}

export const jsxs = jsx;
export const Fragment = Symbol('Fragment');
