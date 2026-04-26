#!/usr/bin/env node
// HCR flow test -- pre/post reload variable verification.

var fs = require("fs");
var path = require("path");
var mymodule = require("./mymodule");

var counter = 0;
var history = [];

for (var i = 0; i < 12; i++) {
    counter += 1;
    if (counter === 7) {
        // Copy v2 over v1 and invalidate require cache
        fs.copyFileSync(
            path.join(__dirname, "mymodule_v2.js"),
            path.join(__dirname, "mymodule.js")
        );
        delete require.cache[require.resolve("./mymodule")];
        mymodule = require("./mymodule");
    }
    var value = mymodule.compute(counter);         // line 23: breakpoint target
    var delta = mymodule.transform(value, counter);
    history.push(delta);
    var total = mymodule.aggregate(history);
    console.log("step=" + counter + " value=" + value + " delta=" + delta + " total=" + total);
}
