fn main(x: Field, y: pub Field) {
    let a: Field = 42;
    let b: bool = a;  // type mismatch: Field cannot be assigned to bool
    assert(b);
}
