type token = Chunk_parser.token History.loc

exception Parse_error of Location.t

type item = { 
  rollback   : int;
  kind       : Outline_utils.kind;
  tokens     : token list;
  exns       : exn list;
}

type sync = item History.sync
type t = item History.t 

val location : t -> Location.t
val seek_before : int * int -> t -> t
val seek_offset : int -> t -> t

val parse_step : ?rollback:int -> ?bufpos:Lexing.position ref -> ?exns:exn list ->
  token History.t -> Lexing.lexbuf -> token History.t * item option

val parse : ?rollback:int -> ?bufpos:Lexing.position ref ->
  token History.t -> t -> Lexing.lexbuf -> token History.t * t

val exns : t -> exn list
