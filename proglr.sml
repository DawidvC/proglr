
structure Parse = ParseFun(Lexer)

structure Util = struct
  (* list as set *)
  fun mem x xs = List.exists (fn y => y = x) xs
  fun add (x, xs) = if mem x xs then xs else x::xs
  fun union [] ys = ys
    | union (x::xs) ys = union xs (add (x, ys))
  fun remove (x, []) = []
    | remove (x, y::ys) = if x = y then remove (x, ys) else y::(remove (x, ys))
  fun minus (xs, ys) = List.foldr (fn (y, xs) => remove (y, xs)) xs ys
  fun uniq xs = List.foldr add [] xs
  
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

  fun escapeUnicode s =
        let
          fun pad d =
                case String.size d of
                     4 => "\\u" ^ d
                   | 8 => "\\U" ^ d
                   | l => if l < 8 then pad ("0" ^ d)
                          else raise Fail (d ^ ": too large for unicode")
          val wchars = UTF8.explode s
          fun isAlphaNum c =
                UTF8.isAscii c andalso Char.isAlphaNum (UTF8.toAscii c)
          fun escapeWChar c =
                if isAlphaNum c
                then UTF8.toString c
                else pad (Word.toString c)
        in
          concat (map escapeWChar (UTF8.explode s))
        end
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

signature GRAMMAR = sig
  (* constructor is 'label' of LBNF; 'EInt' part of 'EInt. Exp ::= Integer' *)
  datatype constructor = Id of string | Wild  | ListE | ListCons | ListOne
  type rule
  type grammar

  (* a symbol may be a nonterminal (Nonterm), a terminal bearing no value (UnitTerm)
   * or a terminal bearing a value *)
  datatype kind = Nonterm | UnitTerm | IntTerm | StrTerm | CharTerm | RealTerm
  eqtype symbol

  (* constructor functions for GRAMMAR types *)
  val fromAst : Parse.Ast.grammar -> grammar
  val makeRule : constructor * symbol * symbol list -> rule

  (* a rule consists of label(cons), value category(lhs),
   * and production rules(rhs) *)
  val consOf : rule -> constructor
  val lhsOf : rule -> symbol
  val rhsOf : rule -> symbol list

  (* a grammar consists of one start symbol, rules, terminal symbols and
   * nonterminal symbols *)
  val startSymbolOf : grammar -> symbol
  val rulesOf : grammar -> rule list
  val termsOf : grammar -> symbol list
  val nontermsOf : grammar -> symbol list

  (* a symbol may be a terminal or a nonterminal *)
  val isTerm : symbol -> bool
  val kindOf : symbol -> kind
  (* a symbol has level if it is nonterminal, e.g. Cat, [Cat], [[Cat]]... *)
  val levelOf : symbol -> int
  val identOfSymbol : symbol -> string

  (* pretty printers *)
  val showCons : constructor -> string
  val showRule : rule -> string
  val showSymbol : symbol -> string
  val printGrammar : TextIO.outstream -> grammar -> unit

  (* special symbols *)
  val S' : symbol
  val EOF : symbol
end

