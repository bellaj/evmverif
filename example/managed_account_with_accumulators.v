(** Managed account with accumulators: a contract that keeps track
 *  of the accumulated income and spending.
 *
 * The contract [managed_account_with_accumulators_code]
 * is a wallet-like contract that can be controlled by a single owner.
 * It also accepts payments from any account.
 *
 * The contract keeps track of the accumulated income and spending in the
 * storage.
 * storage[0]: income so far, and
 * storage[1]: spending so far
 * The difference 'income so far - spending so far' should
 * coincide with the balance.
 * This is stated in [managed_account_with_accumulators_invariant]
 *
 * When this contract is called with no data, the contract just
 * receives Eth.  So, storage[0] should be increased.
 *
 * When the contract is called with some data,
 * the contract sends some Ether, but only when the caller is
 * the owner.  The owner is stored in the program as an immediate value.
 * In this case,
 * data[12-31] is interpreted as the address of recipient.
 * data[32-63] is used as the amount of spending.
 * In this case storage[1] should be increased.
 *
 * There is no particular prevention of reentrancy, but the invariant holds
 * regardless of how deeply the execution is nested.
 *
 * See ../readme.md for how to machine-check the proofs.
 *)

(** Some Coq library imports **)

Require Import NArith.
Require FMapList.
Require Import OrderedType.
Require Import Word.
Require Import ContractSem.
Require Import Cyclic.Abstract.CyclicAxioms.
Require Import Coq.Lists.List.
Require Import ZArith.
Require BinNums.
Require Cyclic.ZModulo.ZModulo.

(* This one still contains unproven conjectures.  Sorry. *)
Require ConcreteWord.

Module ConcreteSem := (ContractSem.Make ConcreteWord.ConcreteWord).
Include ConcreteSem.

(** The Implementation **)

(* [plus_size_label] is the location of the JUMPDEST in the contract *)
(* TODO: streamline this by allowing labels in JUMPDEST *)
Definition plus_size_label : word := 13%Z.
Arguments plus_size_label /.

(* TODO: add owner as an immediate value and check it *)
(* The indentation shows the depth of the stack. *)
Definition managed_account_with_accumulators_code (owner : word) : program :=
  CALLDATASIZE ::
    PUSH1 plus_size_label ::
      JUMPI ::
  (* size zero *)
  CALLVALUE ::
    PUSH1 word_zero (* storage[0] *) ::
      SLOAD ::
      ADD ::
    PUSH1 word_zero ::
      SSTORE ::
  STOP ::
  JUMPDEST (* plus_size_label *) ::
  CALLVALUE ::
    PUSH1 word_zero (* invalid destination *) ::
  (**) JUMPI ::
  (* call_value zero *)
  CALLDATASIZE ::
    PUSH1 (64%Z) ::
      instr_GT ::
    PUSH1 (0%Z) ::
      JUMPI (* data too small *) ::
  PUSH32 owner ::
    CALLER ::
      instr_EQ ::
    ISZERO ::
    PUSH1 word_zero (* invalid destination *) ::
      JUMPI (* caller is not the owner *) ::
  PUSH1 (0%Z) (* out size *) ::
    PUSH1 (0%Z) (* out offset *) ::
      PUSH1 (0%Z) (* out size *) ::
        PUSH1 (0%Z) (* in offset *) ::
          PUSH1 (0%Z) (* in size *) ::
            PUSH1 (32%Z) ::
              CALLDATALOAD (* value loaded *) ::
              DUP1 ::
                PUSH1 (1%Z) ::
                  SLOAD ::
                  ADD ::
                PUSH1 (1%Z) ::
                  SSTORE ::
              PUSH1 (0%Z) ::
                CALLDATALOAD (* addr loaded *) ::
                PUSH2 (30000%Z) ::
                  CALL ::
    ISZERO ::
    PUSH1 word_zero ::
      JUMPI ::
  STOP ::
  nil.


(** The invaliant **)

Definition managed_account_with_accumulators_invariant (v : variable_env) (c : constant_env) : Prop :=
    word_add (v.(venv_balance) c.(cenv_this)) (storage_load 1%Z v.(venv_storage))
  = word_add v.(venv_value_sent) (storage_load 0%Z v.(venv_storage)).


(** The behavioural specification **)

Definition failing_action cont : contract_behavior :=
  ContractAction ContractFail cont.

