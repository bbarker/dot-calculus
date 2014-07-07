
Require Export List.
Require Export Arith.Peano_dec.
Require Export Program.Syntax. (* eg for multiple exists tactic *)
Set Implicit Arguments.


(* List notation with head on the right *)
Notation "E '&' F" := (app F E) (at level 31, left associativity).
Notation " E  ;; x " := (cons x E) (at level 29, left associativity).

(* Testing the list notations: *)
Module ListNotationTests.
Definition head(l: list nat) := match l with
| nil => 777
| cons x xs => x
end.
Eval compute in nil ;; 1 ;; 2 ;; 3.
Eval compute in head (nil ;; 1 ;; 2 ;; 3).
Eval compute in head ((nil ;; 1 ;; 2 ;; 3) & (nil ;; 4 ;; 5)).
Eval compute in nil ;; 1 ;; 2 & nil ;; 3 ;; 4 & nil ;; 5 ;; 6. 
(* Unset Printing Notations. (* or by CoqIDE menu *) *)
Check (nil ;; 0 & nil ;; 0 ;; 0 & nil ;; 0 ;; 0 ;; 0).
End ListNotationTests.

Definition var := nat.

(* If it's clear whether a field or method is meant, we use nat, if not, we use label: *)
Inductive label: Type :=
| label_fld: nat -> label
| label_mtd: nat -> label.

Lemma eq_label_dec: forall l1 l2: label, {l1 = l2} + {l1 <> l2}.
Proof.
  intros. 
  destruct l1 as [n1|n1]; destruct l2 as [n2|n2]; 
  destruct (eq_nat_dec n1 n2); solve [
     (left; f_equal; assumption) |
     (right; unfold not; intro H; inversion H; rewrite H1 in n; apply n; reflexivity)].
Qed.

Inductive avar : Type :=
  | avar_b : nat -> avar  (* bound var (de Bruijn index) *)
  | avar_f : var -> avar. (* free var ("name"), refers to tenv or venv *)

Inductive typ : Type :=
  | typ_rcd  : list ndec -> typ (* record type *)
with ndec : Type := (* named declaration *)
  | ndec_fld : nat -> typ -> ndec
  | ndec_mtd : nat -> typ -> typ -> ndec.
Inductive dec : Type := (* declaration without name *)
  | dec_fld  : typ -> dec
  | dec_mtd  : typ -> typ -> dec.

Inductive trm : Type :=
  | trm_var  : avar -> trm
  | trm_new  : list nini -> trm -> trm
  | trm_sel  : trm -> nat -> trm
  | trm_call : trm -> nat -> trm -> trm
with nini : Type :=
  | nini_fld : nat -> avar -> nini (* cannot have term here, need to assign first *)
  | nini_mtd : nat -> typ -> trm -> nini.
Inductive ini : Type :=
  | ini_fld : avar -> ini
  | ini_mtd : typ -> trm -> ini.

(* Syntactic sugar *)
Definition trm_fun(T: typ)(body: trm) := trm_new (nil ;; nini_mtd 0 T body)
                                                 (trm_var (avar_b 0)).
Definition trm_app(func arg: trm) := trm_call func 0 arg.
Definition trm_let(T: typ)(rhs body: trm) := trm_app (trm_fun T body) rhs.
Definition trm_upcast(T: typ)(e: trm) := trm_app (trm_fun T (trm_var (avar_b 0))) e.
Definition typ_arrow(T1 T2: typ) := typ_rcd (nil ;; ndec_mtd 0 T1 T2).

(* ... opening ...
   replaces in some syntax a bound variable with dangling index (k) by a free variable x
*)

Fixpoint open_rec_avar (k: nat) (u: var) (a: avar) { struct a } : avar :=
  match a with
  | avar_b i => if eq_nat_dec k i then avar_f u else avar_b i
  | avar_f x => avar_f x
  end.

(* The only binders are trm_new and (n)ini_mtd, which cannot be inside a typ or
   inside a dec, so we don't need opening for typ and dec *)

Fixpoint open_rec_trm (k: nat) (u: var) (t: trm) { struct t } : trm :=
  match t with
  | trm_var  a     => trm_var (open_rec_avar k u a)
  | trm_new  is e  => trm_new (map (open_rec_nini (S k) u) is) (open_rec_trm (S k) u e)
  | trm_sel  e n   => trm_sel (open_rec_trm k u e) n
  | trm_call o m a => trm_call (open_rec_trm k u o) m (open_rec_trm k u a)
  end
with open_rec_nini (k: nat) (u: var) (i: nini) { struct i } : nini :=
  match i with
  | nini_fld n a   => nini_fld n (open_rec_avar k u a)
  | nini_mtd n T e => nini_mtd n T (open_rec_trm (S k) u e)
  end.

Definition open_avar u a := open_rec_avar 0 u a.
Definition open_trm  u e := open_rec_trm  0 u e.
Definition open_nini u i := open_rec_nini 0 u i.

Inductive fvar : avar -> Prop :=
  | fvar_f : forall x,
      fvar (avar_f x).

(* 
Environment requirements:
   * Want to use the same definitions and lemmas for
     - decs
     - inis
     - tenv
     - venv
   * Intersection of two dec lists must be total, i.e. if we have
     (m: T -> U) in ds1 and (m: T) in ds2,
     then (ds1 /\ ds2) must be defined and contain both declarations.
     This requires that method labels be distinct from field labels, or that
     the environment data structure allows two decs with the same name if they
     are of a different kind.
   * Want to have generic dec (dec_typ, dec_mtd, dec_fld), and treat dec lists as
     as mappings from dec name to dec, instead of having three separate lists.
Hopefully, this module system approach satisfies the requirements.
*)

Module Type EnvParams.
Parameter K : Type.
Parameter V : Type.
Parameter B : Type.
Parameter key: B -> K.
Parameter value: B -> V. 
Axiom eq_key_dec: forall k1 k2: K, {k1 = k2} + {k1 <> k2}.
Axiom key_val_eq_eq: forall b1 b2, key b1 = key b2 -> value b1 = value b2 -> b1 = b2.
End EnvParams.

Ltac inv H := inversion H; clear H; subst.

(* General environment *)
Module Env (params: EnvParams).
Import params.
Definition key := key.
Definition value := value.
Definition t := list B.
Definition map: (B -> B) -> t -> t := (@List.map B B).
Fixpoint get(k: K)(E: t): option V := match E with
  | nil => None
  | bs ;; b => if eq_key_dec k (key b) then Some (value b) else get k bs
  end.
Definition binds(k: K)(v: V)(E: t): Prop := (get k E = Some v).
Definition unbound(k: K)(E: t): Prop := (get k E = None).
Lemma binds_empty_inv : forall k v, binds k v nil -> False.
Proof.
  intros. unfold binds, get in H. discriminate H.
Qed.
Lemma map_head: forall (E: t) (b: B) (f: B -> B), map f (E ;; b) = (map f E) ;; (f b).
Proof.
  intros. destruct E as [|a E].
  + unfold map. unfold List.map. reflexivity.
  + unfold map. remember (E ;; a) as L. unfold List.map. reflexivity.
Qed.
Lemma concat_cons_assoc: forall (E1: t) (E2: t) (b: B), E1 & (E2 ;; b) = (E1 & E2) ;; b.
Proof.
  intros. simpl. reflexivity.
Qed.
Lemma binds_unbound_head_inv: forall E b, unbound (key b) (E ;; b) -> False.
Proof.
  intros. unfold unbound in H. simpl in H. destruct (eq_key_dec (key b) (key b)).
  + discriminate H.
  + apply n. reflexivity.
Qed.
Lemma unbound_cons_inv: forall E k b, unbound k (E ;; b) -> unbound k E.
Proof.
  intros. unfold unbound in H. unfold get in H. destruct (eq_key_dec k (key b)).
  + inversion H.
  + fold get in H. unfold unbound. assumption.
Qed.
Lemma binds_push_eq_inv: forall E a b,
  binds (key a) (value b) (E ;; a) -> value a = value b.
Proof.
  intros. unfold binds, get in H. destruct (eq_key_dec (key a) (key a)).
  + inversion H. reflexivity.
  + contradiction n. reflexivity.
Qed.
Lemma binds_binding_inv: forall k v E, binds k v E -> exists b, key b = k /\ value b = v.
Proof.
  intros k v E. induction E; intros.
  + exfalso. apply (@binds_empty_inv _ _ H).
  + unfold binds, get in H. fold get in H. destruct (eq_key_dec k (key a)).
    - inversion H. rewrite -> H1. exists a. symmetry in e. split; assumption.
    - unfold binds in IHE. apply IHE. assumption.
Qed.
Lemma binds_map: forall b (f : B -> B) E,
  (forall a, key (f a) = key a) ->
  binds (key b) (value b) E -> 
  binds (key (f b)) (value (f b)) (map f E).
Proof.
  intros. induction E.
  + exfalso. apply (@binds_empty_inv _ _ H0).
  + simpl. unfold binds, get. rewrite -> (H a). rewrite -> (H b).
    unfold binds, get in H0. destruct (eq_key_dec (key b) (key a)).
    - inv H0. do 3 f_equal. symmetry in e. apply key_val_eq_eq; assumption.
    - fold get. fold get in H0. unfold binds in IHE. 
      rewrite -> (H b) in IHE. apply (IHE H0).
Qed.
Lemma unbound_map: forall k (f : B -> B) E,
  (forall a, key (f a) = key a) ->
  unbound k E -> 
  unbound k (map f E).
Proof.
  intros. induction E.
  + simpl. assumption.
  + simpl. unfold unbound, get. fold get. rewrite -> (H a).
    destruct (eq_key_dec k (key a)).
    - exfalso. rewrite -> e in H0. apply (@binds_unbound_head_inv E a H0).
    - unfold unbound in IHE. apply IHE. apply unbound_cons_inv in H0.
      unfold unbound in H0. assumption.
Qed.
Lemma binds_concat_right : forall k v E1 E2,
  binds k v E2 ->
  binds k v (E1 & E2).
Proof.
  intros. induction E2.
  + exfalso. apply (@binds_empty_inv _ _ H).
  + rewrite -> concat_cons_assoc. unfold binds, get. unfold binds, get in H.
    destruct (eq_key_dec k (key a)).
    - assumption.
    - fold get in *. unfold binds in IHE2. apply IHE2. assumption.
Qed.
Lemma binds_concat_left_inv : forall k v E1 E2,
  binds k v (E1 & E2) ->
  unbound k E2 ->
  binds k v E1.
Proof.
  intros. induction E2.
  + simpl in H. assumption.
  + rewrite -> concat_cons_assoc in H. unfold binds, get in H. fold get in H.
    destruct (eq_key_dec k (key a)).
    - exfalso. rewrite -> e in H0. apply (@binds_unbound_head_inv E2 a H0).
    - apply IHE2. unfold binds. assumption. apply (@unbound_cons_inv E2 k a H0).
Qed.
Lemma binds_concat_left : forall k v E1 E2,
  binds k v E1 ->
  unbound k E2 ->
  binds k v (E1 & E2).
Proof.
  intros. induction E2.
  + simpl. assumption.
  + rewrite -> concat_cons_assoc. unfold binds, get. fold get.
    destruct (eq_key_dec k (key a)).
    - exfalso. rewrite -> e in H0. apply (@binds_unbound_head_inv E2 a H0).
    - unfold binds in IHE2. apply IHE2. apply (@unbound_cons_inv E2 k a H0).
Qed.
Lemma binds_unbound_inv : forall k v E,
  binds k v E -> unbound k E -> False.
Proof.
  intros. induction E.
  + inv H.
  + unfold binds, get in H. fold get in H. destruct (eq_key_dec k (key a)).
    - subst. apply (binds_unbound_head_inv H0).
    - apply IHE. unfold binds. assumption. apply (unbound_cons_inv H0).
Qed.
Lemma binds_unique : forall k v1 v2 E,
  binds k v1 E -> binds k v2 E -> v1 = v2.
Proof.
  intros. induction E.
  + inv H.
  + unfold binds, get in *. fold get in *. destruct (eq_key_dec k (key a)).
    - inv H. inv H0. reflexivity.
    - inv H. inv H0. apply IHE; assumption.
Qed.
End Env.

(* Module decs: For lists of declarations: [list ndec] or [label => dec] *)
Module decsParams <: EnvParams.
Definition K := label.
Definition V := dec.
Definition B := ndec.
Definition key(d: ndec): label := match d with
| ndec_fld n T => label_fld n
| ndec_mtd n T U => label_mtd n
end.
Definition value(d: ndec): dec := match d with
| ndec_fld n T => dec_fld T
| ndec_mtd n T U => dec_mtd T U
end.
Definition eq_key_dec := eq_label_dec.
Lemma key_val_eq_eq: forall b1 b2, key b1 = key b2 -> value b1 = value b2 -> b1 = b2.
Proof.
  intros. destruct b1, b2.
  + inv H. inv H0. reflexivity.
  + inv H.
  + inv H.
  + inv H. inv H0. reflexivity.
Qed.
End decsParams.
Module decs := Env(decsParams).

(* Module inis: For lists of initialisations: [list nini] or [label => ini] *)
Module inisParams <: EnvParams.
Definition K := label.
Definition V := ini.
Definition B := nini.
Definition key(i: nini): label := match i with
| nini_fld n T => label_fld n
| nini_mtd n T e => label_mtd n
end.
Definition value(i: nini): ini := match i with
| nini_fld n T => ini_fld T
| nini_mtd n T e => ini_mtd T e
end.
Definition eq_key_dec := eq_label_dec.
Lemma key_val_eq_eq: forall b1 b2, key b1 = key b2 -> value b1 = value b2 -> b1 = b2.
Proof.
  intros. destruct b1, b2.
  + inv H. inv H0. reflexivity.
  + inv H.
  + inv H.
  + inv H. inv H0. reflexivity.
Qed.
End inisParams.
Module inis := Env(inisParams).

(* Module tenv: For type environments: [var => typ] *)
Module tenvParams <: EnvParams.
Definition K := var.
Definition V := typ.
Definition B := (var * typ)%type.
Definition key := @fst var typ.
Definition value := @snd var typ.
Definition eq_key_dec := eq_nat_dec.
Lemma key_val_eq_eq: forall b1 b2, key b1 = key b2 -> value b1 = value b2 -> b1 = b2.
Proof.
  intros. destruct b1, b2. unfold key, fst, value, snd in *. subst. reflexivity.
Qed.
End tenvParams.
Module tenv := Env(tenvParams).

(* Module venv: For value environments: [var => inis] *)
Module venvParams <: EnvParams.
Definition K := var.
Definition V := inis.t.
Definition B := (var * inis.t)%type.
Definition key := @fst var inis.t.
Definition value := @snd var inis.t.
Definition eq_key_dec := eq_nat_dec.
Lemma key_val_eq_eq: forall b1 b2, key b1 = key b2 -> value b1 = value b2 -> b1 = b2.
Proof.
  intros. destruct b1, b2. unfold key, fst, value, snd in *. subst. reflexivity.
Qed.
End venvParams.
Module venv := Env(venvParams).

Module Type IntersectionPreview.

(* Will be part of syntax: *)
Parameter t_and: typ -> typ -> typ.
Parameter t_or:  typ -> typ -> typ.

(* Left as an exercise for the reader ;-) We define intersection by the spec below. *)
Parameter intersect: decs.t -> decs.t -> decs.t.

Axiom intersect_spec_1: forall l d ds1 ds2,
  decs.binds   l d ds1 ->
  decs.unbound l ds2 ->
  decs.binds   l d (intersect ds1 ds2).

Axiom intersect_spec_2: forall l d ds1 ds2,
  decs.unbound l ds1 ->
  decs.binds   l d ds2 ->
  decs.binds   l d (intersect ds1 ds2).

Axiom intersect_spec_12_fld: forall n T1 T2 ds1 ds2,
  decs.binds (label_fld n) (dec_fld T1) ds1 ->
  decs.binds (label_fld n) (dec_fld T2) ds2 ->
  decs.binds (label_fld n) (dec_fld (t_and T1 T2)) (intersect ds1 ds2).

Axiom intersect_spec_12_mtd: forall n S1 T1 S2 T2 ds1 ds2,
  decs.binds (label_mtd n) (dec_mtd S1 T1) ds1 ->
  decs.binds (label_mtd n) (dec_mtd S2 T2) ds2 ->
  decs.binds (label_mtd n) (dec_mtd (t_or S1 S2) (t_and T1 T2)) (intersect ds1 ds2).

End IntersectionPreview.

(* Exercise: Give any implementation of `intersect`, and prove that it satisfies
   the specification. Happy hacking! ;-) *)
