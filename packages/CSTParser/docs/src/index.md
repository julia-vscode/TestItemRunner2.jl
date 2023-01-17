```@meta
CurrentModule = CSTParser
```

# CSTParser

[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://www.julia-vscode.org/CSTParser.jl/dev)
[![Project Status: Active - The project has reached a stable, usable state and is being actively developed.](http://www.repostatus.org/badges/latest/active.svg)](http://www.repostatus.org/#active)
![](https://github.com/julia-vscode/CSTParser.jl/workflows/Run%20CI%20on%20master/badge.svg)
[![codecov](https://codecov.io/gh/julia-vscode/CSTParser.jl/branch/master/graph/badge.svg)](https://codecov.io/gh/julia-vscode/CSTParser.jl)

A parser for Julia using [Tokenize](https://github.com/JuliaLang/Tokenize.jl/) that aims to extend the built-in parser by providing additional meta information along with the resultant AST.

## Installation and Usage
```julia
using Pkg
Pkg.add("CSTParser")
```
```julia
using CSTParser
```
**Documentation**: [![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://www.julia-vscode.org/CSTParser.jl/dev)


### Additional Output
- `EXPR`'s are iterable producing children in the order that they appear in the source code, including punctuation.

    Example:
  ```
  f(x) = x*2 becomes [f(x), =, x*2]
  f(x) becomes [f, (, x, )]
  ```
- The byte span of each `EXPR` is stored allowing a mapping between byte position in the source code and the releveant parsed expression. The span of a single token includes any trailing whitespace, newlines or comments. This also allows for fast partial parsing of modified source code.
- Formatting hints are generated as the source code is parsed (e.g. mismatched indents for blocks, missing white space around operators).
- The declaration of modules, functions, datatypes and variables are tracked and stored in the relevant hierarchical scopes attatched to the expressions that declare the scope. This allows for a mapping between any identifying symbol and the relevant code that it refers to.

### Structure

Expressions are represented solely by the following types:
```
Parser.SyntaxNode
  Parser.EXPR
  Parser.INSTANCE
    Parser.HEAD{K}
    Parser.IDENTIFIER
    Parser.KEYWORD{K}
    Parser.LITERAL{K}
    Parser.OPERATOR{P,K,dot}
    Parser.PUNCTUATION
  Parser.QUOTENODE
```

The `K` parameterisation refers to the `kind` of the associated token as specified by `Tokenize.Tokens.Kind`. The `P` and `dot` parameters for operators refers to the precedence of the operator and whether it is dotted (e.g. `.+`).

`INSTANCE`s represent singular objects that may have a concrete or implicit relation to a portion of the source text. In the the former case they have a `span` storing the width in bytes that they occupy in the source text, in the latter case their span is 0. Additionally, `IDENTIFIER`s store their value as a `Symbol` and `LITERAL`s as a `String`.

`EXPR` are equivalent to `Base.Expr` but have extra fields to store their span and any punctuation tokens.
