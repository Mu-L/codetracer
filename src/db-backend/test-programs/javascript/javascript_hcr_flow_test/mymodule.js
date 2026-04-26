// mymodule.js -- version 1 (pre-reload)

function compute(n) {
    // v1: doubles the input
    return n * 2;
}

function transform(value, n) {
    // v1: adds n to value
    return value + n;
}

function aggregate(history) {
    // v1: sums the history array
    return history.reduce(function(a, b) { return a + b; }, 0);
}

module.exports = { compute: compute, transform: transform, aggregate: aggregate };
