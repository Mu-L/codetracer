// Deliberate type errors for build output testing.

// Type 'string' is not assignable to type 'number'.
const x: number = "hello";

// Type 'number' is not assignable to type 'string'.
const y: string = 42;

// Property 'nonExistent' does not exist on type '{}'.
const obj: {} = {};
console.log(obj.nonExistent);

console.log(x + y);