Module IntersectionPreviewImpl <: IntersectionPreview.

(* Will be part of syntax: *)
Parameter t_and: typ -> typ -> typ.
Parameter t_or:  typ -> typ -> typ.

Fixpoint get_fld(n: nat)(ds: decs.t): option typ := match ds with
  | nil => None
  | tail ;; d => match d with
      | ndec_fld m T => if eq_nat_dec n m then Some T else get_fld n tail
      | _ => get_fld n tail
      end
  end.
(*
Lemma get_fld_spec: forall n ds, decs.get (label_fld n) ds = dec_fld (get_fld n ds).
Proof.
*)

Fixpoint refine_dec(d1: ndec)(ds2: decs.t): ndec := match ds2 with
| nil => d1
| tail2 ;; d2 => match d1, d2 with
    | ndec_fld n1 T1   , ndec_fld n2 T2    => if eq_nat_dec n1 n2
                                              then ndec_fld n1 (t_and T1 T2) 
                                              else refine_dec d1 tail2
    | ndec_mtd n1 T1 S1, ndec_mtd n2 T2 S2 => if eq_nat_dec n1 n2
                                              then ndec_mtd n1 (t_or T1 T2) (t_and S1 S2) 
                                              else refine_dec d1 tail2
    | _, _ => refine_dec d1 tail2
    end
