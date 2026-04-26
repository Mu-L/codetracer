# mymodule.rb -- version 1 (pre-reload)

def compute(n)
  # v1: doubles the input
  n * 2
end

def transform(value, n)
  # v1: adds n to value
  value + n
end

def aggregate(history)
  # v1: sums the history array
  history.sum
end
