(**************************************************************************)
(*                                                                        *)
(*                                 VSCoq                                  *)
(*                                                                        *)
(*                   Copyright INRIA and contributors                     *)
(*       (see version control and README file for authors & dates)        *)
(*                                                                        *)
(**************************************************************************)
(*                                                                        *)
(*   This file is distributed under the terms of the MIT License.         *)
(*   See LICENSE file.                                                    *)
(*                                                                        *)
(**************************************************************************)
open CErrors
open Names
open Util
open Pp
open Printer
open Search
open Vernacexpr
open Lsp.LspData

let query_results_queue = Queue.create ()

let query_feedback : notification Sel.event =
  Sel.on_queue query_results_queue (fun x -> QueryResultNotification x)
  |> Sel.uncancellable

let global_module qid =
  try Nametab.full_name_module qid
  with Not_found ->
    user_err ?loc:qid.CAst.loc
     (str "Module/Section " ++ Ppconstr.pr_qualid qid ++ str " not found.")

let interp_search_restriction = function
  | SearchOutside l -> (List.map global_module l, true)
  | SearchInside l -> (List.map global_module l, false)

let kind_searcher = Decls.(function
  (* Kinds referring to the keyword introducing the object *)
  | IsAssumption _
  | IsDefinition (Definition | Example | Fixpoint | CoFixpoint | Method | StructureComponent | Let)
  | IsProof _
  | IsPrimitive as k -> Inl k
  (* Kinds referring to the status of the object *)
  | IsDefinition (Coercion | SubClass | IdentityCoercion as k') ->
    let coercions = Coercionops.coercions () in
    Inr (fun gr -> List.exists (fun c -> GlobRef.equal c.Coercionops.coe_value gr &&
                                      (k' <> SubClass && k' <> IdentityCoercion || c.Coercionops.coe_is_identity)) coercions)
  | IsDefinition CanonicalStructure ->
    let canonproj = Structures.CSTable.entries () in
    Inr (fun gr -> List.exists (fun c -> GlobRef.equal c.Structures.CSTable.solution gr) canonproj)
  | IsDefinition Scheme ->
    let schemes = DeclareScheme.all_schemes () in
    Inr (fun gr -> Indset.exists (fun c -> GlobRef.equal (GlobRef.IndRef c) gr) schemes)
  | IsDefinition Instance ->
    let instances = Typeclasses.all_instances () in
    Inr (fun gr -> List.exists (fun c -> GlobRef.equal c.Typeclasses.is_impl gr) instances))

let interp_search_item env sigma =
  function
  | SearchSubPattern ((where,head),pat) ->
      let expected_type = Pretyping.(if head then IsType else WithoutTypeConstraint) in
      let pat =
        try Constrintern.interp_constr_pattern env sigma ~expected_type pat
        with e when CErrors.noncritical e ->
          (* We cannot ensure (yet?) that a typable pattern will
             actually be typed, consider e.g. (forall A, A -> A /\ A)
             which fails, not seeing that A can be Prop; so we use an
             untyped pattern as a fallback (i.e w/o no insertion of
             coercions, no compilation of pattern-matching) *)
          snd (Constrintern.intern_constr_pattern env sigma ~as_type:head pat) in
      GlobSearchSubPattern (where,head,pat)
  | SearchString ((Anywhere,false),s,None)
      when Id.is_valid_ident_part s && String.equal (String.drop_simple_quotes s) s ->
      GlobSearchString s
  | SearchString ((where,head),s,sc) ->
      (try
        let ref =
          Notation.interp_notation_as_global_reference
            ~head:false (fun _ -> true) s sc in
        GlobSearchSubPattern (where,head,Pattern.PRef ref)
      with UserError _ ->
        user_err
          (str "Unable to interpret " ++ quote (str s) ++ str " as a reference."))
  | SearchKind k ->
     match kind_searcher k with
     | Inl k -> GlobSearchKind k
     | Inr f -> GlobSearchFilter f

let rec interp_search_request env sigma = function
  | b, SearchLiteral i -> b, GlobSearchLiteral (interp_search_item env sigma i)
  | b, SearchDisjConj l -> b, GlobSearchDisjConj (List.map (List.map (interp_search_request env sigma)) l)

let interp_search ~id env sigma s r =
  let r = interp_search_restriction r in
  let get_pattern c = snd (Constrintern.intern_constr_pattern env sigma c) in
  let warnlist = ref [] in
  let pr_search ref kind env c =
    let pr = pr_global ref in
    let open Impargs in
    let impls = implicits_of_global ref in
    let impargs = select_stronger_impargs impls in
    let impargs = List.map binding_kind_of_status impargs in
    if List.length impls > 1 ||
      List.exists Glob_term.(function Explicit -> false | MaxImplicit | NonMaxImplicit -> true)
        (List.skipn_at_least (Termops.nb_prod_modulo_zeta Evd.(from_env env) (EConstr.of_constr c)) impargs)
       then warnlist := pr :: !warnlist;
    let pc = pr_ltype_env env Evd.(from_env env) ~impargs c in
    let name = Pp.string_of_ppcmds pr in
    let statement = Pp.string_of_ppcmds pc in
    Queue.push { id; name; statement } query_results_queue
  in
  (match s with
  | SearchPattern c ->
      (Search.search_pattern env sigma (get_pattern c) r |> Search.prioritize_search) pr_search
  | SearchRewrite c ->
      (Search.search_rewrite env sigma (get_pattern c) r |> Search.prioritize_search) pr_search
  | Search sl ->
      (Search.search env sigma (List.map (interp_search_request env Evd.(from_env env)) sl) r |>
       Search.prioritize_search) pr_search);
  [query_feedback]
