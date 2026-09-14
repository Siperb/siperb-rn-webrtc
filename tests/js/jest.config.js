/* eslint-disable no-undef */

// Runs the JS layer against a mocked bridge. Neither `react` nor `react-native` is installed in
// this repo (both are the consumer's), so every import of them is mapped to a stub in ./mocks.
module.exports = {
    rootDir: '../..',
    roots: [ '<rootDir>/tests/js' ],
    testEnvironment: 'node',
    transform: {
        '^.+\\.tsx?$': [ 'ts-jest', { tsconfig: '<rootDir>/tests/js/tsconfig.json' } ]
    },
    moduleNameMapper: {
        '^react-native$': '<rootDir>/tests/js/mocks/react-native.ts',
        '^react-native/Libraries/vendor/emitter/EventEmitter$': '<rootDir>/tests/js/mocks/emitter.ts',
        '^react$': '<rootDir>/tests/js/mocks/react.ts',
        '^react/jsx-runtime$': '<rootDir>/tests/js/mocks/react-jsx-runtime.ts'
    },
    testMatch: [ '**/tests/js/**/*.test.ts' ]
};
