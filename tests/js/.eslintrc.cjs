/* eslint-disable no-undef */

// The root config lives in src/ with `root: true`, so this directory needs its own entry point.
module.exports = {
    extends: [ '../../src/.eslintrc.cjs' ],
    root: true,
    env: { jest: true, node: true },
};
