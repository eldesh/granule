{
module HappyParser where

import AlexToken
import Expr
}

%name defs
%tokentype { Token }
%error { parseError }

%token
    nl    { TokenNL }
    let   { TokenLet }
    in    { TokenIn }
    NUM   { TokenNum $$ }
    VAR   { TokenSym $$ }
    Int   { TokenInt }
    Bool  { TokenBool }
    '\\'  { TokenLambda }
    '->'  { TokenArrow }
    '='   { TokenEq }
    '+'   { TokenAdd }
    '-'   { TokenSub }
    '*'   { TokenMul }
    '('   { TokenLParen }
    ')'   { TokenRParen }
    ':'   { TokenSig }
    '['   { TokenBoxLeft }
    ']'   { TokenBoxRight }

%left '+' '-'
%left '*'
%%

Defs : Def                         { [$1] }
     | Defs nl Def                 { $1 ++ [$3] }

Def : Sig nl Binding               { if (fst $1 == fst $3)
	                              then Def (fst $3) (snd $3) (snd $1)
 	                              else error $ "Signature for " ++ fst $3 ++ " does not match the signature head" }

Sig : VAR ':' Type                 { ($1, $3) }

Binding : VAR '=' Expr             { ($1, $3) }

Type : Int                         { ConT TyInt }
     | Bool                        { ConT TyBool }
     | Type '->' Type              { FunTy $1 $3 }
     | '[' Type ']' Coeffect       { Box $4 $2 }

Coeffect :
       NUM                     { Nat $1 }
     | VAR                     { CVar $1 }

Expr : let VAR '=' Expr in Expr    { App (Abs $2 $6) $4 }
     | let '[' VAR ':' Type ']' '=' Expr in Expr
                                   { LetBox $3 $5 $8 $10 }
     | '\\' VAR '->' Expr          { Abs $2 $4 }
     | Form                        { $1 }

Form : Form '+' Form               { Binop Add $1 $3 }
     | Form '-' Form               { Binop Sub $1 $3 }
     | Form '*' Form               { Binop Mul $1 $3 }
     | Juxt                        { $1 }

Juxt : Juxt Atom                   { App $1 $2 }
     | Atom                        { $1 }

Atom : '(' Expr ')'                { $2 }
     | NUM                         { Num $1 }
     | VAR                         { Var $1 }
     | '[' Expr ']'                { Promote $2 }

{
parseError :: [Token] -> a
parseError t = error $ "Parse error, at token " ++ show t

parseDefs :: String -> [Def]
parseDefs = defs . scanTokens
}
