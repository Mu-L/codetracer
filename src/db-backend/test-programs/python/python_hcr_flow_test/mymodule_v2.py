# mymodule.py — version 2 (post-reload)

def compute(n):
    """v2: triples the input."""
    return n * 3

def transform(value, n):
    """v2: multiplies value by n."""
    return value * n

def aggregate(history):
    """v2: sums the history list (same behavior)."""
    return sum(history)