end.

Ltac destruct_matchee :=
  match goal with
  | [ Hm: match ?e1 with _ => _ end = _ |- _ ]  => 
      remember e1 as mExpr; destruct mExpr
  | [ Hm: if ?e1 then _ else _ = _ |- _ ]  => 
      remember e1 as mExpr; destruct mExpr
  end.

Lemma refine_dec_spec_fld: forall ds2 n T1 T2,
  decs.binds (label_fld n) (dec_fld T2) ds2 ->
  (refine_dec (ndec_fld n T1) ds2) = (ndec_fld n (t_and T1 T2)).
Proof. 
  intro ds2. induction ds2; intros.
  + apply decs.binds_empty_inv in H. contradiction H.
  + unfold decs.binds in H. unfold decs.get in H. unfold decs.key, decsParams.key in H.
    destruct_matchee.
    - inv H. unfold decs.value, decsParams.value in H1. destruct a eqn: Heqa.
      * inv H1. inversion e. subst. simpl. destruct (eq_nat_dec n0 n0). reflexivity.
        contradiction n. reflexivity.
      * inv H1.
    - simpl. destruct a eqn: Heqa. 
      * assert (Hnn: n <> n1). unfold not in *. intro. apply n0. f_equal. assumption.
        destruct (eq_nat_dec n n1). contradiction Hnn.
        apply IHds2. unfold decs.binds, decs.get. unfold decs.key, decsParams.key.
        assumption.
      * apply IHds2. unfold decs.binds, decs.get. unfold decs.key, decsParams.key.
        assumption.