Definition receive_eth cont : contract_behavior :=
  ContractAction (ContractReturn nil) cont.

Definition sending_action (recipient : word) value cont : contract_behavior :=
  ContractAction (ContractCall
                    {|
                      callarg_gaslimit := 30000%Z;
                      callarg_code := address_of_word recipient;
                      callarg_recipient := address_of_word recipient;
                      callarg_value := value;
                      callarg_data := nil;
                      callarg_output_begin := 0%Z;
                      callarg_output_size := 0%Z
                    |}) cont.


(* here is the specification of the contract as
   a Coq function. *)
(* Since a contract is a process that can experience unlimited number of
   interactions, the contract is specified with CoFixpoint. *)
(* It's a pity that the specification looks more complicated than the
   implementation.  At the current state, the main fruit is that the
   invariant is guaranteed in any case.  For proving that,
   this specification is useful. *)

(* TODO:
   why can't this be computed from the bytecode easily...
   which is called the static symbolic execution... *)
CoFixpoint managed_account_with_accumulators (owner : word) (income_sofar : word) (spending_sofar : word)
           (stack : list (word * word))
  : response_to_world :=
  Respond
    (fun cenv => (* what happens when the contract is called (or re-entered) *)
       match word_eq word_zero (word_of_nat (length (callenv_data cenv))) with
       | true => receive_eth
                   (managed_account_with_accumulators owner
                                                      (word_add income_sofar cenv.(callenv_value))
                                                      spending_sofar stack)
       | false =>
         if word_eq word_zero (cenv.(callenv_value)) then
           if word_smaller (word_of_nat (List.length cenv.(callenv_data))) 64%Z then
             failing_action (managed_account_with_accumulators owner income_sofar spending_sofar stack)
           else
             if word_iszero (bool_to_word (word_eq (word_of_address cenv.(callenv_caller)) owner)) then
               failing_action (managed_account_with_accumulators owner income_sofar spending_sofar stack)
             else
               let addr := list_slice 0 32 cenv.(callenv_data) in
               let value := list_slice 32 32 cenv.(callenv_data) in
               if word_smaller (word_sub (word_add income_sofar cenv.(callenv_value)) spending_sofar) value then
                 failing_action
                   (managed_account_with_accumulators owner income_sofar spending_sofar stack)
               else
                 sending_action addr value
                                (managed_account_with_accumulators owner income_sofar
                                                                   (word_add spending_sofar value)
                                              ((income_sofar, spending_sofar) :: stack))
         else
           failing_action (managed_account_with_accumulators owner income_sofar spending_sofar stack)
       end
    )
    (fun returned => (* what happens when a callee returns back to the contract. *)
       match stack with
       | _ :: new_stack =>
           ContractAction (ContractReturn nil)
                          (managed_account_with_accumulators owner income_sofar spending_sofar new_stack)
       | nil =>
         failing_action (managed_account_with_accumulators owner income_sofar spending_sofar stack)
       end
    )
    ( (* what happens when a callee fails back to the contract. *)
      match stack with
      | (income_old, spending_old) :: new_stack =>
        failing_action (managed_account_with_accumulators owner income_old spending_old new_stack)
      | nil =>
        failing_action (managed_account_with_accumulators owner income_sofar spending_sofar stack)
      end
    )
    .

