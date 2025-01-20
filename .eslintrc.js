module.exports = {
    env: {
        node: true,
        es6: true
    },
    extends: 'eslint:recommended',
    parserOptions: {
        ecmaVersion: 2020
    },
    ignorePatterns: [
        'node_modules/',
        '.history/**/*',  // Ignore all files in .history
        'dist/',
        'build/',
        '.git/'
    ],
    rules: {
        // Turn off most rules
        'indent': 'off',
        'linebreak-style': 'off',
        'quotes': 'off',
        'semi': 'off',
        'no-unused-vars': 'off',
        'no-console': 'off',
        'no-undef': 'warn',
        'no-empty': 'off',
        'no-mixed-spaces-and-tabs': 'off',
        'no-multiple-empty-lines': 'off',
        'no-trailing-spaces': 'off',
        'comma-dangle': 'off',
        'arrow-spacing': 'off',
        'space-before-function-paren': 'off',
        'space-before-blocks': 'off',
        'keyword-spacing': 'off',
        'space-infix-ops': 'off',
        'comma-spacing': 'off',
        'brace-style': 'off',
        'curly': 'off',
        'no-var': 'off',
        'prefer-const': 'off',
        'object-curly-spacing': 'off',
        'array-bracket-spacing': 'off'
    }
};