Qed.

Lemma refine_dec_spec_mtd: forall ds2 n T1 S1 T2 S2,
  decs.binds (label_mtd n) (dec_mtd T2 S2) ds2 ->
  (refine_dec (ndec_mtd n T1 S1) ds2) = (ndec_mtd n (t_or T1 T2) (t_and S1 S2)).
Proof. 
  intro ds2. induction ds2; intros.
  + apply decs.binds_empty_inv in H. contradiction H.
  + unfold decs.binds in H. unfold decs.get in H. unfold decs.key, decsParams.key in H.
    destruct_matchee.
    - inv H. unfold decs.value, decsParams.value in H1. destruct a eqn: Heqa.
      * inv H1.
      * inv H1. inversion e. subst. simpl. destruct (eq_nat_dec n0 n0). reflexivity.
        contradiction n. reflexivity.
    - simpl. destruct a eqn: Heqa. 
      * apply IHds2. unfold decs.binds, decs.get. unfold decs.key, decsParams.key.
        assumption.
      * assert (Hnn: n <> n1). unfold not in *. intro. apply n0. f_equal. assumption.
        destruct (eq_nat_dec n n1). contradiction Hnn.
        apply IHds2. unfold decs.binds, decs.get. unfold decs.key, decsParams.key.
        assumption.
Qed.

Lemma refine_dec_spec_label: forall d1 ds2, decs.key d1 = decs.key (refine_dec d1 ds2).
Proof.
  intros.
  induction ds2.
  + simpl. reflexivity.
  + unfold decs.key, decsParams.key. unfold refine_dec. destruct a; destruct d1.
    - destruct (eq_nat_dec n0 n).
      * simpl. reflexivity.
      * fold refine_dec. unfold decs.key, decsParams.key in IHds2.
        rewrite <- IHds2. reflexivity.
    - fold refine_dec. unfold decs.key, decsParams.key in IHds2.
        rewrite <- IHds2. reflexivity.
    - fold refine_dec. unfold decs.key, decsParams.key in IHds2.
        rewrite <- IHds2. reflexivity.
    - destruct (eq_nat_dec n0 n).
      * simpl. reflexivity.
      * fold refine_dec. unfold decs.key, decsParams.key in IHds2.
        rewrite <- IHds2. reflexivity.
Qed.

Lemma refine_dec_spec_unbound: forall d1 ds2, 
  decs.unbound (decs.key d1) ds2 ->
  decs.value (refine_dec d1 ds2) = decs.value d1.
Proof.
  intros.
  induction ds2.
  + simpl. reflexivity.
  + unfold decs.key, decsParams.key. unfold refine_dec. destruct a; destruct d1.
    - destruct (eq_nat_dec n0 n) eqn: Hn0ndec.
      * subst. 
        assert (Hkeq: (decs.key (ndec_fld n t0)) = (decs.key (ndec_fld n t)))
          by reflexivity.
        rewrite -> Hkeq in H.
        exfalso. apply (decs.binds_unbound_head_inv H).
      * fold refine_dec. apply IHds2.
        inv H. unfold decsParams.eq_key_dec in H1. 
        destruct (eq_label_dec (label_fld n0) (label_fld n)).
        { inv e. contradiction n1. reflexivity. }
        { unfold decs.unbound. unfold decs.key, decsParams.key. assumption. }
    - fold refine_dec. unfold decs.key, decsParams.key in *.
      apply decs.unbound_cons_inv in H. apply (IHds2 H).
    - fold refine_dec. unfold decs.key, decsParams.key in *.
      apply decs.unbound_cons_inv in H. apply (IHds2 H).
    - destruct (eq_nat_dec n0 n) eqn: Hn0ndec.
      * subst. 
        assert (Hkeq: (decs.key (ndec_mtd n t1 t2)) = (decs.key (ndec_mtd n t t0)))
          by reflexivity.
        rewrite -> Hkeq in H.
        exfalso. apply (decs.binds_unbound_head_inv H).
      * fold refine_dec. apply IHds2.
        inv H. unfold decsParams.eq_key_dec in H1. 
        destruct (eq_label_dec (label_mtd n0) (label_mtd n)).
        { inv e. contradiction n1. reflexivity. }
        { unfold decs.unbound. unfold decs.key, decsParams.key. assumption. }