(* This lemma is just for expanding the above definition.  *)
(* TODO: how to avoid typing the same thing twice? *)
Lemma managed_account_with_accumulators_def :
  forall owner income_sofar spending_sofar stack,
    managed_account_with_accumulators owner income_sofar spending_sofar stack =
  Respond
    (fun cenv =>
       match word_eq word_zero (word_of_nat (length (callenv_data cenv))) with
       | true => receive_eth
                   (managed_account_with_accumulators owner
                                                      (word_add income_sofar cenv.(callenv_value))
                                                      spending_sofar stack)
       | false =>
         if word_eq word_zero (cenv.(callenv_value)) then
           if word_smaller (word_of_nat (List.length cenv.(callenv_data))) 64%Z then
             failing_action (managed_account_with_accumulators owner income_sofar spending_sofar stack)
           else
             if word_iszero (bool_to_word (word_eq (word_of_address cenv.(callenv_caller)) owner)) then
               failing_action (managed_account_with_accumulators owner income_sofar spending_sofar stack)
             else
               let addr := list_slice 0 32 cenv.(callenv_data) in
               let value := list_slice 32 32 cenv.(callenv_data) in
               if word_smaller (word_sub (word_add income_sofar cenv.(callenv_value)) spending_sofar) value then
                 failing_action
                   (managed_account_with_accumulators owner income_sofar spending_sofar stack)
               else
                 sending_action addr value
                                (managed_account_with_accumulators owner income_sofar
                                                                   (word_add spending_sofar value)
                                              ((income_sofar, spending_sofar) :: stack))
         else
           failing_action (managed_account_with_accumulators owner income_sofar spending_sofar stack)
       end
    )
    (fun returned =>
       match stack with
       | _ :: new_stack =>
           ContractAction (ContractReturn nil)
                          (managed_account_with_accumulators owner income_sofar spending_sofar new_stack)
       | nil =>
         failing_action (managed_account_with_accumulators owner income_sofar spending_sofar stack)
       end
    )
    (
      match stack with
      | (income_old, spending_old) :: new_stack =>
        failing_action (managed_account_with_accumulators owner income_old spending_old new_stack)
      | nil =>
        failing_action (managed_account_with_accumulators owner income_sofar spending_sofar stack)
      end
    )
    .
Proof.
  intros owner i s stack.
  unfold managed_account_with_accumulators.
  apply response_expander_eq.
Qed.

Axiom managed_account_with_accumulators_address : address.

(** How should the state of the implementation look like? **)

(*** How should the storage look like *)
Definition managed_account_with_accumulators_storage (income_sofar spending_sofar : word) : storage :=
  storage_store 1%Z spending_sofar (storage_store 0%Z income_sofar (ST.empty word))
  .

Definition managed_account_with_accumulators_account_state (owner income_sofar spending_sofar : word) (going_calls : list variable_env) : account_state :=
  {|
    account_address := managed_account_with_accumulators_address (* TODO: declare this in a section *);
    account_storage := managed_account_with_accumulators_storage income_sofar spending_sofar ;
    account_code := managed_account_with_accumulators_code owner ;
    account_balance := word_sub income_sofar spending_sofar ;
    account_ongoing_calls := going_calls
  |}
  .

(** How the state should look like when the contract has called some
    account. *)
Record managed_account_with_accumulators_calling_state (income_for_reset : word) (spending_for_reset : word) (v : variable_env) : Prop :=
  {
    cw_calling_prg_sfx :
      (v.(venv_prg_sfx) =
       ISZERO ::
           PUSH1 word_zero ::
           JUMPI ::
           STOP ::
           nil) ;
    cw_calling_balance :
      venv_balance_at_call v managed_account_with_accumulators_address =
      word_sub income_for_reset spending_for_reset ;
    cw_calling_storage :
      v.(venv_storage_at_call) =
       managed_account_with_accumulators_storage income_for_reset spending_for_reset
  }.


(** In case of nested reentrancy, all ongoing executions of the contract
    should look like specified above. **)
Inductive all_cw_corresponds :
          list variable_env -> list (word * word) -> Prop :=
| acc_nil : all_cw_corresponds nil nil
| acc_cons :
    forall hd_venv tail_venvs hd_income hd_spending tail_stack,
      managed_account_with_accumulators_calling_state hd_income hd_spending hd_venv ->
      all_cw_corresponds tail_venvs tail_stack ->
      all_cw_corresponds (hd_venv :: tail_venvs)
                       ((hd_income, hd_spending) :: tail_stack)
.


(** The theorem: The implementation matches the specification **)
(** This still relies on some unproven conjectures in ConcreteWord.v **)

Theorem managed_account_with_accumulators_correct :
  forall (owner income_sofar spending_sofar : word) ongoing stack,
    all_cw_corresponds ongoing stack ->
    account_state_responds_to_world
      (managed_account_with_accumulators_account_state owner income_sofar spending_sofar ongoing)
      (managed_account_with_accumulators owner income_sofar spending_sofar stack)
      managed_account_with_accumulators_invariant.
