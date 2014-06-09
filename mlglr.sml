
structure Parse = ParseFun(Lexer)

structure Util = struct
  (* list as set *)
  fun mem x xs = List.exists (fn y => y = x) xs
  fun add x xs = if mem x xs then xs else x::xs
  fun union [] ys = ys
    | union (x::xs) ys = union xs (add x ys)
  
  fun dropWhile p [] = []
    | dropWhile p (x::xs) = if p x then dropWhile p xs else x::xs
  
  fun chopDigit s = 
    let
      val cs = rev (String.explode s)
      val cs' = dropWhile Char.isDigit cs
    in
      String.implode (rev cs')
    end
  
  fun toLower s = String.implode (List.map Char.toLower (String.explode s))
  fun toUpper s = String.implode (List.map Char.toUpper (String.explode s))
end

signature INTERN = sig
  type ''a pool
  val emptyPool : ''a pool
  val intern : ''a -> ''a pool -> int * ''a pool
  val internAll : ''a list -> ''a pool -> int list * ''a pool
  val present : int -> ''a pool -> bool
  val valueOf : int -> ''a pool -> ''a
  val numbersOf : ''a pool -> int list
  val toList : ''a pool -> (int * ''a) list
end

structure Intern :> INTERN = struct
  type ''a pool = (int * ''a) list

  val emptyPool  = []
  fun nextNumber [] = 0
    | nextNumber ((number, _)::values) = number + 1
  fun intern value pool =
    case List.find (fn (_, value') => value = value') pool of
      SOME (number, _) => (number, pool)
    | NONE =>
      let
        val number = nextNumber pool
        val pool' = (number, value)::pool
      in
        (number, pool')
      end
  fun internAll values pool =
    let
      fun loop [] pool numbers = (rev numbers, pool)
        | loop (value::values) pool numbers =
            let val (number, pool') = intern value pool in
              loop values pool' (number::numbers)
            end
    in
      loop values pool []
    end
  fun present number [] = false
    | present number ((number', _)::pool) =
        number = number' orelse present number pool
  fun valueOf number pool =
    let
      val (_, value) = valOf (List.find (fn (number', _) => number = number') pool)
    in
      value
    end
  fun numbersOf pool = List.map (fn (n, _) => n) pool
  fun toList pool = pool
end

(* grammatical symbols: terminal and non-terminal *)
signature SYMBOL = sig
  eqtype symbol
  datatype attr_type = Unit | Int | Str | Char
  datatype kind = TERM of attr_type | NONTERM
  val isTerm : symbol -> bool
  val attrOf : symbol -> attr_type
  val show : symbol -> string
  val makeSymbols : (string * attr_type) list * string list -> (symbol list * symbol list)
  val S' : symbol
  val EOF : symbol
end

structure Symbol :> SYMBOL where type symbol = int = struct
  type symbol = int
  type name = string
  datatype attr_type = Unit | Int | Str | Char
  datatype kind = TERM of attr_type | NONTERM

  val S' = 0
  val EOF = 1
  val symbols : (string * kind) vector ref = ref (Vector.fromList [])
  fun makeSymbols (terms, nonterms) =
    let
      val numTerms = length terms
      val numNonterms = length nonterms
      val terms' = map (fn (name, attrType) => (name, TERM attrType)) terms
      val nonterms' = map (fn name => (name, NONTERM)) nonterms
      val symbols' = [("S'", NONTERM), ("EOF", TERM Unit)] @ terms' @ nonterms'
    in
      (symbols := (Vector.fromList symbols');
      (List.tabulate (numTerms, (fn n => 2 + n)),
       List.tabulate (numNonterms, (fn n => 2 + numTerms + n ))))
    end

  fun lookup symbol =
    SOME (Vector.sub (!symbols, symbol))
    handle Subscript => NONE

  fun show symbol =
    case lookup symbol of
      SOME (name, _) => name
    | NONE => raise Fail "symbol not found"

  fun isTerm symbol =
    case lookup symbol of
      SOME (_, TERM _) => true
    | SOME (_, NONTERM) => false
    | NONE => raise Fail "symbol not found"

  fun attrOf symbol =
    case lookup symbol of
      SOME (_, TERM attrType) => attrType
    | SOME (_, NONTERM) => raise Fail ("symbol " ^ show symbol ^ " is nonterm")
    | NONE => raise Fail "symbol not found"
end

signature GRAMMAR = sig
  datatype constructor = Label of string | Wild
  type rule
  type grammar

  val fromAst : Parse.Ast.grammar -> grammar
  val makeRule : constructor * Symbol.symbol * Symbol.symbol list -> rule
  val makeGrammar : Symbol.symbol list -> Symbol.symbol list -> (constructor * Symbol.symbol * Symbol.symbol list) list -> Symbol.symbol -> grammar
  val rulesOf : grammar -> rule list
  val consOf : rule -> constructor
  val lhsOf : rule -> Symbol.symbol
  val rhsOf : rule -> Symbol.symbol list
  val startSymbolOf : grammar -> Symbol.symbol
  val termsOf : grammar -> Symbol.symbol list
  val nontermsOf : grammar -> Symbol.symbol list
  val attrOf : Symbol.symbol -> (Symbol.symbol * Symbol.attr_type) list -> Symbol.attr_type

  val isConsDefined : constructor -> bool
  val showCons : constructor -> string

  val showRule : rule -> string
  val printGrammar : grammar -> unit
end

structure Grammar :> GRAMMAR = struct
  datatype constructor = Label of string | Wild
  local
    open Symbol
    type lhs = symbol
    type rhs = symbol list
    type terms = symbol list
    type nonterms = symbol list
    type start = symbol
  in
    type rule = constructor * lhs * rhs
    type grammar = terms * nonterms * rule list * start
  end

  local
    open Parse.Ast
    fun tokensOfGrammar (Grammar (_, defs)) tokens =
      tokensOfDefs defs tokens
    and tokensOfDefs (NilDef _) tokens = tokens
      | tokensOfDefs (ConsDef (_, def, defs)) tokens =
          tokensOfDef def (tokensOfDefs defs tokens)
    and tokensOfItems (NilItem _) tokens = tokens
      | tokensOfItems (ConsItem (_, item, items)) tokens =
          tokensOfItem item (tokensOfItems items tokens)
    and tokensOfDef (Rule (_, label, cat, items)) tokens =
          tokensOfCat cat (tokensOfItems items tokens)
    and tokensOfItem (Terminal (_, ident)) tokens = ident::tokens
      | tokensOfItem (NTerminal (_, cat)) tokens = 
          tokensOfCat cat tokens
    and tokensOfCat (IdCat (_, ident)) tokens = ident::tokens
      | tokensOfCat (ListCat (_, cat)) tokens =
          let
            val _ = ()
          in
            tokens
          end
  in
    fun fromAst ast =
      let 
        val nonterms = tokensOfGrammar ast
      in
        ([], [], [], Symbol.S')
      end
  end

  fun makeRule (rule as (constructor, lhs, rhs)) =
    if Symbol.isTerm lhs then raise Fail "non-terminal cannot be lhs of a rule"
    else rule
  fun makeGrammar terms nonterms rules startSymbol =
    let
      val rules = List.map makeRule rules
    in
      (terms, nonterms, rules, startSymbol)
    end
  fun rulesOf (_, _, rules, _) = rules
  fun consOf (constructor, _, _) = constructor
  fun lhsOf (_, lhs, _) = lhs
  fun rhsOf (_, _, rhs) = rhs
  fun startSymbolOf (_, _, _, startSymbol) = startSymbol
  fun termsOf (terms, _, _, _) = terms
  fun nontermsOf (_, nonterms, _, _) = nonterms
  fun attrOf symbol terms =
    #2 (valOf (List.find (fn (symbol', attr) => symbol = symbol') terms))

  fun isConsDefined Wild = false | isConsDefined _ = true
  fun showCons (Label s) = s | showCons Wild = "_"
  fun showRule (con, lhs, rhs) =
    showCons con ^ ". "
      ^ Symbol.show lhs ^ " ::= "
      ^ String.concatWith " " (List.map Symbol.show rhs) ^ ";"
  fun printGrammar (_, _, rules, _) =
    let
      fun printRule rule = print (showRule rule ^ "\n")
    in
      List.app printRule rules
    end
end

signature LRITEM = sig
  eqtype item
  type items = item list
  val fromRule : Grammar.rule -> item
  val expand : items -> Grammar.rule list -> items
  val moveOver : items -> Symbol.symbol -> Grammar.rule list -> items
  val nextSymbols : items -> Symbol.symbol list
  val partition :items -> items * items
  val consOf : item -> Grammar.constructor
  val lhsOf : item -> Symbol.symbol
  val rhsBeforeDot : item -> Symbol.symbol list
  val show : item -> string
end

structure LrItem :> LRITEM = struct
  local
    open Symbol
    type lhs = symbol
    type rhs_before_dot = symbol list
    type rhs_after_dot = symbol list
  in
    type item = Grammar.constructor * lhs * rhs_before_dot * rhs_after_dot
    type items = item list
  end

  fun fromRule rule = (Grammar.consOf rule, Grammar.lhsOf rule, [], Grammar.rhsOf rule)

  fun expand (lrItems : items) (rules : Grammar.rule list) =
    let
      (* 1st = unexpanded items, 2nd = expanded items *)
      fun loop [] expanded = expanded
        | loop (lrItem::lrItems) expanded =
            if Util.mem lrItem expanded then loop lrItems expanded
            else
              case lrItem of
                (* if the dot is not in fromt of a non-terminal *)
                (_, _, _, [])     => loop lrItems (lrItem::expanded)
              | (_, _, _, sym::_) =>
                  if Symbol.isTerm sym then
                    (* if the dot is not in fromt of a non-terminal *)
                    loop lrItems (lrItem::expanded)
                  else
                    (* if the dot is in fromt of a non-terminal *)
                    let
                     (* all grammar rules of the form sym->... *)
                      val rules = List.filter (fn rule => Grammar.lhsOf rule = sym) rules
                     (* convert the rules to LR items *)
                      val newLrItems = map fromRule rules
                    in
    		  (* lrItem is expanded now, since it generated new items.
    		     The new items are possibly unexpanded. *)
                      loop (newLrItems @ lrItems) (lrItem::expanded)
                    end
    in
      loop lrItems []
    end

  fun moveOver items symbol grammar =
    let
      fun move (c, n, l, []) = NONE
        | move (c, n, l, next::rest) =
          if next = symbol then SOME (c, n, l @ [next], rest)
          else NONE
      val moved = List.mapPartial move items
    in
      expand moved grammar
    end

  fun endsWithDot (_, _, _, []) = true
    | endsWithDot _ = false

  fun nextSymbols lrItems =
    let
      fun loop [] symbols = symbols
        | loop ((_, _, _, [])::lrItems) symbols = loop lrItems symbols
        | loop ((_, _, _, nextSymbol::_)::lrItems) symbols =
            loop lrItems (Util.add nextSymbol symbols)
    in
      loop lrItems []
    end

  fun partition lrItems =
    List.partition endsWithDot lrItems

  fun consOf (cons, _, _, _) = cons
  fun lhsOf (_, lhs, _, _) = lhs
  fun rhsBeforeDot (_, _, rhs, []) = rhs

  fun show (_, lhs, rhs1, rhs2) =
    Symbol.show lhs ^ " -> "
      ^ String.concatWith " " (List.map Symbol.show rhs1)
      ^ " . "
      ^ String.concatWith " " (List.map Symbol.show rhs2)
end

structure State = struct
  type state = LrItem.items * LrItem.items
end

signature AUTOMATON = sig
  type state
  type state_number = int
  eqtype alphabet
  type transition = state_number * alphabet * state_number
  type automaton
  val makeAutomaton : Grammar.grammar -> automaton
  val stateNumbers : automaton -> state_number list
  val stateOf : state_number -> automaton -> state
  val nextStatesOf : state_number -> automaton -> (alphabet * state_number) list
  val numbersAndStates : automaton -> (state_number * state) list
  val printAutomaton : automaton -> unit
end

structure Automaton :> AUTOMATON where
  type state = State.state
  and type alphabet = Symbol.symbol
  = struct
  open State
  type state = State.state
  type state_number = int
  type alphabet = Symbol.symbol
  type transition = state_number * alphabet * state_number
  type automaton = LrItem.items Intern.pool * transition list

  fun stateOfLrItems lrItems = LrItem.partition lrItems

  fun makeAutomaton grammar =
    let
      val startRule = Grammar.makeRule (Grammar.Wild , Symbol.S', [Grammar.startSymbolOf grammar])
      val rules = Grammar.rulesOf grammar
      val startState = LrItem.expand [LrItem.fromRule startRule] rules
      val (startStateNumber, pool) = Intern.intern startState Intern.emptyPool
  
      (* loop U S T
           where U = numbers of unprocessed state, 
                 S = a list of states and numbers,
                 T = trnasitions *)
      fun loop [] pool transitions = (pool, transitions)
        | loop (number::numbers) pool transitions =
            let
              val state = Intern.valueOf number pool
              val nextSymbols = LrItem.nextSymbols state
              val nextStates = map (fn symbol => LrItem.moveOver state symbol rules) nextSymbols
              val (nextStateNumbers, pool') = Intern.internAll nextStates pool
              (* State numbers which are not present in old S are new *)
              val newStateNumbers = List.filter (fn number => not (Intern.present number pool)) nextStateNumbers
              val newTransitions =
                map
                  (fn (symbol, nextStateNumber) => (number, symbol, nextStateNumber))
                  (ListPair.zip (nextSymbols, nextStateNumbers))
            in
              loop (newStateNumbers @ numbers) pool' (newTransitions @ transitions)
            end
    in
      loop [startStateNumber] pool []
    end
  fun stateNumbers (pool, _) = Intern.numbersOf pool
  fun stateOf number (pool, _) = stateOfLrItems (Intern.valueOf number pool)
  fun numbersAndStates (pool, _) = List.map (fn (n, items) => (n, stateOfLrItems items)) (Intern.toList pool)
  fun nextStatesOf state (_, transitions) =
    List.map (fn (_, symbol, next) => (symbol, next)) (List.filter (fn (s', _, _) => state = s') transitions)

  fun printStates states =
    let
      fun showState state = String.concatWith " | " (List.map LrItem.show state)
      fun printState (n, state) = print (Int.toString n ^ ": " ^ showState state ^ "\n")
    in
      List.app printState (Intern.toList states)
    end
  
  fun printTransitions transitions =
    let
      fun printTransition (s1, symbol, s2) =
        print (Int.toString s1 ^ " -> " ^ Symbol.show symbol ^ " -> " ^ Int.toString s2 ^ "\n")
    in
      List.app printTransition transitions
    end

  fun printAutomaton (states, transitions) =
    (printStates states;
    printTransitions transitions)
end

structure MLAst = struct
  type ident = string
  type tycon = string
  
  datatype
      ty =
        Tycon of tycon
      | TupleType of ty list
      | AsisType of string
  and strexp = Struct of strdec list
  and strdec = 
        Structure of strbind
      | Dec of dec
  and sigdec = Signature of sigbind
  and dec =
        Datatype of datbind list
      | Fun of fvalbind list
      | Val of pat * exp
      | AsisDec of string
  and exp =
        AsisExp of string
      | Let of dec list * exp
      | Case of exp * mrule list
      | TupleExp of exp list
      | AppExp of exp * exp
  and pat = AsisPat of string
  and fundec = Functor of funbind
  and sigexp =
        Sig of spec list
      | SigId of ident * (ident * ty) list
  and spec =
        ValSpec of valdesc
      | TypeSpec of typedesc
  withtype
      datbind = ident * (ident * ty option) list
  and fvalbind = ident * (pat list * exp) list
  and strbind = (ident * strexp) list
  and sigbind = (ident * sigexp) list
  and mrule = pat * exp
  and funbind = (ident * ident * sigexp * strexp) list
  and valdesc = (ident * ty) list
  and typedesc = ident list

  fun p out s = (TextIO.output (out, s); TextIO.flushOut out)
  fun printIndent out 0 = ()
    | printIndent out n = (p out " "; printIndent out (n - 1))
  fun out outs indent str = (printIndent outs indent; p outs str; p outs "\n")

  exception BlockExp
  fun showTy (Tycon tycon) = tycon
    | showTy (TupleType tys) =
      let
        fun prepend [] = "unit"
          | prepend [ty] = showTy ty
          | prepend (ty::tys) = (showTy ty) ^ " * " ^ prepend tys
      in
        prepend tys
      end
    | showTy (AsisType ty) = ty
  fun showPat (AsisPat string) = string
  fun showExp (AsisExp string) = string
    | showExp (Let _) = raise BlockExp
    | showExp (Case _) = raise BlockExp
    | showExp (TupleExp []) = "()"
    | showExp (TupleExp (first::rest)) =
      let
        fun addComma exp = ", " ^ showExp exp
      in
        "(" ^ showExp first ^ concat (map addComma rest) ^ ")"
      end
    | showExp (AppExp (e1, e2)) = "(" ^ showExp e1 ^ " " ^ showExp e2 ^ ")"
  fun showSigExp (SigId (sigid, [])) = sigid
    | showSigExp (SigId (sigid, first::rest)) =
      let
        fun showWh (t, tycon) = " type " ^ t ^ " = " ^ (showTy tycon)
      in
        sigid ^ " where" ^ (showWh first)
        ^ List.foldl (fn (wh, acc) => acc ^ " and" ^ showWh wh) "" rest
      end
  fun printExp outs indent (exp as AsisExp string) = out outs indent (showExp exp)
    | printExp outs indent (Let (decs, exp)) =
      (out outs indent "let";
      List.app (printDec outs (indent + 2)) decs;
      out outs indent "in";
      printExp outs (indent + 2) exp;
      out outs indent "end")
    | printExp outs indent (Case (exp, mrules)) =
      let
        fun printMrule indent pre (pat, exp) =
          out outs indent (pre ^ showPat pat ^ " => " ^ showExp exp)
          handle BlockExp =>
            (out outs indent (pre ^ showPat pat ^ " =>");
            printExp outs (indent + 2) exp)
        fun printMrules indent [] = ()
          | printMrules indent (first::rest) =
          (printMrule indent "  " first;
          List.app (printMrule indent "| ") rest)
      in
        out outs indent ("case " ^ showExp exp ^ " of");
        printMrules indent mrules
      end
    | printExp outs indent exp = out outs indent (showExp exp)
  and printDec outs indent (Datatype []) = ()
    | printDec outs indent (Datatype (first::rest)) =
      let
        fun printConbind indent pre (vid, ty) =
          out outs indent (pre ^ vid ^ (case ty of NONE => "" | SOME ty => " of " ^ showTy ty))
        fun printConbinds indent [] = ()
          | printConbinds indent (first::rest) =
          (printConbind indent "  " first;
  	  List.app (printConbind indent "| ") rest)
        fun printDatbind indent pre (tycon, conbind) =
          (out outs indent (pre ^ " " ^ tycon ^ " =");
          printConbinds indent conbind)
      in
        (printDatbind indent "datatype" first;
        List.app (printDatbind indent "and") rest)
      end
    | printDec outs indent (Fun []) = ()
    | printDec outs indent (Fun (first::rest)) =
      let
        fun printFvalbind indent pre (ident, []) = out outs indent (pre ^ " " ^ ident ^ " _ = raise Fail \"unimplemented\"")
          | printFvalbind indent pre (ident, (first::rest)) =
          let
            fun printClause indent pre (patseq, exp) =
              let
                val patterns = List.foldl (fn (a,b) => b ^ " " ^ showPat a) "" patseq
              in
                let val expstr = showExp exp in
                  if (indent + String.size ident + String.size patterns + String.size expstr) >  70 then
                    raise BlockExp
                  else
                    out outs indent (pre ^ " " ^ ident ^ patterns ^ " = " ^ expstr)
                end 
                handle BlockExp =>
                  (out outs indent (pre ^ " " ^ ident ^ patterns ^ " =");
                  printExp outs (indent + 4) exp)
              end
          in
            printClause indent pre first;
            List.app (printClause indent "  |") rest
          end
      in
        (printFvalbind indent "fun" first;
        List.app (printFvalbind indent "and") rest)
      end
    | printDec outs indent (AsisDec s) = out outs indent s
  fun printStrdec outs indent (Structure []) = ()
    | printStrdec outs indent (Structure (first::rest)) =
      let
        fun printStrbind indent pre (ident, Struct strdecseq) =
          (out outs indent (pre ^ " " ^ ident ^ " = struct");
          List.app (printStrdec outs (indent + 2)) strdecseq;
          out outs indent "end")
      in
        printStrbind indent "structure" first;
        List.app (printStrbind indent "and") rest
      end
    | printStrdec outs indent (Dec dec) = printDec outs indent dec
  fun printSpec outs indent (ValSpec []) = ()
    | printSpec outs indent (ValSpec (first::rest)) =
      let
        fun printValSpec pre (ident, ty) =
          out outs indent (pre ^ " " ^ ident ^ " : " ^ showTy ty)
      in
        (printValSpec "val" first;
        List.app (printValSpec "and") rest)
      end
    | printSpec outs indent (TypeSpec []) = ()
    | printSpec outs indent (TypeSpec (first::rest)) =
      let
        fun printTypeSpec pre ty =
          out outs indent (pre ^ " " ^ ty)
      in
        (printTypeSpec "type" first;
        List.app (printTypeSpec "and") rest)
      end
  fun printSigdec outs indent (Signature []) = ()
    | printSigdec outs indent (Signature (first::rest)) =
      let
        fun printSigbind indent pre (ident, Sig specs) =
          (out outs indent (pre ^ " " ^ ident ^ " = sig");
          List.app (printSpec outs (indent + 2)) specs;
          out outs indent "end")
      in
        printSigbind indent "signature" first;
        List.app (printSigbind indent "and") rest
      end
  fun printFundec outs indent (Functor []) = ()
    | printFundec outs indent (Functor (first::rest)) =
      let
        fun printFunbind indent pre (funid, sigid, sigexp, Struct strdecs) =
          (out outs indent (pre ^ " " ^ funid ^ "(" ^ sigid ^ " : " ^ showSigExp sigexp ^ ") = struct");
          List.app (printStrdec outs (indent + 2)) strdecs;
          out outs indent "end")
          
      in
        printFunbind indent "functor" first;
        List.app (printFunbind indent "and") rest
      end
end

structure CodeGenerator = struct

  fun fromAttr Symbol.Unit = NONE
    | fromAttr Symbol.Int = SOME (MLAst.Tycon "int")
    | fromAttr Symbol.Str = SOME (MLAst.Tycon "string")
    | fromAttr Symbol.Char = SOME (MLAst.Tycon "char")

  fun makeTokenDatatype typeName tokens =
    let
      fun f symbol = (Symbol.show symbol, fromAttr (Symbol.attrOf symbol))
      fun makeTycons tokens = List.map f tokens
    in
      MLAst.Datatype [(typeName, makeTycons tokens)]
    end
  fun makeShowFun tokens =
    let
      fun makePat symbol = 
        if Symbol.isTerm symbol then
          if Symbol.attrOf symbol = Symbol.Unit then 
            MLAst.AsisPat ("(" ^ Symbol.show symbol ^ ")")
          else
            MLAst.AsisPat ("(" ^ Symbol.show symbol ^ " a)")
        else
          MLAst.AsisPat ("(" ^ Symbol.show symbol ^ " _)")
      fun makeBody symbol =
        if Symbol.isTerm symbol then
          case Symbol.attrOf symbol of
            Symbol.Unit => MLAst.AsisExp ("\"" ^ Symbol.show symbol ^ "\"")
          | Symbol.Int  => MLAst.AsisExp ("\"" ^ Symbol.show symbol ^ "(\" ^ Int.toString a ^ \")\"")
          | Symbol.Str  => MLAst.AsisExp ("\"" ^ Symbol.show symbol ^ "(\" ^ a ^ \")\"")
          | Symbol.Char => MLAst.AsisExp ("\"" ^ Symbol.show symbol ^ "(\" ^ Char.toString a ^ \")\"")
        else
          MLAst.AsisExp ("\"" ^ Symbol.show symbol ^ "\"")
      val patExps = List.map (fn token => ([makePat token], makeBody token)) tokens
    in
      MLAst.Fun [("show", patExps)]
    end
  fun nt2dt nonterm = Util.toLower (Util.chopDigit (Symbol.show nonterm))
  fun makeAstDatatype datatypeNames rules terms =
    let
      fun makeDatatype name =
        let
          fun ruleFor name = List.filter (fn rule => name = nt2dt (Grammar.lhsOf rule) andalso Grammar.isConsDefined (Grammar.consOf rule)) rules
          fun symToTycon sym = 
            if Symbol.isTerm sym then
              fromAttr (Symbol.attrOf sym)
            else
              SOME (MLAst.Tycon (nt2dt sym))
          fun f rhs =
            case List.mapPartial symToTycon rhs of
              [] => MLAst.Tycon "Lex.span"
            | tys => MLAst.TupleType (MLAst.Tycon "Lex.span"::tys)
          fun consId (Grammar.Label l) = l
        in
          (* type name and constructors *)
          (name,
          List.map (fn rule => (consId (Grammar.consOf rule), SOME (f (Grammar.rhsOf rule)))) (ruleFor name))
        end
    in
      (* this makes mutually recursive datatypes *)
      MLAst.Datatype (List.map makeDatatype datatypeNames)
    end
  fun makeCategoryDatatype typeName symbols =
    let
      fun f symbol =
        let val name = Symbol.show symbol in
          if Symbol.isTerm symbol then
            (name, fromAttr (Symbol.attrOf symbol))
          else
            (name, SOME (MLAst.Tycon ("Ast." ^ nt2dt symbol)))
        end
      fun makeTycons tokens = List.map f tokens
    in
      MLAst.Datatype [(typeName, makeTycons symbols)]
    end
  fun makeFromTokenFun tokens =
    let
      fun makePat symbol =
        if Symbol.attrOf symbol = Symbol.Unit then
          MLAst.AsisPat ("(Token." ^ Symbol.show symbol ^ ")")
        else
          MLAst.AsisPat ("(Token." ^ Symbol.show symbol ^ " a)")
      fun makeBody symbol =
        if Symbol.attrOf symbol = Symbol.Unit then
          MLAst.AsisExp (Symbol.show symbol)
        else
          MLAst.AsisExp (Symbol.show symbol ^ " a")
      val patExps = List.map (fn token => ([makePat token], makeBody token)) tokens
    in
      MLAst.Fun [("fromToken", patExps)]
    end

  fun holdSv sym =
    not (Symbol.isTerm sym) orelse Symbol.attrOf sym <> Symbol.Unit
  (* st functions *)
  fun makeStMrule automaton (symbol, next) =
    let
      val pat = if holdSv symbol
                then MLAst.AsisPat (Symbol.show symbol ^ " _")
                else MLAst.AsisPat (Symbol.show symbol)
      val (reduce, shift) = Automaton.stateOf next automaton
      val stNum = Int.toString next
      val shiftExp =
        if shift = [] then "[]"
        else "[(" ^ stNum ^ ", (stackItem::stack))]" 
      val reduceExp =
        if reduce = [] then ""
        else " @ st" ^ stNum ^ "r (stackItem::stack) toPos"
      val exp = MLAst.AsisExp (shiftExp ^ reduceExp)
    in
      (pat, exp)
    end
  fun makeStFvalbind automaton stateNumber =
    let
      val n = Int.toString stateNumber
      val (reduce, shift) = Automaton.stateOf stateNumber automaton
      fun stReduce item = 
        let
          val cons = LrItem.consOf item
          val lhs = LrItem.lhsOf item
          val rhs = LrItem.rhsBeforeDot item
          val isYpsilon = length rhs = 0
          val fromPos = if isYpsilon then "pos" else "pos0"
          val index = ref 0
          val stackPat =
            List.foldl
            (fn (sym, pats) =>
              let
                val n = Int.toString (!index)
                val sv = if holdSv sym then SOME ("sv" ^ n) else NONE
              in
                index := !index + 1;
                (sym, sv, "stNum" ^ n, "pos" ^ n)::pats
              end)
            []
            rhs
          val stackPatString =
            let
              fun toString (sym, sv, stNum, pos) =
                "("
                ^ Symbol.show sym
                ^ (case sv of SOME sv => " " ^ sv | NONE => "")
                ^ ", "
                ^ pos
                ^ ", "
                ^ stNum
                ^ ")::"
            in
              concat (map toString stackPat)
            end
          val svalues = rev (List.mapPartial #2 stackPat)
          val svaluesAst =
            case cons of 
              Grammar.Label c => MLAst.AppExp (MLAst.AsisExp ("Ast." ^ c), MLAst.TupleExp (MLAst.AsisExp ("(" ^ fromPos ^ ", pos)")::map MLAst.AsisExp svalues))
            | Grammar.Wild => MLAst.TupleExp (map MLAst.AsisExp svalues)
          val currentAst = MLAst.AppExp (MLAst.AsisExp (Symbol.show lhs), svaluesAst)
        in
          ("st" ^ n ^ "r", [
              if lhs = Symbol.S' then
                (map MLAst.AsisPat ["stack", "pos"],
                 MLAst.AsisExp "[(~1, stack)]")
              else
                (map MLAst.AsisPat ["(" ^ stackPatString ^ "stack)", "pos"],
                if isYpsilon then
                  MLAst.AsisExp ("go " ^ n ^ " stack " ^ MLAst.showExp currentAst ^ " (pos, pos)")
                else
                  MLAst.AsisExp ("go stNum0 stack " ^ MLAst.showExp currentAst ^ " (pos0, pos)"))
          ])
        end
      val st = 
        let
          val nextStates = Automaton.nextStatesOf stateNumber automaton
          val lastMrule = (MLAst.AsisPat "c", MLAst.AsisExp ("[] (* raise Parse (c, pos, " ^ n ^ ") *)"))
          val stMrules = List.map (makeStMrule automaton) nextStates @ [lastMrule]
        in
          ("st" ^ n, [
            (map MLAst.AsisPat ["stack", "category", "(fromPos, toPos)"],
            MLAst.Let ([
              MLAst.AsisDec ("val stackItem = (category, fromPos, " ^ n ^ ")")],
              MLAst.Case (MLAst.AsisExp "category", stMrules)))
          ])
        end
    in
      (if shift = [] then [] else [st]) @ map stReduce reduce
    end

  fun generateParser outs grammar =
    let
      val tokens = Symbol.EOF :: Grammar.termsOf grammar
      val nonterms = Grammar.nontermsOf grammar
      val rules = Grammar.rulesOf grammar
      val categories = tokens @ nonterms
      val automaton = Automaton.makeAutomaton grammar
      val numbersAndStates = Automaton.numbersAndStates automaton
      val stateNumbers = List.map #1 numbersAndStates
    
      (* Token *)
      val tokenDatatype = makeTokenDatatype "token" tokens
      val tokenShowFun = makeShowFun tokens
      val tokenStructure =
        MLAst.Structure [("Token", MLAst.Struct
          [MLAst.Dec tokenDatatype,
           MLAst.Dec tokenShowFun])]
    
      (* Aat *)
      val astDatatypeNames = List.foldr (fn (nonterm, datatypeNames) => Util.add (nt2dt nonterm) datatypeNames) [] nonterms
      val astDatatype = makeAstDatatype astDatatypeNames rules tokens
      val astStructure =
        MLAst.Structure [("Ast", MLAst.Struct [MLAst.Dec astDatatype])]
    
      (* Category *)
      val categoryDatatype = makeCategoryDatatype "category" categories
      val categoryShowFun = makeShowFun categories
      val fromTokenFun = makeFromTokenFun tokens
      val categoryStructure =
        MLAst.Structure [("Category", MLAst.Struct
          [MLAst.Dec categoryDatatype,
           MLAst.Dec categoryShowFun,
           MLAst.Dec fromTokenFun])]
    
      (* go function *)
      val nonacceptingStateNumbers = List.filter (fn number => let val (_, s) = Automaton.stateOf number automaton in s <> [] end) stateNumbers
      val stateNumbersAsString = List.map Int.toString nonacceptingStateNumbers
      val goMrules = List.map (fn n => (MLAst.AsisPat n, MLAst.AsisExp ("st" ^ n ^ " stack category span"))) stateNumbersAsString
      val goCase = MLAst.Case (MLAst.AsisExp "stateNumber", goMrules @ [(MLAst.AsisPat "_", MLAst.AsisExp "[]")])
      val goFvalbind =
        ("go", [
          (map MLAst.AsisPat ["stateNumber", "stack", "category", "span"], goCase)
        ])
    
      val st = List.concat (List.map (makeStFvalbind automaton) (Automaton.stateNumbers automaton))
      (* state machine function *)
      val stFuns = MLAst.Fun (goFvalbind::st)
    
      val lexSignature = MLAst.Signature [("Lex",
        MLAst.Sig [
          MLAst.TypeSpec ["strm"],
          MLAst.TypeSpec ["pos"],
          MLAst.TypeSpec ["span = pos * pos"], (* dirty *)
          MLAst.TypeSpec ["tok"],
          MLAst.ValSpec [("lex", MLAst.AsisType "AntlrStreamPos.sourcemap -> strm -> tok * span * strm")],
          MLAst.ValSpec [("getPos", MLAst.AsisType "strm -> pos")]])]

      val parseLoop = MLAst.Fun [
        ("loop" , [([MLAst.AsisPat "stacks", MLAst.AsisPat "strm"],
          MLAst.Let (
            [MLAst.AsisDec "val pos = Lex.getPos strm",
             MLAst.AsisDec "val (token, span, strm') = Lex.lex sourcemap strm"],
            MLAst.Case (MLAst.AsisExp "token",
            [(MLAst.AsisPat "Token.EOF", MLAst.AsisExp "map (fn (st, stack) => stack) (List.filter (fn (st, _) => st = ~1) stacks)"),
             (MLAst.AsisPat "_",
               MLAst.Let (
                 [MLAst.AsisDec "val category = Category.fromToken token",
                  MLAst.AsisDec "val stacks' = List.concat (map (fn (st, stack) => go st stack category span) stacks)"],
                  MLAst.AsisExp "loop stacks' strm'"))
            ])))])]

      val reduceExp =
        let
          val (reduce, shift) = Automaton.stateOf 0 automaton
        in
          if reduce = [] then "" else " @ st0r [] pos"
        end
      val parseFun = MLAst.Fun [
        ("parse", [([MLAst.AsisPat "sourcemap", MLAst.AsisPat "strm"],
          MLAst.Let (
            [MLAst.AsisDec "val pos = Lex.getPos strm",
             MLAst.AsisDec ("val stacks = [(0, [])]" ^ reduceExp),
             parseLoop],
            MLAst.AsisExp "loop stacks strm"))])]
    
      val parseStructure = MLAst.Struct [
        astStructure,
        categoryStructure,
        MLAst.Dec (MLAst.AsisDec "open Category"),
        MLAst.Dec (MLAst.AsisDec "exception Parse of category * Lex.pos * int"),
        MLAst.Dec stFuns,
        MLAst.Dec parseFun
      ]
    
      val parseFunctor = MLAst.Functor [(
        "Parse",
        "Lex",
        MLAst.SigId ("Lex", [("tok", MLAst.Tycon "Token.token")]),
        parseStructure)]
    in
      MLAst.printStrdec outs 0 tokenStructure;
      MLAst.printSigdec outs 0 lexSignature;
      MLAst.printFundec outs 0 parseFunctor
    end
end

(*
local
  open Symbol
  open Grammar
  val ([INT, LPAREN, RPAREN, SUB, DOLLAR], [S, E0, E1]) =
    Symbol.makeSymbols
      ([("INT", Int),
        ("LPAREN", Unit),
        ("RPAREN", Unit),
        ("SUB", Unit),
        ("DOLLAR", Unit)
       ],
       ["S", "E0", "E1"])
in
  val grammar = Grammar.makeGrammar
    [INT, LPAREN, RPAREN, SUB, DOLLAR] 
    [S, E0, E1]
    [
      (Label "ExpStmt", S,  [E0]),
      (* (SOME "ExpStmt", S,  [E0, DOLLAR]), *)
      (Label "SubExp" , E0, [E0, SUB, E1]),
      (Wild           , E0, [E1]),
      (Label "EInt"   , E1, [INT]),
      (Wild           , E1, [LPAREN, E0, RPAREN])]
    S
end
*)

(*
local
  open Symbol
  open Grammar
  val ([INT, DIV, DOLLAR], [S, E, F, Q]) =
    Symbol.makeSymbols
      ([("INT", Unit),
        ("DIV", Unit),
        ("DOLLAR", Unit)
       ],
       ["S", "E", "F", "Q"])
in
  val grammar = Grammar.makeGrammar
    [INT, DIV, DOLLAR]
    [S, E, F, Q]
    [
      (Label "Stmt", S,  [E, DOLLAR]),
      (Label "OpExp" , E, [E, Q, F]),
      (Label "Exp" , E, [F]),
      (Label "Int" , F, [INT]),
      (Label "Mul" , Q, []),
      (Label "Div" , Q, [DIV])]
    S
end
*)
(*
local
  open Symbol
  val ([SEMI, DOT, IS, STRING, LBRACKET, RBRACKET, IDENT, UNDERSCORE, LPAREN, COLON, RPAREN],
       [Grammar, Defs, Items, Def, Item, Cat, Label]) =
    Symbol.makeSymbols
      ([("SEMI", Unit),
        ("DOT", Unit),
        ("IS", Unit),
        ("STRING", Str),
        ("LBRACKET", Unit),
        ("RBRACKET", Unit),
        ("IDENT", Str),
        ("UNDERSCORE", Unit),
        ("LPAREN", Unit),
        ("COLON", Unit),
        ("RPAREN", Unit)
       ],
       ["Grammar", "Defs", "Items", "Def", "Item", "Cat", "Label"])
in
  val grammar = Grammar.makeGrammar
    [SEMI, DOT, IS, STRING, LBRACKET, RBRACKET, IDENT, UNDERSCORE, LPAREN, COLON, RPAREN]
    [Grammar, Defs, Items, Def, Item, Cat, Label]
    [
      (Grammar.Label "Grammar",   Grammar, [Defs]),
      (Grammar.Label "NilDef" ,   Defs,    []),
      (Grammar.Label "ConsDef",   Defs,    [Def, SEMI, Defs]),
      (Grammar.Label "NilItem",   Items,   []),
      (Grammar.Label "ConsItem",  Items,   [Item, Items]),
      (Grammar.Label "Rule",      Def,     [Label, DOT, Cat, IS, Items]),
      (Grammar.Label "Terminal",  Item,    [STRING]),
      (Grammar.Label "NTerminal", Item,    [Cat]),
      (Grammar.Label "ListCat",   Cat,     [LBRACKET, Cat, RBRACKET]),
      (Grammar.Label "IdCat",     Cat,     [IDENT]),
      (Grammar.Label "Id",        Label,   [IDENT]),
      (Grammar.Label "Wild",      Label,   [UNDERSCORE]),
      (Grammar.Label "ListE",     Label,   [LBRACKET, RBRACKET]),
      (Grammar.Label "ListCons",  Label,   [LPAREN, COLON, RPAREN]),
      (Grammar.Label "ListOne",   Label,   [LPAREN, COLON, LBRACKET, RBRACKET, RPAREN])]
    Grammar
end
*)

structure Main = struct
  fun main ins inFileName outs =
    let
      val strm = Lexer.streamifyInstream ins
      val sourcemap =
        case inFileName of 
          NONE => AntlrStreamPos.mkSourcemap ()
        | SOME name => AntlrStreamPos.mkSourcemap' name
    in
      Parse.parse sourcemap strm
      (* CodeGenerator.generateParser outs grammar *)
    end
end

fun main () =
  Main.main TextIO.stdIn NONE TextIO.stdOut