Qed.

Definition refine_decs(ds1: decs.t)(ds2: decs.t): decs.t := 
  decs.map (fun d1 => refine_dec d1 ds2) ds1.

Lemma refine_decs_spec_unbound: forall l d ds1 ds2,
  decs.binds   l d ds1 ->
  decs.unbound l ds2 ->
  decs.binds   l d (refine_decs ds1 ds2).
Proof.
  intros. unfold refine_decs. unfold decs.map.  
  assert (Hex: exists nd, decs.key nd = l /\ decs.value nd = d).
    apply (@decs.binds_binding_inv l d ds1 H).
  destruct Hex as [nd [Hl Hd]]. subst.
  remember (fun d1 : decsParams.B => refine_dec d1 ds2) as f.
  assert (Hk: (decs.key nd) = decs.key (f nd)).
    subst. apply (refine_dec_spec_label nd ds2).
  rewrite -> Hk.
  assert (Hv: (decs.value nd) = decs.value (f nd)).
    subst. symmetry. apply (refine_dec_spec_unbound _ H0).
  rewrite -> Hv.
  apply decs.binds_map. 
    intro. rewrite -> Heqf. symmetry. apply refine_dec_spec_label.
    assumption.
Qed.

Lemma refine_decs_spec_unbound_preserved: forall l ds1 ds2,
  decs.unbound l ds1 ->
  decs.unbound l (refine_decs ds1 ds2).
Proof.
  intros. unfold refine_decs. remember (fun d1 : decsParams.B => refine_dec d1 ds2) as f.
  refine (@decs.unbound_map l f ds1 _ H).
  subst. intro. symmetry. apply refine_dec_spec_label.
Qed.

Lemma refine_decs_spec_fld: forall n ds1 ds2 T1 T2,
  decs.binds (label_fld n) (dec_fld T1) ds1 ->
  decs.binds (label_fld n) (dec_fld T2) ds2 ->
  decs.binds (label_fld n) (dec_fld (t_and T1 T2)) (refine_decs ds1 ds2).
Proof.
  intros n ds1 ds2 T1 T2 H. induction ds1; intros.
  + apply decs.binds_empty_inv in H. contradiction H.
  + unfold decs.binds, decs.get in H. destruct a eqn: Heqa.
    - fold decs.get in H. unfold decs.key, decsParams.key in H.
      destruct (decsParams.eq_key_dec (label_fld n) (label_fld n0)).
      * inv H. inv e.
        unfold decs.binds, decs.get. simpl. fold decs.get. 
        rewrite <- (@refine_dec_spec_label (ndec_fld n0 T1) ds2).
        unfold decs.key, decsParams.key.
        destruct (decsParams.eq_key_dec (label_fld n0) (label_fld n0)). {
          f_equal. rewrite -> (@refine_dec_spec_fld ds2 n0 T1 T2 H0).
          simpl. reflexivity. 
        } { contradiction n. reflexivity. }
      * assert (Hnn: n <> n0). unfold not in *. intro. apply n1. f_equal. assumption.
        unfold decs.binds, decs.get. simpl. fold decs.get. 
        rewrite <- (@refine_dec_spec_label (ndec_fld n0 t) ds2).
        unfold decs.key, decsParams.key.
        destruct (decsParams.eq_key_dec (label_fld n) (label_fld n0)). {
          inv e. contradiction Hnn. reflexivity.
        } {
          unfold decs.binds in *. apply IHds1; assumption.
        }
    - fold decs.get in H. unfold decs.key, decsParams.key in H.
      destruct (decsParams.eq_key_dec (label_fld n) (label_fld n0)).
      * inv H. inv e.
        unfold decs.binds, decs.get. simpl. fold decs.get.
        rewrite <- (@refine_dec_spec_label (ndec_mtd n0 t t0) ds2).
        unfold decs.key, decsParams.key.
        destruct (decsParams.eq_key_dec (label_fld n0) (label_mtd n0)). {
          inv H2.
        } {
          unfold decs.binds in *. apply IHds1; assumption.
        }
      * assert (Hnn: n <> n0). unfold not in *. intro. apply n1. f_equal. assumption.
        unfold decs.binds, decs.get. simpl. fold decs.get. 
        rewrite <- (@refine_dec_spec_label (ndec_mtd n0 t t0) ds2).
        unfold decs.key, decsParams.key.
        destruct (decsParams.eq_key_dec (label_fld n) (label_fld n0)). {
          inv e. contradiction Hnn. reflexivity.
        } {
          destruct (decsParams.eq_key_dec (label_fld n) (label_mtd n0)).
          + inv e.
          + unfold decs.binds in *. apply IHds1; assumption.
        }
Qed.

Lemma refine_decs_spec_mtd: forall n ds1 ds2 T1 S1 T2 S2,
  decs.binds (label_mtd n) (dec_mtd T1 S1) ds1 ->
  decs.binds (label_mtd n) (dec_mtd T2 S2) ds2 ->
  decs.binds (label_mtd n) (dec_mtd (t_or T1 T2) (t_and S1 S2)) (refine_decs ds1 ds2).
