# mymodule.rb -- version 2 (post-reload)

def compute(n)
  # v2: triples the input
  n * 3
end

def transform(value, n)
  # v2: multiplies value by n
  value * n
end

def aggregate(history)
  # v2: sums the history array (same behavior)
  history.sum
end
