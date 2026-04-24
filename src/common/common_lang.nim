## Module contains types and procedures for handling the various programming languages
## codetracer might support

# backend agnostic code, part of the lang module, should not be imported directly,
# use common/lang or frontend/lang instead.

import os

type
  Lang* = enum ## Identifies a programming language implementation
    ## Ordinals MUST match the Rust `Lang` enum in codetracer-native-backend/src/lang.rs
    ## which uses `#[repr(u8)]` with `serde_repr` for trace_metadata.json serialization.
    LangC,        # 0
    LangCpp,      # 1
    LangRust,     # 2
    LangNim,      # 3
    LangGo,       # 4
    LangPascal,   # 5
    LangFortran,  # 6
    LangD,        # 7
    LangCrystal,  # 8
    LangLean,     # 9
    LangJulia,    # 10
    LangAda,      # 11
    LangPython,   # 12
    LangRuby,     # 13
    LangRubyDb,   # 14
    LangJavascript, # 15
    LangLua,      # 16
    LangAsm,      # 17
    LangNoir,     # 18
    LangRustWasm, # 19
    LangCppWasm,  # 20
    LangSmall,    # 21
    LangPythonDb, # 22
    LangUnknown,  # 23
    LangBash,     # 24 — internal only (tree-sitter support in db-backend)
    LangZsh,      # 25 — internal only (tree-sitter support in db-backend)
    LangSolidity, # 26
    LangMasm,     # 27
    LangSway,     # 28
    LangMove,     # 29
    LangPolkavm,  # 30
    LangCairo,    # 31
    LangCircom,   # 32
    LangLeo,      # 33
    LangTolk,     # 34
    LangAiken,    # 35
    LangCadence,  # 36
    LangSolana    # 37

var CURRENT_LANG*: Lang = LangUnknown ## The current lang in the codetraces session

proc isVMLang*(lang: Lang): bool =
  ## return true if programming language implementation runs in a virtual machine
  false # lang in {LangRuby, LangPython, LangPythonDb, LangLua, LangJavascript, LangUnknown}

var IS_DB_BASED*: array[Lang, bool] = [
  #C     Cpp    Rust   Nim    Go     Pascal Fortrn D      Crystl Lean   Julia  Ada
  false, false, false, false, false, false, false, false, false, false, false, false,
  #Py    Ruby   RubyDb JS     Lua    Asm    Noir   RsWasm CppWsm Small  PyDb   Unknwn
  false, false, false, false, false, false, false, false, false, false, false, false,
  #Bash  Zsh    Sol    Masm   Sway   Move   Polka  Cairo  Circom Leo    Tolk   Aiken  Cadnce Solana
  false, false, false, false, false, false, false, false, false, false, false, false, false, false
]

IS_DB_BASED[LangRubyDb] = true
IS_DB_BASED[LangNoir] = true
IS_DB_BASED[LangSmall] = true
IS_DB_BASED[LangRustWasm] = true
IS_DB_BASED[LangCppWasm] = true
IS_DB_BASED[LangPythonDb] = true
IS_DB_BASED[LangPascal] = false
IS_DB_BASED[LangSolidity] = true
IS_DB_BASED[LangMasm] = true
IS_DB_BASED[LangSway] = true
IS_DB_BASED[LangMove] = true
IS_DB_BASED[LangPolkavm] = true
IS_DB_BASED[LangCairo] = true
IS_DB_BASED[LangCircom] = true
IS_DB_BASED[LangLeo] = true
IS_DB_BASED[LangTolk] = true
IS_DB_BASED[LangAiken] = true
IS_DB_BASED[LangCadence] = true
IS_DB_BASED[LangSolana] = true
IS_DB_BASED[LangBash] = true
IS_DB_BASED[LangZsh] = true
IS_DB_BASED[LangJavascript] = true

proc isDbBased*(lang: Lang): bool =
  ## return true if `lang` uses the db backend
  IS_DB_BASED[lang]

proc toCLang*(lang: Lang): string =
  ## convert Lang_ to string
  let langs: array[Lang, string] = [
    "c", "cpp", "rust", "nim", "go", "pascal",
    "fortran", "d", "crystal", "lean", "julia", "ada",
    "python", "ruby", "ruby", "javascript", "lua", "assembly", "noir",
    "rust", "c++", "small", "python", "unknown",
    "bash", "zsh", "solidity", "masm", "sway", "move",
    "polkavm", "cairo", "circom", "leo", "tolk", "aiken", "cadence",
    "solana"
  ]
  result = langs[lang]

proc toName*(lang: Lang): string =
  ## convert Lang_ to string
  let langs: array[Lang, string] = [
       "C", "C++", "Rust", "Nim", "Go", "Pascal",
       "Fortran", "D", "Crystal", "Lean", "Julia", "Ada",
       "Python", "Ruby", "Ruby(db)", "Javascript", "Lua", "assembly language", "Noir",
       "Rust(wasm)", "C++(wasm)",
       "Small", "Python(db)", "unknown",
       "Bash", "Zsh", "Solidity", "MASM/Miden", "Sway", "Move",
       "PolkaVM", "Cairo", "Circom", "Leo", "Tolk", "Aiken", "Cadence",
       "Solana"
  ]
  result = langs[lang]

proc toLang*(lang: string): Lang
proc toLang*(lang: cstring): Lang

proc isDbBasedForExtension*(extension: string): bool =
  ## return true if extention is for a language that uses the db backend
  let lang = toLang(extension)
  isDbBased(lang)