Proof.
  intros n ds1 ds2 T1 S1 T2 S2 H. induction ds1; intros.
  + apply decs.binds_empty_inv in H. contradiction H.
  + unfold decs.binds, decs.get in H. destruct a eqn: Heqa.
    - fold decs.get in H. unfold decs.key, decsParams.key in H.
      destruct (decsParams.eq_key_dec (label_mtd n) (label_mtd n0)).
      * inv H. inv e.
        unfold decs.binds, decs.get. simpl. fold decs.get.
        rewrite <- (@refine_dec_spec_label (ndec_fld n0 t) ds2).
        unfold decs.key, decsParams.key.
        destruct (decsParams.eq_key_dec (label_mtd n0) (label_fld n0)). {
          inv H2.
        } {
          unfold decs.binds in *. apply IHds1; assumption.
        }
      * assert (Hnn: n <> n0). unfold not in *. intro. apply n1. f_equal. assumption.
        unfold decs.binds, decs.get. simpl. fold decs.get. 
        rewrite <- (@refine_dec_spec_label (ndec_fld n0 t) ds2).
        unfold decs.key, decsParams.key.
        destruct (decsParams.eq_key_dec (label_mtd n) (label_mtd n0)). {
          inv e. contradiction Hnn. reflexivity.
        } {
          destruct (decsParams.eq_key_dec (label_mtd n) (label_fld n0)).
          + inv e.
          + unfold decs.binds in *. apply IHds1; assumption.
        }
    - fold decs.get in H. unfold decs.key, decsParams.key in H.
      destruct (decsParams.eq_key_dec (label_mtd n) (label_mtd n0)).
      * inv H. inv e.
        unfold decs.binds, decs.get. simpl. fold decs.get. 
        rewrite <- (@refine_dec_spec_label (ndec_mtd n0 T1 S1) ds2).
        unfold decs.key, decsParams.key.
        destruct (decsParams.eq_key_dec (label_mtd n0) (label_mtd n0)). {
          f_equal. rewrite -> (@refine_dec_spec_mtd ds2 n0 T1 S1 T2 S2 H0).
          simpl. reflexivity. 
        } { contradiction n. reflexivity. }
      * assert (Hnn: n <> n0). unfold not in *. intro. apply n1. f_equal. assumption.
        unfold decs.binds, decs.get. simpl. fold decs.get. 
        rewrite <- (@refine_dec_spec_label (ndec_mtd n0 t t0) ds2).
        unfold decs.key, decsParams.key.
        destruct (decsParams.eq_key_dec (label_mtd n) (label_mtd n0)). {
          inv e. contradiction Hnn. reflexivity.
        } {
          unfold decs.binds in *. apply IHds1; assumption.
        } 
Qed.


(* refined decs shadow the outdated decs of ds2 *)
Definition intersect(ds1 ds2: decs.t): decs.t := ds2 & (refine_decs ds1 ds2).

Lemma intersect_spec_1: forall l d ds1 ds2,
  decs.binds   l d ds1 ->
  decs.unbound l ds2 ->
  decs.binds   l d (intersect ds1 ds2).
Proof.
  intros. unfold intersect. apply decs.binds_concat_right.
  apply refine_decs_spec_unbound; assumption.
Qed.

Lemma intersect_spec_2: forall l d ds1 ds2,
  decs.unbound l ds1 ->
  decs.binds   l d ds2 ->
  decs.binds   l d (intersect ds1 ds2).
Proof.
  intros. unfold intersect.
  apply (@decs.binds_concat_left l d ds2 (refine_decs ds1 ds2) H0). 
  apply (@refine_decs_spec_unbound_preserved l ds1 ds2 H). 
Qed.

Lemma intersect_spec_12_fld: forall n T1 T2 ds1 ds2,
  decs.binds (label_fld n) (dec_fld T1) ds1 ->
  decs.binds (label_fld n) (dec_fld T2) ds2 ->
  decs.binds (label_fld n) (dec_fld (t_and T1 T2)) (intersect ds1 ds2).
Proof.
  intros. unfold intersect. apply decs.binds_concat_right.
  apply refine_decs_spec_fld; assumption.
Qed.

Lemma intersect_spec_12_mtd: forall n S1 T1 S2 T2 ds1 ds2,
  decs.binds (label_mtd n) (dec_mtd S1 T1) ds1 ->
  decs.binds (label_mtd n) (dec_mtd S2 T2) ds2 ->
  decs.binds (label_mtd n) (dec_mtd (t_or S1 S2) (t_and T1 T2)) (intersect ds1 ds2).
Proof.
  intros. unfold intersect. apply decs.binds_concat_right.
  apply refine_decs_spec_mtd; assumption.
Qed.

End IntersectionPreviewImpl.


(** Operational Semantics **)
(* Note: Terms given by user are closed, so they only contain avar_b, no avar_f.
   Whenever we introduce a new avar_f (only happens in red_new), we choose one
   which is not in the store, so we never have name clashes. *) 
Inductive red : venv.t -> trm -> venv.t -> trm -> Prop :=
  (* computation rules *)
  | red_call : forall (s: venv.t) (x y: var) (m: nat) (T: typ) (is: inis.t) (body: trm),
      venv.binds x is s ->
      inis.binds (label_mtd m) (ini_mtd T body) is ->
      red s (trm_call (trm_var (avar_f x)) m (trm_var (avar_f y))) 
          s (open_trm y body)
  | red_sel : forall (s: venv.t) (x: var) (y: avar) (l: nat) (is: inis.t),
      venv.binds x is s ->
      inis.binds (label_fld l) (ini_fld y) is ->
      red s (trm_sel (trm_var (avar_f x)) l) s 
            (trm_var y)
  | red_new : forall (s: venv.t) (is: inis.t) (e: trm) (x: var),
      venv.unbound x s ->
      red s (trm_new is e)
          (s ;; (x, is)) (open_trm x e)
  (* congruence rules *)
  | red_call1 : forall s o m a s' o',
      red s o s' o' ->
      red s  (trm_call o  m a) 
          s' (trm_call o' m a)
  | red_call2 : forall s x m a s' a',
      red s a s' a' ->
      red s  (trm_call (trm_var (avar_f x)) m a ) 
          s' (trm_call (trm_var (avar_f x)) m a')
  | red_sel1 : forall s o l s' o',
      red s o s' o' ->
      red s  (trm_sel o  l)
          s' (trm_sel o' l).

