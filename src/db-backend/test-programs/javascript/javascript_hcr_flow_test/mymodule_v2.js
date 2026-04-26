// mymodule.js -- version 2 (post-reload)

function compute(n) {
    // v2: triples the input
    return n * 3;
}

function transform(value, n) {
    // v2: multiplies value by n
    return value * n;
}

function aggregate(history) {
    // v2: sums the history array (same behavior)
    return history.reduce(function(a, b) { return a + b; }, 0);
}

module.exports = { compute: compute, transform: transform, aggregate: aggregate };