structure Grammar :> GRAMMAR = struct
  structure Handle (* :> HASHABLE where type t = string * int *) = struct
    (* handle for grammatical symbol.
       T = ("T", 0), [T] = ("T", 1), [[T]] = ("T", 2), ... *)
    type t = string * int
    fun eq (a, b) = a = b
    fun hash (ident, level) =
      let
        val word8ToWord = Word.fromLarge o Word8.toLarge
        fun hash (ch, h) = JenkinsHash.hashInc h (word8ToWord ch)
      in
        Word8Vector.foldl hash (Word.fromInt level) (Byte.stringToBytes ident)
      end
    fun show (str, ~1) = str
      | show (ident, 0) = ident
      | show (ident, level) = "[" ^ show (ident, level - 1) ^ "]"
  end
  structure SymbolHashTable = HashTable(Handle)

  datatype kind = Nonterm | UnitTerm | IntTerm | StrTerm | CharTerm | RealTerm
  type symbol = Handle.t * kind

  datatype constructor = Id of string | Wild  | ListE | ListCons | ListOne
  type lhs = symbol
  type rhs = symbol list
  type rule = constructor * lhs * rhs
  type grammar = {
         terms : symbol list,
         nonterms : symbol list,
         rules : rule list,
         start : symbol}

  fun isTerm (_, Nonterm) = false
    | isTerm ((_, 0), _) = true
    | isTerm ((_, _), _) = false
  fun showSymbol ((ident, 0), _) = ident
    | showSymbol ((ident, level), kind) = "[" ^ showSymbol ((ident, level - 1), kind) ^ "]"
  fun kindOf (_, kind) = kind
  fun levelOf ((_, level), _) = level
  fun identOfSymbol ((ident, _), _) = ident
  val S' = (("S'", 0), Nonterm)
  val EOF = (("EOF", 0), UnitTerm)

  fun makeRule (rule as (constructor, lhs, rhs)) =
    if isTerm lhs then raise Fail "non-terminal cannot be lhs of a rule"
    else rule

  fun rulesOf ({rules,...} : grammar) = rules

  fun consOf (constructor, _, _) = constructor
  fun lhsOf (_, lhs, _) = lhs
  fun rhsOf (_, _, rhs) = rhs

  fun fromAst ast =
    (* Construct a grammar from an AST.
     * A grammar consists of terms, nonterms, rules and a start symbol.
     * Create them in order. *)
    let
      (* utility functions *)
      fun catToHandle (Parse.Ast.IdCat (_, ident)) = (ident, 0)
        | catToHandle (Parse.Ast.ListCat (_, cat)) =
            let val (ident, level) = catToHandle cat in
              (ident, level + 1)
            end
      fun itemToHandle (Parse.Ast.Terminal (_, str)) = (str, ~1)
        | itemToHandle (Parse.Ast.NTerminal (_, cat)) = catToHandle cat
      fun labelToCons (Parse.Ast.Id (_, ident)) = Id ident
        | labelToCons (Parse.Ast.Wild _) = Wild
        | labelToCons (Parse.Ast.ListE _) = ListE
        | labelToCons (Parse.Ast.ListCons _) = ListCons
        | labelToCons (Parse.Ast.ListOne _) = ListOne
      (* a hash table in which all terms and nonterms will be stored
       * for checking duplicate *)
      val table = SymbolHashTable.table 256
      (* visit token definitions and collect terms *)
      val terms =
        let
          fun termsOfGrammar (Parse.Ast.Grammar (_, tokens, _)) terms =
                termsOfTokens tokens terms
          and termsOfTokens [] terms = []
            | termsOfTokens (token::tokens) terms =
                termsOfToken token (termsOfTokens tokens terms)
          and termsOfToken (Parse.Ast.Keyword (_, name, literal)) terms =
                let
                  val hand = (name, 0)
                  val symbol = (hand, UnitTerm)
                  val (term, present) = SymbolHashTable.lookupOrInsert' table hand (fn () => symbol)
                  val literalHand = (literal, ~1)
                in
                  (* 'literal' form can be used as an 'alias' of token name *)
                  (SymbolHashTable.lookupOrInsert table literalHand (fn () => symbol);
                  if present then terms else term::terms)
                end
            | termsOfToken (Parse.Ast.AttrToken (_, name, attr)) terms =
                let
                  val hand = (name, 0)
                  val kind =
                    case attr of
                      "string" => StrTerm
                    | "int"    => IntTerm
                    | "char"   => CharTerm
                    | "real"   => RealTerm
                    | t        => raise Fail ("unknown type: " ^ t)
                  val symbol = (hand, kind)
                  val (term, present) = SymbolHashTable.lookupOrInsert' table hand (fn () => symbol)
                in
                  if present then terms else term::terms
                end
            | termsOfToken (Parse.Ast.NoAttrToken (_, name)) terms =
                let
                  val hand = (name, 0)
                  val symbol = (hand, UnitTerm)
                  val (term, present) = SymbolHashTable.lookupOrInsert' table hand (fn () => symbol)
                in
                  if present then terms else term::terms
                end
        in
          termsOfGrammar ast []
        end
      (* visit rules and collect nonterms *)
      val nonterms =
        let
          fun nontermsOfGrammar (Parse.Ast.Grammar (_, _, defs)) syms =
                nontermsOfDefs defs syms
          and nontermsOfDefs [] syms = []
            | nontermsOfDefs (def::defs) syms =
                nontermsOfDef def (nontermsOfDefs defs syms)
          and nontermsOfDef (Parse.Ast.Rule (_, label, cat, items)) syms =
                nontermsOfCat cat syms
            | nontermsOfDef (Parse.Ast.Separator (span, minimumsize, cat, separator)) syms =
                nontermsOfCat (Parse.Ast.ListCat (span, cat)) syms
            | nontermsOfDef (Parse.Ast.Terminator (span, minimumsize, cat, terminator)) syms =
                nontermsOfCat (Parse.Ast.ListCat (span, cat)) syms
            | nontermsOfDef (Parse.Ast.Coercions (span, ident, level)) syms =
                let
                  fun coerce 0 syms = nontermsOfCat (Parse.Ast.IdCat (span, ident)) syms
                    | coerce level syms =
                        coerce (level - 1) (nontermsOfCat (Parse.Ast.IdCat (span, ident ^ Int.toString level)) syms)
                in
                  coerce level syms
                end
          and nontermsOfCat cat syms = 
                let
                  val hand as (ident, level) = catToHandle cat
                  fun symf ()= case SymbolHashTable.find table (ident, 0) of
                                  SOME (_, kind) => (hand, kind)
                                | NONE => (hand, Nonterm)
                  val (sym, present) = SymbolHashTable.lookupOrInsert' table hand symf
                in
                  if present then syms else sym::syms
                end
        in
          nontermsOfGrammar ast []
        end
      (* collect rules, expand macros if needed *)
      val rules =
        let
          (* constructor functions for polymorphic list rules *)
          fun makeNilRule span cat =
            Parse.Ast.Rule
              (span, Parse.Ast.ListE span, Parse.Ast.ListCat (span, cat), [])
          fun makeOneRule span cat separator =
            Parse.Ast.Rule
              (span,
               Parse.Ast.ListOne span,
               Parse.Ast.ListCat (span, cat),
               [Parse.Ast.NTerminal (span, cat)]
               @ (if separator = "" then []
                  else [Parse.Ast.Terminal (span, separator)]))
          fun makeConsRule span cat separator =
            Parse.Ast.Rule
              (span,
               Parse.Ast.ListCons span,
               Parse.Ast.ListCat (span, cat),
               [Parse.Ast.NTerminal (span, cat)]
               @ (if separator = "" then []
                  else [Parse.Ast.Terminal (span, separator)])
               @ [Parse.Ast.NTerminal (span, Parse.Ast.ListCat (span, cat))])
          (* visitors *)
          fun rulesOfGrammar (Parse.Ast.Grammar (_, terminals, defs)) rules = rulesOfDefs defs rules
          and rulesOfDefs [] rules = []
            | rulesOfDefs (def::defs) rules =
                rulesOfDef def (rulesOfDefs defs rules)
          and rulesOfDef (Parse.Ast.Rule (_, label, cat, items)) rules =
                let
                  val cons = labelToCons label
                  val lhs = SymbolHashTable.lookup table (catToHandle cat)
                            handle Absent => raise Fail "error while constructing a grammar from AST. (possible bug)"
                  fun l i =
                    let
                      val h = itemToHandle i
                    in
                      SymbolHashTable.lookup table h
                      handle Absent => raise Fail ("symbol " ^ (Handle.show h) ^ " not defined.")
                    end
                  val rhs = map l items
                in
                  (cons, lhs, rhs)::rules
                end
            | rulesOfDef (Parse.Ast.Separator (span, minimumsize, cat, separator)) rules =
                (* expand separator macro *)
                let
                  val emptyCase = makeNilRule span cat
                  val oneCase = makeOneRule span cat ""
                  val consCase = makeConsRule span cat separator
                in
                  case minimumsize of
                      Parse.Ast.MEmpty _ =>
                        rulesOfDef consCase (rulesOfDef oneCase (rulesOfDef emptyCase rules))
                    | Parse.Ast.MNonempty _ =>
                        rulesOfDef consCase (rulesOfDef oneCase rules)
                end
            | rulesOfDef (Parse.Ast.Terminator (span, minimumsize, cat, terminator)) rules =
                (* expand terminator macro *)
                let
                  val emptyCase = makeNilRule span cat
                  val oneCase = makeOneRule span cat terminator
                  val consCase = makeConsRule span cat terminator
                in
                  case minimumsize of
                      Parse.Ast.MEmpty _ =>
                        rulesOfDef consCase (rulesOfDef emptyCase rules)
                    | Parse.Ast.MNonempty _ =>
                        rulesOfDef consCase (rulesOfDef oneCase rules)
                end
            | rulesOfDef (Parse.Ast.Coercions (span, ident, level)) rules =
                (* expand coercions macro *)
                let
                  val atomicRule = 
                    Parse.Ast.Rule
                      (span,
                       Parse.Ast.Wild span, 
                       Parse.Ast.IdCat (span, ident ^ Int.toString level),
                       [Parse.Ast.Terminal (span, "("),
                        Parse.Ast.NTerminal (span, Parse.Ast.IdCat (span, ident)),
                        Parse.Ast.Terminal (span, ")")])
                  fun levelToString 0 = ""
                    | levelToString level = Int.toString level
                  fun makeCoerceRule level =
                        Parse.Ast.Rule
                          (span,
                           Parse.Ast.Wild span,
                           Parse.Ast.IdCat (span, ident ^ levelToString (level - 1)),
                           [Parse.Ast.NTerminal (span, Parse.Ast.IdCat (span, ident ^ levelToString level))])
                  fun coerce 1 rules =
                        rulesOfDef (makeCoerceRule 1) rules
                    | coerce level rules =
                        coerce (level - 1) (rulesOfDef (makeCoerceRule level) rules)
                in
                  coerce level (rulesOfDef atomicRule rules)
                end
        in
          rulesOfGrammar ast []
        end
      (* the start symbols is lhs of the first rule *)
      val start = lhsOf (hd rules)
    in
      {terms = terms, nonterms = nonterms, rules = rules, start = start}
    end

  fun startSymbolOf ({start,...} : grammar) = start
  fun termsOf ({terms,...} : grammar) = terms
  fun nontermsOf ({nonterms,...} : grammar) = nonterms

  fun showCons (Id s) = s
    | showCons Wild = "_"
    | showCons ListE = "[]"
    | showCons ListCons = "(:)"
    | showCons ListOne = "(:[])"
  fun showRule (con, lhs, rhs) =
    showCons con ^ ". "
      ^ showSymbol lhs ^ " ::= "
      ^ String.concatWith " " (List.map showSymbol rhs) ^ ";"
  fun printGrammar out ({terms, nonterms, rules, start} : grammar) =
    let
      fun println s =
        (TextIO.output (out, s); TextIO.output (out, "\n"); TextIO.flushOut out)
      val printRule = println o showRule
    in
      println ("terms = {" ^ String.concatWith ", " (map showSymbol terms) ^
      "}");
      println ("nonterms = {" ^ String.concatWith ", " (map showSymbol nonterms)
      ^ "}");
      println ("start = " ^ (showSymbol start));
      List.app printRule rules
    end