(* Term typing *)
Inductive has : tenv.t -> venv.t -> trm -> label -> dec -> Prop :=
  | has_dec : forall G s e l d ds,
      typing_trm G s e (typ_rcd ds) ->
      decs.binds l d ds ->
      has G s e l d
with typing_trm : tenv.t -> venv.t -> trm -> typ -> Prop :=
  | typing_trm_var_g : forall G s x T,
      tenv.binds x T G ->
      venv.unbound x s ->
      typing_trm G s (trm_var (avar_f x)) T
  | typing_trm_var_s : forall G s x is ds,
      tenv.unbound x G ->
      venv.binds x is s ->
      typing_inis nil s is ds -> 
      typing_trm G s (trm_var (avar_f x)) (typ_rcd ds)
  | typing_trm_sel : forall G s e l T,
      has G s e (label_fld l) (dec_fld T) ->
      typing_trm G s (trm_sel e l) T
  | typing_trm_call : forall G s t m U V u,
      has G s t (label_mtd m) (dec_mtd U V) ->
      typing_trm G s u U ->
      typing_trm G s (trm_call t m u) V
  | typing_trm_new : forall G s nis ds t T,
      typing_inis G s nis ds -> (* no self reference yet, no recursion *)
      (forall x, tenv.unbound x G ->
                 venv.unbound x s ->
                 typing_trm (G ;; (x, typ_rcd ds)) s (open_trm x t) T) ->
      typing_trm G s (trm_new nis t) T
with typing_ini : tenv.t -> venv.t -> nini -> ndec -> Prop :=
  | typing_ini_fld : forall G s l v T,
      typing_trm G s (trm_var v) T ->
      typing_ini G s (nini_fld l v) (ndec_fld l T)
  | typing_ini_mtd : forall G s m S T t,
      (forall x, tenv.unbound x G ->
                 venv.unbound x s ->
                 typing_trm (G ;; (x, S)) s (open_trm x t) T) ->
      typing_ini G s (nini_mtd m S t) (ndec_mtd m S T)
with typing_inis : tenv.t -> venv.t -> inis.t -> decs.t -> Prop :=
  | typing_inis_nil : forall G s,
      typing_inis G s nil nil
  | typing_inis_cons : forall G s is i ds d,
      typing_inis G s is ds ->
      typing_ini  G s i d ->
      typing_inis G s (is ;; i) (ds ;; d).

Scheme has_mut         := Induction for has         Sort Prop
with   typing_trm_mut  := Induction for typing_trm  Sort Prop
with   typing_ini_mut  := Induction for typing_ini  Sort Prop
with   typing_inis_mut := Induction for typing_inis Sort Prop.

Combined Scheme typing_mutind from has_mut, typing_trm_mut, typing_ini_mut, typing_inis_mut.

Lemma invert_has: forall G s e l d,
  has G s e l d ->
  exists ds, typing_trm G s e (typ_rcd ds) /\ decs.binds l d ds.
Proof.
  intros. inv H. eauto.
Qed.

Lemma invert_typing_var_s: forall G s x is ds,
  typing_trm G s (trm_var (avar_f x)) (typ_rcd ds) ->
  venv.binds x is s ->
  typing_inis nil s is ds.
Proof.
  intros G s x is ds Hty Hbv.
  inversion Hty; subst.
  (* typing_var_g *)
  + exfalso. apply (@venv.binds_unbound_inv x is s); assumption.
  (* typing_var_s *)
  + assert (is0 = is) by apply (venv.binds_unique H4 Hbv). subst. assumption.
Qed.

Lemma invert_typing_ini_key: forall G s i d, 
  typing_ini G s i d -> inis.key i = decs.key d.
Proof.
  intros. inv H; reflexivity.
Qed.

Lemma invert_typing_ini_cases: forall G s i d, 
  typing_ini G s i d ->
  (exists l x T, i = (nini_fld l x) /\ d = (ndec_fld l T)) \/
  (exists m e T U, i = (nini_mtd m T e) /\ d = (ndec_mtd m T U)).
Proof.
  intros. inv H.
  + left. exists l v T. split; reflexivity.
  + right. exists m t S T. split; reflexivity.
Qed.

Lemma invert_typing_ini: forall G s i d, 
  typing_ini G s i d ->
  exists k iv dv, inis.key i = k /\ inis.value i = iv /\ 
                  decs.key d = k /\ decs.value d = dv.
Proof.
  intros. destruct (invert_typing_ini_cases H)
    as [[l [x [T [Heq1 Heq2]]]] | [m [e [T [U [Heq1 Heq2]]]]]].
  + exists (label_fld l) (ini_fld x) (dec_fld T). subst. auto.
  + exists (label_mtd m) (ini_mtd T e) (dec_mtd T U). subst. auto.
Qed.

Lemma decs_binds_to_inis_binds: forall d is ds s,
  typing_inis nil s is ds ->
  decs.binds (decs.key d) (decs.value d) ds ->
  exists i, decs.key d = inis.key i /\ inis.binds (inis.key i) (inis.value i) is.
Proof.
Admitted.

Lemma decs_binds_to_inis_binds_fld: forall l T is ds s,
  typing_inis nil s is ds ->
  decs.binds (label_fld l) (dec_fld T) ds ->
  exists x, inis.binds (label_fld l) (ini_fld x) is.