Proof.
  cofix.
  intros owner income_sofar spending_sofar ongoing stack ongoingH.
  rewrite managed_account_with_accumulators_def.
  apply AccountStep.
  {
    unfold respond_to_call_correctly.
    intros callenv act cont.
    split.
    {
      unfold managed_account_with_accumulators_invariant.
      cbn.
      unfold update_balance.
      rewrite address_eq_refl.
      unfold managed_account_with_accumulators_storage.
      set (spend := storage_load 1%Z _).
      assert (spendH : spend = spending_sofar).
      {
        unfold spend.
        clear spend.
        rewrite storage_load_store.
        rewrite ST.E.eq_refl.
        reflexivity.
      }
      rewrite spendH.
      set (income := storage_load 0%Z _).
      assert (incomeH : income = income_sofar).
      {
        unfold income.
        rewrite storage_load_store.
        set (e := word_eq _ _).
        compute in e.
        unfold e.
        clear e.
        rewrite storage_load_store.
        set (e := word_eq _ _).
        compute in e.
        unfold e.
        reflexivity.
      }
      rewrite incomeH.
      generalize word_add_sub.
      cbn.
      intro was.
      rewrite !was.
      generalize word_addK.
      intro wK.
      cbn in wK.
      rewrite wK.
      apply word_addC.
    }
    {
      intro I.
      set (data_len_zero := word_eq word_zero (word_of_nat _)).
      case_eq data_len_zero.
      { (* data_len_is_zero *)
        intro data_len_is_zero.
        unfold receive_eth.
        intro H.
        inversion H; subst.
        clear H.
        eexists.
        eexists.
        eexists.
        split.
        {
          intro s.
          repeat (case s as [| s]; [ solve [left; auto] | cbn ]).
          unfold datasize.
          cbn.
          unfold word_iszero.
          rewrite data_len_is_zero.
          repeat (case s as [| s]; [ solve [left; auto] | cbn ]).
          right.
          reflexivity.
        }
        {
          cbn.
          unfold managed_account_with_accumulators_storage.
          set (prev_income := storage_load _ _).
          assert (P : prev_income = income_sofar).
          {
            unfold prev_income.
            (* why does it contain ST.find *)
            rewrite storage_store_reorder by (compute; auto).
            rewrite storage_load_store.
            reflexivity.
          }
          rewrite P.
          set (new_income := ZModulo.to_Z _ (ZModulo.add income_sofar _)).
          generalize (managed_account_with_accumulators_correct owner new_income).
          intro IH.
          unfold managed_account_with_accumulators_account_state in IH.
          unfold managed_account_with_accumulators_storage in IH.
          assert (II : storage_store 0%Z new_income
                       (storage_store 1%Z spending_sofar
                          (storage_store 0%Z income_sofar
                             (ST.empty word))) =
                       (storage_store 1%Z spending_sofar
                          (storage_store 0%Z new_income
                             (ST.empty word)))).
          {
            rewrite storage_store_reorder by solve [compute; auto].
            rewrite storage_store_idem.
            reflexivity.
          }
          rewrite II.
          unfold update_balance.
          rewrite address_eq_refl.
          generalize word_add_sub.
          cbn.
          intro was.
          rewrite was.
          cbn in IH.
          clear II.
          clear was.

          eapply IH.
          assumption.
        }
      }
      { (* input data is not nil *)
        intros data_len_non_zero.
        case_eq (word_eq word_zero (callenv_value callenv)).
        { (* sent value is zero *)
          intro sent_zero.
          (* hmmm wanting ssreflect tactics. *)
          match goal with
            | [ |- ((if ?t then _ else _) = _) -> _] => case_eq t
          end.

          {
            intro data_short.
            unfold failing_action.
            intro H.
            inversion H; subst.
            clear H.
            eexists.
            eexists.
            eexists.
            split.
            {
              intros s.
              repeat (case s as [| s]; [ solve [left; auto] | cbn ]).
              unfold plus_size_label.
              unfold datasize.
              cbn.
              set (zero_cond := word_iszero _ ).
              assert (Zf : zero_cond = false) by assumption.
              rewrite Zf.
              cbn.
              simpl.
              repeat (case s as [| s]; [ solve [left; auto] | ]).
              cbn.
              set (z_cond := word_iszero _).
              assert (Zt : z_cond = true) by assumption.
              rewrite Zt.
              repeat (case s as [| s]; [ solve [left; auto] | ]).
              cbn.
              unfold datasize.
              cbn.
              set (small := word_smaller _ _).
              assert (SS : small = true).
              {
                unfold small.
                assumption.
              }
              rewrite SS.
              simpl.
              right.
              eauto.
            }
            {
              unfold update_account_state.
              cbn.
              unfold update_balance.
              rewrite address_eq_refl.
              apply managed_account_with_accumulators_correct.
              assumption.
            }
          }
          {
            intro data_big_enough.
            set (owner_ng := word_iszero (bool_to_word (word_eq _ owner))).
            case_eq owner_ng.
            {
              (* The case where the owner is not correct. *)
              intros owner_ngT ac_eq.
              inversion ac_eq; subst.
              clear ac_eq.

              eexists.
              eexists.
              eexists.
              split.
              {
                intros s.
                repeat (case s as [| s]; [ solve [left; auto] | cbn ]).
                unfold datasize.
                cbn.
                unfold word_iszero.
                rewrite data_len_non_zero.
                cbn.
                set (matched := N_of_word _).
                compute in matched.
                unfold matched.
                clear matched.
                cbn.
                repeat (case s as [| s]; [ solve [left; auto] | cbn ]).
                unfold word_iszero.
                rewrite sent_zero.
                repeat (case s as [| s]; [ solve [left; auto] | cbn ]).
                unfold datasize.
                cbn.
                set (mo := ZModulo.modulo _ 64 _).
                compute in mo.
                unfold mo.
                clear mo.
                rewrite data_big_enough.
                cbn.
                repeat (case s as [| s]; [ solve [left; auto] | cbn ]).
                unfold compose.
                unfold bool_to_word in owner_ngT.
                unfold word_of_address in owner_ngT.
                cbn in owner_ngT.
                rewrite owner_ngT.
                cbn.
                set (cond := word_iszero _).
                compute in cond.
                unfold cond.
                clear cond.
                cbn.
                right.
                reflexivity.
              }
              {
                unfold account_state_update_storage.
                cbn.
                rewrite get_update_balance.
                unfold word_sub.
                cbn.
                apply managed_account_with_accumulators_correct.
                assumption.
              }
            }
            intro owner_ok.
            unfold sending_action.
            (* Here, before introducing the existential variables,
             * all ambuiguities must be resolved. *)
            set (enough_balance_spec := word_smaller _ _).
            case_eq enough_balance_spec.
            { (* not enough balance *)
              intro not_enough_spec.
              intro H.
              inversion H; subst.
              clear H.

              eexists.
              eexists.
              eexists.
              split.
              {
                intro s.
                repeat (case s as [| s]; [ solve [left; auto] | ]).
                cbn.
                unfold datasize.
                cbn.
                set (e0 := word_iszero _).
                assert (R : e0 = false) by assumption.
                rewrite R.
                unfold N_of_word.
                cbn.
                set (matched := Z.to_N (ZModulo.to_Z _ (ZModulo.modulo _ 13 256))).
                compute in matched.
                unfold matched.
                clear matched.                  simpl.
                repeat (case s as [| s]; [ solve [left; auto] | ]).
                simpl.
                assert (Z : word_iszero (callenv_value callenv) = true)
                by assumption.
                rewrite Z.
                repeat (case s as [| s]; [ solve [left; auto] | ]).
                cbn.
                unfold datasize.
                simpl.
                set (s64 := word_smaller _ _).
                assert (S : s64 = false).
                {
                  unfold s64.
                  set (x := ZModulo.modulo _ _ _ ).
                  compute in x.
                  unfold x.
                  assumption.
                }

                rewrite S.
                simpl.
                repeat (case s as [| s]; [ solve [left; auto] | cbn ]).
                cbn in owner_ok.
                unfold compose.
                rewrite owner_ok.
                set (cond := word_iszero _ ).
                compute in cond.
                unfold cond.
                clear cond.
                repeat (case s as [| s]; [ solve [left; auto] | cbn ]).

                set (cd := cut_data _ _).
                assert (cdH : cd = list_slice 32 32 (callenv_data callenv)).
                {
                  unfold cd.
                  cbn.
                  unfold cut_data.
                  cbn.
                  reflexivity.
                }
                rewrite cdH.
                clear cdH cd.
                set (balance_smaller := word_smaller _ _).
                assert (A : balance_smaller = true).
                {
                  unfold balance_smaller.
                  rewrite get_update_balance.
                  generalize word_add_sub.
                  cbn.
                  intro K.
                  rewrite K.
                  assumption.
                }
                rewrite A.
                right.
                eauto.
              }
              {
                simpl.
                unfold managed_account_with_accumulators_account_state in managed_account_with_accumulators_correct.
                unfold update_balance.
                rewrite address_eq_refl.
                apply managed_account_with_accumulators_correct.
                assumption.
              }
            }
            { (* enough balance *)
              intro enough_balance_spec_t.
              intro H.
              inversion H; subst.
              clear H.
              eexists.
              eexists.
              eexists.
              split.
              {
                intro s.
                repeat (case s as [| s]; [ solve [left; auto] | ]).
                cbn.
                unfold datasize.
                cbn.
                set (e0 := word_iszero _).
                assert (R : e0 = false) by assumption.
                rewrite R.
                unfold N_of_word.
                cbn.
                set (matched := Z.to_N (ZModulo.to_Z _ (ZModulo.modulo _ 13 256))).
                compute in matched.
                unfold matched.
                clear matched.                  simpl.
                repeat (case s as [| s]; [ solve [left; auto] | ]).
                simpl.
                assert (Z : word_iszero (callenv_value callenv) = true) by assumption.
                rewrite Z.
                repeat (case s as [| s]; [ solve [left; auto] | ]).
                cbn.
                unfold datasize.
                cbn.
                set (s64 := word_smaller _ _).
                assert (S : s64 = false) by assumption.
                rewrite S.
                simpl.
                repeat (case s as [| s]; [ solve [left; auto] | cbn ]).
                cbn in owner_ok.
                unfold compose.
                rewrite owner_ok.
                set (cond := word_iszero _ ).
                compute in cond.
                unfold cond.
                clear cond.
                repeat (case s as [| s]; [ solve [left; auto] | cbn ]).

                set (balance_smaller := word_smaller _ _).
                assert (F : balance_smaller = false).
                {
                  (* use enough_balance_spec *)
                  unfold cut_data in balance_smaller.
                  cbn in balance_smaller.
                  unfold balance_smaller.
                  rewrite get_update_balance.
                  set (idx := N_of_word _).
                  compute in idx.
                  unfold idx.
                  clear idx.
                  clear balance_smaller.
                  cbn in enough_balance_spec_t.
                  generalize enough_balance_spec_t.
                  generalize word_add_sub.
                  intro WAS.
                  cbn in WAS.
                  rewrite WAS.
                  tauto.
                }
                rewrite F.
                clear F.
                cbn.
                right.
                f_equal.
                f_equal.
                f_equal.
                {
                  rewrite cut_memory_zero_nil.
                  reflexivity.
                }
              }
              {
                cbn.
                unfold cut_data.
                cbn.
                unfold managed_account_with_accumulators_account_state in managed_account_with_accumulators_correct.
                set (new_storage := storage_store _ _ _).
                set (new_ongoing := _ :: ongoing).


                unfold update_balance.
                rewrite address_eq_refl.

                set (new_balance := ZModulo.to_Z _ (ZModulo.sub _ _)).

                set (new_sp := ZModulo.to_Z _ (ZModulo.add spending_sofar _)).
                assert (S : new_storage = managed_account_with_accumulators_storage income_sofar new_sp).
                {
                  unfold new_storage.
                  clear new_ongoing.
                  clear new_balance.
                  clear enough_balance_spec_t.
                  unfold managed_account_with_accumulators_storage.
                  rewrite storage_load_store.
                  set (e := word_eq _ 1%Z).
                  compute in e.
                  unfold e.
                  clear e.
                  set (idx := (N_of_word _)).
                  compute in idx.
                  unfold idx.
                  clear idx.
                  fold new_sp.
                  rewrite storage_store_idem.
                  reflexivity.
                }

                rewrite S.
                assert (B : new_balance = word_sub income_sofar new_sp).
                {
                  clear ongoing ongoingH I new_ongoing.
                  unfold new_balance.
                  unfold new_sp.
                  clear new_balance.
                  clear S.
                  clear new_storage.
                  clear new_sp.
                  clear enough_balance_spec_t.
                  generalize word_add_zero.
                  intro T.
                  cbn in T.
                  rewrite (T _ _ sent_zero).
                  generalize word_sub_sub.
                  intro S.
                  cbn in S.
                  cbn.
                  rewrite !S.
                  rewrite modulo_idem.
                  set (c := N_of_word _).
                  compute in c.
                  unfold c.
                  clear c.
                  reflexivity.
                }
                rewrite B.
                apply (managed_account_with_accumulators_correct owner income_sofar new_sp).

                unfold new_ongoing.
                apply acc_cons.
                {
                  simpl.
                  refine (
                      {|
                        cw_calling_prg_sfx := _ ;
                        cw_calling_balance := _
                      |}
                    ).
                  {
                    reflexivity.
                  }
                  {
                    cbn.
                    rewrite get_update_balance.
                    reflexivity.
                  }
                  {
                    cbn.
                    reflexivity.
                  }
                }
                {
                  assumption.
                }
              }
            }
          }
        }
        { (* sent value is not zero, and data is also sent; should fail *)
          (* I can just imagine this needs the definition of datasize, too *)
          idtac.
          intro value_nonzero.
          intro H.
          inversion H; subst.
          eexists.
          eexists.
          eexists.
          split.
          {
            intro s.
            repeat (case s as [| s]; [ solve [left; auto] | ]).
            cbn.
            unfold datasize.
            cbn.
            set (e0 := word_iszero _).
            assert (E0 : e0 = false).
            {
              assumption.
            }
            rewrite E0.
            simpl.
            repeat (case s as [| s]; [ solve [left; auto] | ]).
            cbn.
            set (v0 := word_iszero _).
            assert (V0 : v0 = false).
            {
              (* maybe this should be a lemma *)
              unfold v0.
              generalize value_nonzero.
              unfold word_eq.
              unfold ZModulo.eq0.
              set (v := callenv_value _).
              case_eq v; auto.
            }
            rewrite V0.
            cbn.
            right. (* TODO: maybe name a constructor *)
            eauto.
          }
          {
              unfold update_account_state.
              cbn.
              unfold update_balance.
              rewrite address_eq_refl.
              apply managed_account_with_accumulators_correct.
              assumption.
          }
        }
      }
    }
  }
  {
    unfold respond_to_return_correctly.
    intros rr venv cont act.
    intro venvH.
    intro H.
    inversion H; subst.
    clear H.
    unfold build_venv_returned in venvH.
    unfold managed_account_with_accumulators_account_state in venvH.
    cbn in venvH.
    case ongoing as [| recovered rest_ongoing]; try congruence.
    inversion ongoingH; subst.
    (* I don't like the generated names... *)
    (* TODO: create a theorem instead of inversion ongoingH *)
    case H2; clear H2.
    intros sfx_eq bal_eq.
    inversion H1; subst.

    eexists.
    eexists.
    eexists.
    split.
    {
      inversion venvH; subst.
      clear venvH.
      rewrite sfx_eq.

      intro s.
      repeat (case s as [| s]; [ solve [left; auto] | cbn ]).
      simpl.
      right.
      eauto.
    }
    {
      unfold update_account_state.
      unfold managed_account_with_accumulators_account_state in managed_account_with_accumulators_correct.
      unfold account_state_update_storage.
      simpl.

      rewrite get_update_balance.
      apply (managed_account_with_accumulators_correct owner income_sofar spending_sofar
                                         rest_ongoing tail_stack).
      assumption.
    }
  }
  {
    unfold respond_to_fail_correctly.
    intros v c a.
    intro v_eq.
    intro a_c_eq.
    inversion a_c_eq; subst.
    unfold failing_action in a_c_eq.
    clear a_c_eq.
    unfold build_venv_fail in v_eq.
    simpl in v_eq.
    case_eq ongoing.
    {
      intros ?.
      subst.
      congruence.
    }
    intros ongoing_head ongoing_tail ongoing_eq.
    subst.
    inversion v_eq; subst.
    clear v_eq.
    inversion ongoingH; subst.
    clear ongoingH.
    inversion H0; subst.

    eexists.
    eexists.
    eexists.
    split.
    {
      intro s.
      case H2.
      clear H2.
      intros ongoing_head_sfx_eq balance_eq storage_eq.
      rewrite ongoing_head_sfx_eq.

      repeat (case s as [| s]; [ solve [left; auto] | cbn ]).

      assert (Q : word_iszero (ZModulo.to_Z ALEN.p ZModulo.one) = false).
      {
        compute.
        auto.
      }
      rewrite Q.
      simpl.
      right.
      eauto.
    }
    { (* somehow use the induction hypothesis *)
      unfold update_account_state.
      cbn.
      case H2.
      clear H2.
      intros sfx_eq balance_eq storage_eq.
      rewrite storage_eq.
      rewrite balance_eq.
      apply managed_account_with_accumulators_correct.
      assumption.
    }
  }
Qed.