end

signature LRITEM = sig
  eqtype item
  type items = item list
  val fromRule : Grammar.rule -> item
  val expand : items -> Grammar.rule list -> items
  val moveOver : items -> Grammar.symbol -> Grammar.rule list -> items
  val nextSymbols : items -> Grammar.symbol list
  val partition :items -> items * items
  val consOf : item -> Grammar.constructor
  val lhsOf : item -> Grammar.symbol
  val rhsBeforeDot : item -> Grammar.symbol list
  val show : item -> string
end

structure LrItem :> LRITEM = struct
  local
    open Grammar
    type lhs = symbol
    type rhs_before_dot = symbol list
    type rhs_after_dot = symbol list
  in
    type item = constructor * lhs * rhs_before_dot * rhs_after_dot
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
                (* if the dot is not in front of a non-terminal *)
                (_, _, _, [])     => loop lrItems (lrItem::expanded)
              | (_, _, _, sym::_) =>
                  if Grammar.isTerm sym then
                    (* if the dot is not in front of a non-terminal *)
                    loop lrItems (lrItem::expanded)
                  else
                    (* if the dot is in front of a non-terminal *)
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
            loop lrItems (Util.add (nextSymbol, symbols))
    in
      loop lrItems []
    end

  fun partition lrItems =
    List.partition endsWithDot lrItems

  fun consOf (cons, _, _, _) = cons
  fun lhsOf (_, lhs, _, _) = lhs
  fun rhsBeforeDot (_, _, rhs, []) = rhs

  fun show (_, lhs, rhs1, rhs2) =
    Grammar.showSymbol lhs ^ " -> "
      ^ String.concatWith " " (List.map Grammar.showSymbol rhs1)
      ^ " . "
      ^ String.concatWith " " (List.map Grammar.showSymbol rhs2)
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
  val printAutomaton : TextIO.outstream -> automaton -> unit