Proof.
  intros. remember (ndec_fld l T) as d. 
  assert (HeqKey: (decs.key d) = (label_fld l)).
    subst. reflexivity.
  assert (HeqVal: (decs.value d) = (dec_fld T)).
    subst. reflexivity.
  rewrite <- HeqKey in *. rewrite <- HeqVal in *.
  destruct (decs_binds_to_inis_binds _ H H0) as [i [Heq Hbi]].
  rewrite -> HeqKey in *.
  rewrite <- Heq in *.
  apply inis.binds_binding_inv in Hbi.
  destruct Hbi as [i' [Heq1 Heq2]].
  inversion i.
  subst.
  

Lemma decs_binds_to_inis_binds_fld: forall l T is ds s,
  typing_inis nil s is ds ->
  decs.binds (label_fld l) (dec_fld T) ds ->
  exists x, inis.binds (label_fld l) (ini_fld x) is.
Proof.
  intros l T is. induction is; intros ds s Hty Hbd. 
  + inv Hty. inv Hbd.
  + inv Hty. destruct (invert_typing_ini_cases H5)
    as [[k [x [S [Heq1 Heq2]]]] | [k [e [S [U [Heq1 Heq2]]]]]]; subst.
    - unfold inis.binds, inis.get; fold inis.get. 
        unfold inisParams.eq_key_dec. simpl.
      unfold decs.binds, decs.get in Hbd; fold decs.get in Hbd. 
        unfold decsParams.eq_key_dec in Hbd. simpl in Hbd.
      destruct (eq_label_dec (label_fld l) (label_fld k)).
      * exists x. reflexivity.
      * unfold decs.binds in IHis. apply IHis with ds0 s; assumption.
    - unfold inis.binds, inis.get; fold inis.get. 
        unfold inisParams.eq_key_dec. simpl.
      unfold decs.binds, decs.get in Hbd; fold decs.get in Hbd. 
        unfold decsParams.eq_key_dec in Hbd. simpl in Hbd.
      destruct (eq_label_dec (label_fld l) (label_fld k)).
      * exists . reflexivity.
      * unfold decs.binds in IHis. apply IHis with ds0 s; assumption.


 destruct (invert_typing_ini H5) as [k [iv [dv [Hik [Hiv [Hdk Hdv]]]]]].
    subst.



    assert (HeqKey: inis.key a = decs.key d) by apply (invert_typing_ini_key H5).
    unfold decs.binds, decs.get in Hbd. fold decs.get in Hbd.
    destruct (decsParams.eq_key_dec (label_fld l) (decs.key d)).
    - inv Hbd. exists (inis.key a).
*)

Definition progress_for(s: venv.t)(e: trm) :=
  (* can step *)
  (exists s' e', red s e s' e') \/
  (* or is a value *)
  (exists x is, e = (trm_var (avar_f x)) /\ venv.binds x is s).


Theorem progress: forall G s e T,
  typing_trm G s e T -> progress_for s e.
Proof.
  Definition P_has :=         fun G s e l d (Hhas: has G s e l d)   => progress_for s e.
  Definition P_typing_trm :=  fun G s e T (Hty: typing_trm G s e T) => progress_for s e.
  Definition P_typing_ini :=  fun G s i d (Htyp: typing_ini G s i d)      => True.
  Definition P_typing_inis := fun G s is ds (Htyp: typing_inis G s is ds) => True.
  apply (typing_trm_mut P_has P_typing_trm P_typing_ini P_typing_inis);
    intros;
    try apply I;
    unfold P_has, P_typing_trm, P_typing_ini, P_typing_inis, progress_for in *.
  (* case has_dec *)
  + assumption. 
  (* case typing_trm_var_g *)
  + (* how to step a var in Gamma ?? *) admit.
  (* case typing_trm_var_s *)
  + right. exists x is. split. reflexivity. assumption.
  (* case typing_trm_sel *)
  + left. destruct H as [IH | IH].
    (* receiver is an expression *)
    - destruct IH as [s' [e' IH]]. do 2 eexists. apply (red_sel1 l IH). 
    (* receiver is a var *)
    - destruct IH as [x [is [Heq Hbv]]]. subst. do 2 eexists.
      destruct (invert_has h) as [ds [Hty Hbd]].
stop
      eapply (red_sel Hbv).
      Check (invert_typing_var_s Hty Hbv).
      Check (red_sel Hbv).
  (* case typing_trm_call *)
  (* case typing_trm_new *)


(* garbage .............. *)



(*
what's below is not needed because simpler:
assign everything first to a var -> no need to evaluate fields of record
and one type for record construction / fully evaluated record
*)

(* Value (: [list nslot] or [label => slot] *)
Module val <: env.
Definition K := loc.
Definition V := slot.
Definition B := nslot.
Definition t := list nslot.
Definition key(s: nslot): loc := match s with
| nslot_fld n lo => label_fld n
| nslot_mtd n T e => label_mtd n
end.
Definition value(s: nslot): slot := match s with
| nslot_fld n lo => slot_fld lo
| nslot_mtd n T e => slot_mtd T e
end.
End val.

(* fully evaluated record member *)
Inductive slot : Type :=
  | slot_fld : loc -> slot
  | slot_mtd : typ -> trm -> slot.

(* named slot *)
Inductive nslot : Type :=
  | nslot_fld : nat -> loc -> nslot
  | nslot_mtd : nat -> typ -> trm -> nslot.

(* Import List.ListNotations. *)

(*
theories/Lists/List, Module ListNotations:
Notation " [ ] " := nil : list_scope.
Notation " [ x ] " := (cons x nil) : list_scope.
Notation " [ x ; .. ; y ] " := (cons x .. (cons y nil) ..) : list_scope.

theories/Init/Datatypes:
Infix "++" := app (right associativity, at level 60) : list_scope.
Infix "::" := cons (at level 60, right associativity) : list_scope.
*)

