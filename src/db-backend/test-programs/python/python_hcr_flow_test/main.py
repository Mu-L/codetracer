#!/usr/bin/env python3
"""HCR flow test — pre/post reload variable verification."""
import sys
import os
import importlib
import shutil

sys.path.insert(0, os.path.dirname(__file__))
import mymodule

counter = 0
history = []

for i in range(12):
    counter += 1
    if counter == 7:
        shutil.copy(
            os.path.join(os.path.dirname(__file__), "mymodule_v2.py"),
            os.path.join(os.path.dirname(__file__), "mymodule.py")
        )
        importlib.reload(mymodule)
    value = mymodule.compute(counter)           # line 22: breakpoint target
    delta = mymodule.transform(value, counter)
    history.append(delta)
    total = mymodule.aggregate(history)
    print(f"step={counter} value={value} delta={delta} total={total}", flush=True)