end

structure Automaton :> AUTOMATON where
  type state = State.state
  and type alphabet = Grammar.symbol
  = struct
  open State
  type state = State.state
  type state_number = int
  type alphabet = Grammar.symbol
  type transition = state_number * alphabet * state_number
  type automaton = LrItem.items Intern.pool * transition list

  fun stateOfLrItems lrItems = LrItem.partition lrItems

  fun makeAutomaton grammar =
    let
      val startRule = Grammar.makeRule (Grammar.Wild , Grammar.S', [Grammar.startSymbolOf grammar])
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

  fun printStates outs states =
    let
      fun printLrItem lrItem = TextIO.output (outs, LrItem.show lrItem ^ "\\n")
      fun printState (n, state) = (
            TextIO.output (outs, ("State" ^ Int.toString n ^ " [ label=\"State" ^
            Int.toString n ^ "\\n"));
            List.app printLrItem state;
            TextIO.output (outs, "\"]\n"))
    in
      List.app printState (Intern.toList states)
    end
  
  fun printTransitions outs transitions =
    let
      fun printTransition (s1, symbol, s2) = (
            TextIO.output (outs, "State" ^ Int.toString s1);
            TextIO.output (outs, " -> State" ^ Int.toString s2);
            TextIO.output (outs, " [ label=\"");
            TextIO.output (outs, Grammar.showSymbol symbol);
            TextIO.output (outs, "\"]\n"))
    in
      List.app printTransition transitions
    end

  fun printAutomaton outs (states, transitions) = (
        TextIO.output (outs, "digraph automaton {\n");
        TextIO.output (outs, "graph [ rankdir = LR ];\n");
        TextIO.output (outs, "node [shape = box ];\n");
        printStates outs states;
        printTransitions outs transitions;
        TextIO.output (outs, "}\n"))
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
      | EqTypeSpec of typedesc
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
    | printSpec outs indent (EqTypeSpec []) = ()
    | printSpec outs indent (EqTypeSpec (first::rest)) =
      let
        fun printEqTypeSpec pre ty =
          out outs indent (pre ^ " " ^ ty)
      in
        (printEqTypeSpec "eqtype" first;
        List.app (printEqTypeSpec "and") rest)
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
  fun nt2dt nonterm =
    Util.toLower (Util.chopDigit (Grammar.identOfSymbol nonterm))

  (* Terms: appropriate atomic types
     Nonerms: T => T, [T] => T list ...  *)
  fun symToTycon prefix sym = 
    let
      fun suffix 0 = ""
        | suffix n = suffix (n - 1) ^ " list"
      val level = Grammar.levelOf sym
    in
      case Grammar.kindOf sym of
        Grammar.UnitTerm => NONE
      | Grammar.IntTerm  => SOME (MLAst.Tycon ("int" ^ suffix level))
      | Grammar.StrTerm  => SOME (MLAst.Tycon ("string" ^ suffix level))
      | Grammar.CharTerm => SOME (MLAst.Tycon ("char" ^ suffix level))
      | Grammar.RealTerm => SOME (MLAst.Tycon ("real" ^ suffix level))
      | Grammar.Nonterm  => SOME (MLAst.Tycon (prefix ^ (nt2dt sym) ^ suffix level))
    end

  fun symToCategory sym =
    let
      fun addPrimes s 0 = s
        | addPrimes s n = addPrimes s (n - 1) ^ "'"
    in
      addPrimes (Grammar.identOfSymbol sym) (Grammar.levelOf sym)
    end

  (* string -> Grammar.symbol list -> MLAst.dec *)
  (* example output: datatype token = EOF | ... *)
  fun makeTokenDatatype typeName tokens =
    let
      fun f symbol = (Grammar.identOfSymbol symbol, (symToTycon "") symbol)
      fun makeTycons tokens = List.map f tokens
    in
      MLAst.Datatype [(typeName, makeTycons tokens)]
    end

  (* symbol list -> MLAst.dec *)
  (* example outpu: fun show (EOF) = "EOF" | ... *)
  fun makeShowFun tokens =
    let
      fun makePat symbol = 
        case (Grammar.kindOf symbol, Grammar.levelOf symbol) of
          (Grammar.Nonterm, _) =>  MLAst.AsisPat ("(" ^ symToCategory symbol ^ " _)")
        | (Grammar.UnitTerm, _) => MLAst.AsisPat ("(" ^ symToCategory symbol ^ ")")
        | (_, 0) =>                MLAst.AsisPat ("(" ^ symToCategory symbol ^ " a)")
        | (_, _) =>                MLAst.AsisPat ("(" ^ symToCategory symbol ^ " _)")
      fun makeBody symbol =
        case (Grammar.kindOf symbol, Grammar.levelOf symbol) of
          (Grammar.UnitTerm, _) => MLAst.AsisExp ("\"" ^ symToCategory symbol ^ "\"")
        | (Grammar.IntTerm,  0) => MLAst.AsisExp ("\"" ^ symToCategory symbol ^ "(\" ^ Int.toString a ^ \")\"")
        | (Grammar.StrTerm,  0) => MLAst.AsisExp ("\"" ^ symToCategory symbol ^ "(\" ^ a ^ \")\"")
        | (Grammar.CharTerm, 0) => MLAst.AsisExp ("\"" ^ symToCategory symbol ^ "(\" ^ Char.toString a ^ \")\"")
        | (Grammar.RealTerm, 0) => MLAst.AsisExp ("\"" ^ symToCategory symbol ^ "(\" ^ Real.toString a ^ \")\"")
        | (Grammar.Nonterm,  _) => MLAst.AsisExp ("\"" ^ symToCategory symbol ^ "\"")
        | (_, _)                => MLAst.AsisExp ("\"" ^ symToCategory symbol ^ "\"")
      val patExps = List.map (fn token => ([makePat token], makeBody token)) tokens
    in
      MLAst.Fun [("show", patExps)]
    end

  (* makeAstDatatype : string list -> Grammar.rule list -> MLAst.dec *)
  (* example output:
       datatype grammar =
         Grammar of Lex.span * defs
       and defs = ... *)
  fun makeAstDatatype idents rules =
    let
      fun makeDatatype name =
        let
          val rules =
            List.filter
            (fn rule =>
              name = Util.chopDigit (Grammar.identOfSymbol (Grammar.lhsOf rule))
              andalso Grammar.levelOf (Grammar.lhsOf rule) = 0)
            rules
          fun ruleToCons rule =
            case Grammar.consOf rule of
              Grammar.Wild     => NONE
            | Grammar.ListE    => NONE
            | Grammar.ListCons => NONE
            | Grammar.ListOne  => NONE
            | Grammar.Id ident =>
                case List.mapPartial (symToTycon "") (Grammar.rhsOf rule) of
                  []  => SOME (ident, SOME (MLAst.Tycon "Lex.span"))
                | tys => SOME (ident, SOME (MLAst.TupleType (MLAst.Tycon "Lex.span"::tys)))
        in
          (* type name and constructors *)
          (Util.toLower name, List.mapPartial ruleToCons rules)
        end
    in
      (* this makes mutually recursive datatypes *)
      MLAst.Datatype (List.map makeDatatype idents)
    end

  (* example output:
       datatype category =
         EOF
       | Grammar of Ast.grammar
       ... *)
  fun makeCategoryDatatype typeName symbols =
    let
      fun f symbol =
        let val name = symToCategory symbol in
          (name, symToTycon "Ast." symbol)
        end
      fun makeTycons tokens = List.map f tokens
    in
      MLAst.Datatype [(typeName, makeTycons symbols)]
    end

  (* example output:
       fun fromToken (Token.EOF) = EOF
         | fromToken ... *)
  fun makeFromTokenFun tokens =
    let
      fun makePat symbol =
        case Grammar.kindOf symbol of
          Grammar.Nonterm  => raise Fail ""
        | Grammar.UnitTerm => MLAst.AsisPat ("(Token." ^ Grammar.identOfSymbol symbol ^ ")")
        | _                => MLAst.AsisPat ("(Token." ^ Grammar.identOfSymbol symbol ^ " a)")
      fun makeBody symbol =
        case Grammar.kindOf symbol of
          Grammar.Nonterm  => raise Fail ""
        | Grammar.UnitTerm => MLAst.AsisExp (Grammar.identOfSymbol symbol)
        | _                => MLAst.AsisExp (Grammar.identOfSymbol symbol ^ " a")
      val patExps = List.map (fn token => ([makePat token], makeBody token)) tokens
    in
      MLAst.Fun [("fromToken", patExps)]
    end

  fun holdSv sym =
    case Grammar.kindOf sym of
      Grammar.UnitTerm => false
    | _ => true

  (* st functions *)
  fun makeStMrule automaton (symbol, next) =
    let
      val pat = if holdSv symbol
                then MLAst.AsisPat (symToCategory symbol ^ " _")
                else MLAst.AsisPat (symToCategory symbol)
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
                ^ symToCategory sym
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
              Grammar.Id c => MLAst.AppExp (MLAst.AsisExp ("Ast." ^ c), MLAst.TupleExp (MLAst.AsisExp ("(" ^ fromPos ^ ", pos)")::map MLAst.AsisExp svalues))
            | Grammar.Wild => MLAst.TupleExp (map MLAst.AsisExp svalues)
            | Grammar.ListE => MLAst.AsisExp "[]"
            | Grammar.ListCons => 
                let
                  val head = List.nth (svalues, 0) handle Subscript => raise Fail "a"
                  val tail = List.nth (svalues, 1) handle Subscript => raise Fail "b"
                in
                  MLAst.AsisExp ("(" ^ head ^ "::" ^ tail ^ ")")
                end
            | Grammar.ListOne => MLAst.AsisExp ("[" ^ hd svalues ^ "]")
          val currentAst = MLAst.AppExp (MLAst.AsisExp (symToCategory lhs), svaluesAst)
        in
          ("st" ^ n ^ "r", [
              if lhs = Grammar.S' then
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

  fun generateParser outs grammar automaton =
    let
      val tokens = Grammar.EOF :: Grammar.termsOf grammar
      val nonterms = Grammar.nontermsOf grammar
      val rules = Grammar.rulesOf grammar
      val startSymbol = Grammar.startSymbolOf grammar
      val categories = tokens @ nonterms
      val numbersAndStates = Automaton.numbersAndStates automaton
      val stateNumbers = List.map #1 numbersAndStates
    
      (* Token *)
      val tokenDatatype = makeTokenDatatype "token" tokens
      val tokenShowFun = makeShowFun tokens
      val tokenStructure =
        MLAst.Structure [("Token", MLAst.Struct
          [MLAst.Dec tokenDatatype,
           MLAst.Dec tokenShowFun])]
    
      (* Ast *)
      val nontermIdents = map (Util.chopDigit o Grammar.identOfSymbol) nonterms
      val termIdents = map (Util.chopDigit o Grammar.identOfSymbol) tokens
      (* idents are the datatypes to be defined.
         term identifiers should be removed *)
      val idents = Util.uniq (Util.minus (nontermIdents, termIdents))
      val astDatatype = makeAstDatatype idents rules
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
          MLAst.EqTypeSpec ["pos"],
          MLAst.TypeSpec ["span = pos * pos"], (* dirty *)
          MLAst.EqTypeSpec ["tok"],
          MLAst.ValSpec [("lex", MLAst.AsisType "AntlrStreamPos.sourcemap -> strm -> tok * span * strm")],
          MLAst.ValSpec [("getPos", MLAst.AsisType "strm -> pos")]])]

      val parseLoop = MLAst.Fun [
        ("loop" , [([MLAst.AsisPat "stacks", MLAst.AsisPat "strm"],
          MLAst.Let (
            [MLAst.AsisDec "val pos = Lex.getPos strm",
             MLAst.AsisDec "val (token, span, strm') = Lex.lex sourcemap strm"],
            MLAst.Case (MLAst.AsisExp "token",
            [(MLAst.AsisPat "Token.EOF",
               MLAst.Let (
                 [MLAst.AsisDec "val completeStacks = List.filter (fn (st, _) => st = ~1) stacks",
                  MLAst.AsisDec "val topCategories = map (fn (st, stack) => hd stack) completeStacks",
                  MLAst.AsisDec ("fun toAst (" ^ symToCategory startSymbol ^ " sv, _, _) = SOME sv | toAst _ = NONE")],
                  MLAst.AsisExp "List.mapPartial toAst topCategories")),
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
        "ParseFun",
        "Lex",
        MLAst.SigId ("Lex",
          [("tok", MLAst.Tycon "Token.token"), ("pos", MLAst.Tycon "AntlrStreamPos.pos")]),
        parseStructure)]
    in
      MLAst.printStrdec outs 0 tokenStructure;
      MLAst.printSigdec outs 0 lexSignature;
      MLAst.printFundec outs 0 parseFunctor
    end
end

structure ResourceGen = struct
  (* spawn command specified by args whose stdout is connected to outs
     and execute function f which takes stdin of the spawned process *)
  fun spawn args outs f =
        let
          val (BinPrimIO.WR {ioDesc, ...}, _) =
                BinIO.StreamIO.getWriter (BinIO.getOutstream outs)
          val fd = (Option.valOf o Posix.FileSys.iodToFD o Option.valOf) ioDesc
          val {infd = pipeIn, outfd = pipeOut} = Posix.IO.pipe ()
          val writer = Posix.IO.mkTextWriter {
                fd = pipeOut,
                name = "-",
                appendMode = true,
                initBlkMode = false,
                chunkSize = 1024 }
          val outs =
                TextIO.mkOutstream (TextIO.StreamIO.mkOutstream (writer, IO.LINE_BUF))
        in
          case Posix.Process.fork () of
               NONE => (
                 Posix.IO.close pipeOut;
                 Posix.IO.dup2 {old = pipeIn, new = Posix.FileSys.stdin};
                 Posix.IO.close pipeIn;
                 Posix.IO.dup2 {old = fd, new = Posix.FileSys.stdout};
                 Posix.IO.close fd;
                 Posix.Process.execp (hd args, args);
                 ())
             | SOME pid => (
                 Posix.IO.close pipeIn;
                 f outs;
                 Posix.IO.close pipeOut;
                 Posix.Process.waitpid (Posix.Process.W_CHILD pid, []);
                 ())
        end

  fun expand defs resourceName outputName =
        let
          val args = ["m4"] @ defs
          fun feed outs =
                let
                  val content = Resource.get resourceName
                in
                  TextIO.output (outs, content);
                  TextIO.flushOut outs
                end
          val outs = BinIO.openOut outputName
        in
          spawn args outs feed;
          BinIO.closeOut outs
        end

  fun dirExists path =
    let
      val dir = OS.FileSys.openDir path 
    in
      OS.FileSys.closeDir dir;
      true
    end
    handle OS.SysErr _ => false

  fun mkDirP dir =
    let
      val canonical = OS.Path.mkCanonical dir
      val {arcs, isAbs, vol} = OS.Path.fromString canonical
      val parent = if isAbs then "/" else "."
      fun concatAndMake (t, path) =
        let val newPath = OS.Path.concat (path, t) in
          if dirExists newPath then ()
          else OS.FileSys.mkDir newPath;
          newPath
        end
    in
      ignore (List.foldl concatAndMake parent arcs)
    end

  fun generateResources "mlton" = ()
    | generateResources m =
        let
          fun emitResource ("", _) = ()
            | emitResource (path, content) =
                let
                  val {dir, file} = OS.Path.splitDirFile path
                in
                  mkDirP dir;
                  let
                    val outs = BinIO.openOut path
                    val content = Byte.stringToBytes content
                  in
                    BinIO.output (outs, content);
                    BinIO.closeOut outs
                  end
                end
        in
          List.app emitResource Resource.resources
        end

  fun expandResources m l =
        let
          val resources =
                case m of
                     "mlton" => ["boot.sml.m4",
                                 "main.mlb.m4",
                                 "main.sml.m4"]
                   | _       => ["boot.sml.m4",
                                 "main.sml.m4"]
          val defs = case l of
                          SOME f => ["-DPROGLR_SCAN_SML=" ^ f ^ ".sml"]
                        | NONE => []
        in
          List.app (fn r => expand defs r (OS.Path.base r)) resources
        end

  fun generateLexer l tokens =
        let
          fun tokenToDef (Parse.Ast.AttrToken (_, "Integer", "int")) =
                SOME "-DPROGLR_USE_INTEGER"
            | tokenToDef (Parse.Ast.AttrToken (_, "Double", "real")) =
                SOME "-DPROGLR_USE_DOUBLE"
            | tokenToDef (Parse.Ast.AttrToken (_, "Char", "char")) =
                SOME "-DPROGLR_USE_CHAR"
            | tokenToDef (Parse.Ast.AttrToken (_, "String", "string")) =
                SOME "-DPROGLR_USE_STRING"
            | tokenToDef (Parse.Ast.AttrToken (_, "Ident", "string")) =
                SOME "-DPROGLR_USE_IDENT"
            | tokenToDef _ = NONE
          val defs = List.mapPartial tokenToDef tokens
          fun expandLexer () = expand defs "scan.ulex.m4" l
          fun generateSml () =
                let
                  val args = ["ml-ulex", l]
                  val outs =
                    BinIO.openOut "/dev/null"
                  fun f outs = ()
                in
                  spawn args outs f
                end
        in
          expandLexer ();
          generateSml ()
        end
end

structure Args = struct
  open GetOpt

  val opts = [StrOpt #"m", StrOpt #"d", StrOpt #"l"]

  fun getM [] = NONE
    | getM (Str (#"m", m)::opts) = SOME m
    | getM (_::opts) = getM opts

  fun getD [] = NONE
    | getD (Str (#"d", d)::opts) = SOME d
    | getD (_::opts) = getD opts

  fun getL [] = NONE
    | getL (Str (#"l", l)::opts) = SOME l
    | getL (_::opts) = getL opts

  fun parse args = getopt opts (List.::) [] args
end

structure Main = struct
  fun writeDot automaton fileName =
        let
          val outs = TextIO.openOut fileName
        in
          Automaton.printAutomaton outs automaton
          before TextIO.closeOut outs
        end

  fun generate ins inFileName outs opts =
    let
      val strm = Lexer.streamifyInstream ins
      val sourcemap =
            case inFileName of
              NONE => AntlrStreamPos.mkSourcemap ()
            | SOME name => AntlrStreamPos.mkSourcemap' name
      val asts = Parse.parse sourcemap strm handle Fail s =>
            let
              val pos = Lexer.getPos strm
              val str = AntlrStreamPos.toString sourcemap pos
            in
              raise Fail ("Parsing failed at " ^ str ^ ", caused by \"" ^ s ^ "\"")
            end
      val ast = case asts of [ast] => ast | _ => raise Fail "parsing failed"
      val grammar = Grammar.fromAst ast
      val automaton = Automaton.makeAutomaton grammar
      val Parse.Ast.Grammar (_, tokens, _) = ast
      val lexFileName = Args.getL opts
    in
      (* Print the grammar as comment *)
      TextIO.output (outs, "(*\n");
      Grammar.printGrammar outs grammar;
      TextIO.output (outs, "*)\n");
      (* and then the structure *)
      CodeGenerator.generateParser outs grammar automaton;
      case lexFileName of
           SOME l => ResourceGen.generateLexer l tokens
         | NONE => ();
      case Args.getM opts of
           SOME m => (
             ResourceGen.generateResources m;
             ResourceGen.expandResources m lexFileName)
         | NONE => ();
      case  Args.getD opts of
           SOME d => writeDot automaton d
         | NONE => ()
    end
    handle e => TextIO.output (TextIO.stdErr, exnMessage e ^ "\n")
end

fun main () =
  let
    val (opts, sources) = Args.parse (CommandLine.arguments ())
    fun replaceExt (path, newExt) =
      let val {base, ext} = OS.Path.splitBaseExt path in base ^ "." ^ newExt end
  in
    case sources of
         [] => Main.generate TextIO.stdIn NONE TextIO.stdOut opts
       | sources =>
           let
             fun generate fileName =
               let
                 val ins = TextIO.openIn fileName
                 val outs = TextIO.openOut (replaceExt (fileName, "sml"))
               in
                 Main.generate ins (SOME fileName) outs opts
               end
           in
             List.app generate sources
           end
  end
  handle e => TextIO.output (TextIO.stdErr, exnMessage e ^ "\n")
